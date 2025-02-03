const std = @import("std");
const builtin = @import("builtin");
const assertions = @import("utils/assertions.zig");
const assert = assertions.assert;
const string_utils = @import("utils/string_utils.zig");
const x = @import("x");
const common = @import("x11/x11_common.zig");
const render = @import("compositing_manager/render.zig");
const app_state = @import("compositing_manager/app_state.zig");
const x11_extension_utils = @import("x11/x11_extension_utils.zig");
const x_composite_extension = @import("x11/x_composite_extension.zig");
const x_shape_extension = @import("x11/x_shape_extension.zig");
const x_render_extension = @import("x11/x_render_extension.zig");
const x_damage_extension = @import("x11/x_damage_extension.zig");
const x_fixes_extension = @import("x11/x_fixes_extension.zig");
const XWindowFinder = @import("x11/x_window_finder.zig").XWindowFinder;
const render_utils = @import("utils/render_utils.zig");

// In order to create the total screen presentation we need to create a render picture
// for the root window (or "composite overlay window" if available), and draw the
// windows on it manually, taking the window hierarchy into account.

// We want to use manual redirection so the window contents will be redirected to
// offscreen storage, but not automatically updated on the screen when they're modified.

pub const std_options = struct {
    pub const log_level = .debug;

    pub const log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .x_window_finder, .level = .debug },
    };
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer switch (gpa.deinit()) {
        .ok => {},
        .leak => std.log.err("GPA allocator: Memory leak detected", .{}),
    };

    try x.wsaStartup();

    // We establish two distinct connections to the X server:
    //
    // 1. Event Connection: Used for reading events in the main event loop.
    //    - Make sure to call `x.change_window_attributes` on the windows you care about
    //      listening for events on. Specify `.event_mask` with the events you want the
    //      event loop to subscribe to.
    // 2. Request Connection: Used for making one-shot requests and reading their replies.
    //
    // This dual-connection approach offers several benefits:
    // - Clear Separation: It keeps event handling separate from one-shot requests.
    // - Simplified Reply Handling: We can easily get replies to one-shot requests
    //   without worrying about them being mixed with event messages.
    // - No Complex Queuing: Unlike the xcb library, we avoid the need for a
    //   cookie-based reply queue system.
    //
    // This design leads to cleaner, more maintainable code by reducing complexity
    // in handling different types of X server interactions.
    //
    // 1. Create an X connection for the event loop
    const x_event_connect_result = try common.connect(allocator);
    defer x_event_connect_result.setup.deinit(allocator);
    const x_event_connection = try common.XConnection.init(
        x_event_connect_result.sock,
        1000,
        allocator,
    );
    defer x_event_connection.deinit();
    // 2. Create an X connection for making one-off requests
    const x_request_connect_result = try common.connect(allocator);
    defer x_request_connect_result.setup.deinit(allocator);
    const x_request_connection = try common.XConnection.init(
        x_request_connect_result.sock,
        8000,
        allocator,
    );
    defer x_request_connection.deinit();

    const conn_setup_fixed_fields = x_event_connect_result.setup.fixed();
    // Print out some info about the X server we connected to
    {
        inline for (@typeInfo(@TypeOf(conn_setup_fixed_fields.*)).Struct.fields) |field| {
            std.log.debug("{s}: {any}", .{ field.name, @field(conn_setup_fixed_fields, field.name) });
        }
        std.log.debug("vendor: {s}", .{try x_event_connect_result.setup.getVendorSlice(conn_setup_fixed_fields.vendor_len)});
    }

    const screen = common.getFirstScreenFromConnectionSetup(x_event_connect_result.setup);
    inline for (@typeInfo(@TypeOf(screen.*)).Struct.fields) |field| {
        std.log.debug("SCREEN 0| {s}: {any}", .{ field.name, @field(screen, field.name) });
    }
    std.log.info("root window ID {0} 0x{0x}", .{screen.root});

    // We use the X Composite extension to redirect the rendering of the windows to offscreen storage.
    const optional_composite_extension = try x11_extension_utils.getExtensionInfo(
        x_request_connection,
        "Composite",
    );
    const composite_extension = optional_composite_extension orelse @panic("X Composite extension extension not found");

    // We use the X Shape extension to make the debug window click-through-able. If
    // you're familiar with CSS, we use this to apply `pointer-events: none;`.
    const optional_shape_extension = try x11_extension_utils.getExtensionInfo(
        x_request_connection,
        "SHAPE",
    );
    const shape_extension = optional_shape_extension orelse @panic("X SHAPE extension not found");

    // We use the X Render extension for capturing screenshots and splatting them onto
    // our window. Useful because their "composite" request works with mismatched depths
    // between the source and destinations.
    const optional_render_extension = try x11_extension_utils.getExtensionInfo(
        x_request_connection,
        "RENDER",
    );
    const render_extension = optional_render_extension orelse @panic("RENDER extension not found");

    // We use the X Damage extension to get notified when a region is damaged (where a
    // window would be drawn) and needs to be redrawn.
    const optional_damage_extension = try x11_extension_utils.getExtensionInfo(
        x_request_connection,
        "DAMAGE",
    );
    const damage_extension = optional_damage_extension orelse @panic("X Damage extension extension not found");

    // We use the X Fixes extension to create regions to use with the Damage extension.
    const optional_fixes_extension = try x11_extension_utils.getExtensionInfo(
        x_request_connection,
        "XFIXES",
    );
    const fixes_extension = optional_fixes_extension orelse @panic("X Fixes extension extension not found");

    // We must run the query_version request of each extension on every connection that
    // interacts with the extension. Most extensions have this behavior in the spec that
    // it will return a "request" error (BadRequest) if haven't negotiated the version
    // of the extension.
    //
    // > The client must negotiate the version of the extension before executing
    // > extension requests.  Behavior of the server is undefined otherwise.
    //
    // > The client must negotiate the version of the extension before executing
    // > extension requests.  Otherwise, the server will return BadRequest for any
    // > operations other than QueryVersion.
    const x_connections = [_]common.XConnection{ x_event_connection, x_request_connection };
    for (x_connections) |x_connection| {
        try x_composite_extension.ensureCompatibleVersionOfXCompositeExtension(
            x_connection,
            &composite_extension,
            .{
                // We require version 0.3 of the X Composite extension for the
                // `x.composite.get_overlay_window` request.
                .major_version = 0,
                .minor_version = 3,
            },
        );

        try x_shape_extension.ensureCompatibleVersionOfXShapeExtension(
            x_connection,
            &shape_extension,
            .{
                // We arbitrarily require version 1.1 of the X Shape extension
                // because that's the latest version and is sufficiently old
                // and ubiquitous.
                .major_version = 1,
                .minor_version = 1,
            },
        );

        try x_render_extension.ensureCompatibleVersionOfXRenderExtension(
            x_connection,
            &render_extension,
            .{
                // We arbitrarily require version 0.11 of the X Render extension just
                // because it's the latest but came out in 2009 so it's pretty much
                // ubiquitous anyway. Feature-wise, we only use "Composite" which came out
                // in 0.0.
                //
                // For more info on what's changed in each version, see the "15. Extension
                // Versioning" section of the X Render extension protocol docs,
                // https://www.x.org/releases/X11R7.5/doc/renderproto/renderproto.txt
                .major_version = 0,
                .minor_version = 11,
            },
        );

        try x_damage_extension.ensureCompatibleVersionOfXDamageExtension(
            x_connection,
            &damage_extension,
            .{
                // This just seems like the only veresion
                .major_version = 1,
                .minor_version = 1,
            },
        );

        try x_fixes_extension.ensureCompatibleVersionOfXFixesExtension(
            x_connection,
            &fixes_extension,
            .{
                // We only use requests from version 2.0 or lower from the X Fixes extension
                .major_version = 2,
                .minor_version = 0,
            },
        );
    }

    // Assemble a map of X extension info
    const extensions = x11_extension_utils.Extensions(&.{ .composite, .shape, .render, .fixes, .damage }){
        .composite = composite_extension,
        .shape = shape_extension,
        .render = render_extension,
        .fixes = fixes_extension,
        .damage = damage_extension,
    };

    // Redirect all of the subwindows of the root window to offscreen storage.
    {
        var message_buffer: [x.composite.redirect_subwindows.len]u8 = undefined;
        x.composite.redirect_subwindows.serialize(&message_buffer, composite_extension.opcode, .{
            .window_id = screen.root,
            // With both `.manual` and `.automatic` redirection, the X server will
            // redirect the output to offscreen storage. The difference is that with
            // `.manual`, the X server will not automatically update the root window or
            // overlay window when the window contents change.
            //
            // Since the X server doesn't handle alpha/transparency, we want `.manual`
            // redirection so we can composite the window contents to our final overlay
            // window ourselves taking alpha/transparency into account.
            .update_type = .manual,
        });
        try x_request_connection.send(&message_buffer);
    }

    // Get the overlay window that we can draw on without interference. This window is
    // always above normal windows and is always below the screen saver window. It has
    // the same size of the root window.
    //
    // Calling `get_overlay_window` automatically maps/shows the overlay window if it hasn't
    // been mapped yet.
    {
        var message_buffer: [x.composite.get_overlay_window.len]u8 = undefined;
        x.composite.get_overlay_window.serialize(&message_buffer, composite_extension.opcode, .{
            .window_id = screen.root,
        });
        try x_request_connection.send(&message_buffer);
    }
    const overlay_window_id = blk: {
        const message_length = try x.readOneMsg(
            x_request_connection.reader(),
            @alignCast(x_request_connection.buffer.nextReadBuffer()),
        );
        // const msg = try common.asReply(
        //     x.composite.get_overlay_window.Reply,
        //     @alignCast(x_request_connection.buffer.double_buffer_ptr[0..message_length]),
        // );
        // break :blk msg.overlay_window_id;

        try common.checkMessageLengthFitsInBuffer(message_length, x_request_connection.buffer.half_len);
        switch (x.serverMsgTaggedUnion(@alignCast(x_request_connection.buffer.double_buffer_ptr))) {
            .reply => |msg_reply| {
                const msg: *x.composite.get_overlay_window.Reply = @ptrCast(msg_reply);
                break :blk msg.overlay_window_id;
            },
            else => |msg| {
                std.log.err("expected a reply for `x.composite.get_overlay_window` but got {}", .{msg});
                return error.ExpectedReplyForGetOverlayWindow;
            },
        }
    };

    // Since each connection has a `base_resource_id`, let's create most resources with
    // the request connection since that's easier
    var request_connection_id_generator = render.IdGenerator.init(
        x_request_connect_result.setup.fixed().resource_id_base,
    );
    var ids = render.Ids.init(
        screen.root,
        overlay_window_id,
        &request_connection_id_generator,
    );
    std.log.debug("ids: {any}", .{ids});

    // But we still need to create Damage resources with the event connection because
    // they have coupled creating the Damage object with tracking the DamageNotify
    // events.
    var event_connection_id_generator = render.IdGenerator.init(
        x_event_connect_result.setup.fixed().resource_id_base,
    );

    // We're using 32-bit depth so we can use ARGB colors that include alpha/transparency
    const depth = 32;

    const root_screen_dimensions = render_utils.Dimensions{
        .width = @intCast(screen.pixel_width),
        .height = @intCast(screen.pixel_height),
    };

    var window_map = std.AutoHashMap(u32, app_state.Window).init(allocator);
    defer window_map.deinit();
    var window_to_picture_id_map = std.AutoHashMap(u32, u32).init(allocator);
    var window_to_region_id_map = std.AutoHashMap(u32, u32).init(allocator);
    var root_window_stacking_order = app_state.StackingOrder.init(screen.root, null, allocator);
    const state = app_state.AppState{
        .root_screen_dimensions = root_screen_dimensions,
        .window_map = &window_map,
        .window_to_picture_id_map = &window_to_picture_id_map,
        .window_to_region_id_map = &window_to_region_id_map,
        .window_stacking_order = &root_window_stacking_order,
    };

    // Since the `overlay_window_id` isn't necessarily a 32-bit depth window, we're
    // going to create our own window with 32-bit depth (for alpha/transparency support)
    // with the same dimensions as overlay/root with the `overlay_window_id` as the
    // parent.
    try render.createResources(
        x_request_connection,
        &ids,
        screen,
        &x11_extension_utils.Extensions(&.{ .composite, .render }){
            .composite = extensions.composite,
            .render = extensions.render,
        },
        depth,
        &state,
    );
    // Clean-up and free resources
    defer render.cleanupResources(x_request_connection, &ids) catch |err| {
        std.log.err("Failed to cleanup resoures: {}", .{err});
    };

    // Set the `_NET_WM_PID` atom so we can later find the window ID by the PID
    for ([_]u32{ ids.window, ids.overlay_window_id }) |window_id| {
        {
            const wm_pid_atom = try common.intern_atom(
                x_request_connection.socket,
                x_request_connection.buffer,
                comptime x.Slice(u16, [*]const u8).initComptime("_NET_WM_PID"),
            );

            const pid: u32 = switch (builtin.os.tag) {
                .linux => blk: {
                    const pid = std.os.linux.getpid();
                    if (pid < 0) {
                        std.log.err("Process ID (PID) unexpectedly negative (expected it to be positive) -> {d}", .{pid});
                        return error.ProcessIdUnexpectedlyNegative;
                    }

                    break :blk @intCast(pid);
                },
                .windows => std.os.windows.kernel32.GetCurrentProcessId(),
                else => 0,
            };

            const pid_array = [_]u32{pid};
            const change_property = x.change_property.withFormat(u32);
            var message_buffer: [change_property.getLen(pid_array.len)]u8 = undefined;
            change_property.serialize(&message_buffer, .{
                .mode = .replace,
                .window_id = window_id,
                .property = wm_pid_atom,
                .type = x.Atom.CARDINAL,
                .values = x.Slice(u16, [*]const u32){ .ptr = &pid_array, .len = pid_array.len },
            });
            try x_request_connection.send(&message_buffer);
        }
        // "If _NET_WM_PID is set, the ICCCM-specified property WM_CLIENT_MACHINE MUST also be set."
        // (https://specifications.freedesktop.org/wm-spec/1.3/ar01s05.html#id-1.6.14)
        {
            var host_name_buffer: [std.os.HOST_NAME_MAX]u8 = undefined;
            // "While the ICCCM only requests that WM_CLIENT_MACHINE is set “ to a string
            // that forms the name of the machine running the client as seen from the
            // machine running the server” conformance to this specification requires that
            // WM_CLIENT_MACHINE be set to the fully-qualified domain name of the client's
            // host."
            // (https://specifications.freedesktop.org/wm-spec/1.3/ar01s05.html#id-1.6.14)
            const machine_name = try std.os.gethostname(&host_name_buffer);
            const change_property = x.change_property.withFormat(u8);
            var message_buffer = try allocator.alloc(u8, change_property.getLen(@intCast(machine_name.len)));
            defer allocator.free(message_buffer);
            change_property.serialize(message_buffer.ptr, .{
                .mode = .replace,
                .window_id = window_id,
                .property = x.Atom.WM_CLIENT_MACHINE,
                .type = x.Atom.STRING,
                .values = x.Slice(u16, [*]const u8){ .ptr = machine_name.ptr, .len = @intCast(machine_name.len) },
            });
            try x_request_connection.send(message_buffer);
        }
    }

    // Make the overlay window click-through-able. If you're familiar with CSS, we use
    // this to apply `pointer-events: none;`.
    //
    // We want the pointer events to go through the overlay window and pass to the
    // underlying windows.
    {
        const rectangle_list = [_]x.Rectangle{
            .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        };
        var msg: [x.shape.rectangles.getLen(rectangle_list.len)]u8 = undefined;
        x.shape.rectangles.serialize(&msg, shape_extension.opcode, .{
            .destination_window_id = overlay_window_id,
            .destination_kind = .input,
            .operation = .set,
            .x_offset = 0,
            .y_offset = 0,
            .ordering = .unsorted,
            .rectangles = &rectangle_list,
        });
        try x_request_connection.send(&msg);
    }
    // Also do this to our own 32-bit depth overlay window
    {
        const rectangle_list = [_]x.Rectangle{
            .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        };
        var msg: [x.shape.rectangles.getLen(rectangle_list.len)]u8 = undefined;
        x.shape.rectangles.serialize(&msg, shape_extension.opcode, .{
            .destination_window_id = ids.window,
            .destination_kind = .input,
            .operation = .set,
            .x_offset = 0,
            .y_offset = 0,
            .ordering = .unsorted,
            .rectangles = &rectangle_list,
        });
        try x_request_connection.send(&msg);
    }

    // We want to know when a window is created/destroyed, moved, resized, show/hide,
    // stacking order change, so we can reflect the change.
    {
        var message_buffer: [x.change_window_attributes.max_len]u8 = undefined;
        const len = x.change_window_attributes.serialize(&message_buffer, ids.root, .{
            // `substructure_notify` allows us to listen for all of the `xxx_notify`
            // events like window creation/destruction (i.e.
            // `create_notify`/`destroy_notify`), moved, resized, visibility, stacking
            // order change, etc.
            .event_mask = x.event.substructure_notify,
            // `substructure_redirect` changes how the server handles requests. When
            // `substructure_redirect` is set, instead of the X server processing
            // requests from windows directly, they are redirected to us (the window
            // manager) as `xxx_request` events with the same arguments as the actual
            // request and we can either grant, deny or modify them by making a new
            // request ourselves. For example, if we get a `configure_request` event, we
            // can make a `configure_window` request with what we see fit.
            //
            // | x.event.substructure_redirect,
        });
        // XXX: Use the event connection so we get the events we subscribed to in the
        // `.event_mask` in the event loop
        try x_event_connection.send(message_buffer[0..len]);
    }

    // Show the window. In the X11 protocol is called mapping a window, and hiding a
    // window is called unmapping. When windows are initially created, they are unmapped
    // (or hidden).
    {
        var msg: [x.map_window.len]u8 = undefined;
        x.map_window.serialize(&msg, ids.window);
        try x_request_connection.send(&msg);
    }

    var render_context = render.RenderContext{
        .sock = &x_request_connection.socket,
        .ids = &ids,
        .extensions = &x11_extension_utils.Extensions(&.{ .composite, .render }){
            .composite = extensions.composite,
            .render = extensions.render,
        },
        .state = &state,
    };

    while (true) {
        {
            const receive_buffer = x_event_connection.buffer.nextReadBuffer();
            if (receive_buffer.len == 0) {
                std.log.err("buffer size {} not big enough!", .{x_event_connection.buffer.half_len});
                return error.BufferSizeNotBigEnough;
            }
            const len = try x.readSock(x_event_connect_result.sock, receive_buffer, 0);
            if (len == 0) {
                std.log.info("X server connection closed", .{});
                return;
            }
            x_event_connection.buffer.reserve(len);
        }

        while (true) {
            const data = x_event_connection.buffer.nextReservedBuffer();
            if (data.len < 32)
                break;
            const msg_len: u32 = switch (data[0] & 0x7f) {
                // Let zigx figure out the message length for what it can
                0...35 => x.parseMsgLen(data[0..32].*),
                // But we have to figure out the message length for any extensions
                // because the format of the events is specific to each extension.
                else => |t| blk: {
                    // The damage extension only defines one event type: `damage_notify`
                    const damage_notify = damage_extension.base_event_code;
                    if (t == damage_notify) {
                        break :blk @sizeOf(x.damage.DamageNotifyEvent);
                    }

                    std.debug.panic("We currently do not handle reply type {}", .{t});
                },
            };
            if (data.len < msg_len)
                break;
            x_event_connection.buffer.release(msg_len);

            //buf.resetIfEmpty();
            switch (x.serverMsgTaggedUnion(@alignCast(data.ptr))) {
                .err => |msg| {
                    std.log.err("Received X error: {}", .{msg});
                    return error.ReceivedXError;
                },
                .reply => |msg| {
                    // We should only receive replies over the `x_request_connection`
                    std.log.info("Unexpectedly received reply over the `x_event_connection`: {}", .{msg});
                    return error.UnexpectedXReplyOverEventLoopConnection;
                },
                .expose => |msg| {
                    std.log.info("expose: {}", .{msg});
                    // Render when our 32-bit overlay window is mapped/shown
                    try render_context.render();
                },
                .create_notify => |msg| {
                    std.log.info("create_notify: {}", .{msg});
                    try state.window_map.put(msg.window_id, .{
                        .window_id = msg.window_id,
                        // When windows are initially created, they are unmapped (or
                        // hidden).
                        .visible = false,
                        .x = msg.x_position,
                        .y = msg.y_position,
                        .width = msg.width,
                        .height = msg.height,
                    });

                    // "The window is placed on top in the stacking order with respect to siblings."
                    _ = try state.window_stacking_order.appendNewChild(msg.window_id);

                    // Track damage on the window so we can repaint it.
                    //
                    // We need to create Damage resources with the event connection because the API
                    // couples creating the Damage object with tracking the DamageNotify events.
                    const damage_id = event_connection_id_generator.generateMonotonicId();
                    {
                        var message_buffer: [x.damage.create.len]u8 = undefined;
                        x.damage.create.serialize(&message_buffer, .{
                            .ext_opcode = extensions.damage.opcode,
                            .damage_id = damage_id,
                            .drawable_id = msg.window_id,
                            // We only need to know when there is any damage to the window.
                            // as we're just going to repaint the whole window.
                            .report_level = .non_empty,
                        });
                        // XXX: Use the event connection so we get the DamageNotify events in the event loop
                        try x_event_connection.send(&message_buffer);
                    }
                },
                .destroy_notify => |msg| {
                    std.log.info("destroy_notify: {}", .{msg});

                    _ = state.window_to_picture_id_map.remove(msg.target_window_id);

                    try state.window_stacking_order.removeChild(msg.target_window_id);

                    const opt_region_id = state.window_to_region_id_map.get(msg.target_window_id);
                    if (opt_region_id) |region_id| {
                        var request_message: [x.fixes.destroy_region.len]u8 = undefined;
                        x.fixes.destroy_region.serialize(&request_message, .{
                            .ext_opcode = fixes_extension.opcode,
                            .region_id = region_id,
                        });
                        try x_request_connection.send(&request_message);

                        _ = state.window_to_region_id_map.remove(msg.target_window_id);
                    }

                    // Remove this last in case other things need it during clean-up
                    _ = state.window_map.remove(msg.target_window_id);
                },
                .map_notify => |msg| {
                    std.log.info("map_notify: {}", .{msg});

                    // TODO: NameWindowPixmap, 'window' will get a new pixmap allocated
                    // each time it is mapped or resized, so this request will need to
                    // be reinvoked for the client to continue to refer to the storage
                    // holding the current window contents

                    // We expect an entry to already be in the `window_map` because we
                    // should have received a `create_notify` event before this.
                    const existing_window_entry = state.window_map.get(msg.window) orelse return error.ConfigureNotifyWindowNotFound;

                    // Keep track of the new window visibility
                    try state.window_map.put(msg.window, .{
                        .window_id = msg.window,
                        // Window is now visible
                        .visible = true,
                        .x = existing_window_entry.x,
                        .y = existing_window_entry.y,
                        .width = existing_window_entry.width,
                        .height = existing_window_entry.height,
                    });

                    const window_picture_id = request_connection_id_generator.generateMonotonicId();
                    try x_render_extension.createPictureForWindow(
                        x_request_connection,
                        window_picture_id,
                        msg.window,
                        &x11_extension_utils.Extensions(&.{.render}){
                            .render = extensions.render,
                        },
                    );
                    try state.window_to_picture_id_map.put(msg.window, window_picture_id);

                    // Render after a new window is shown
                    try render_context.render();
                },
                .unmap_notify => |msg| {
                    std.log.info("unmap_notify: {}", .{msg});

                    // We expect an entry to already be in the `window_map` because we
                    // should have received a `create_notify` event before this.
                    const existing_window_entry = state.window_map.get(msg.target_window_id) orelse return error.ConfigureNotifyWindowNotFound;

                    // Keep track of the new window visibility
                    try state.window_map.put(msg.target_window_id, .{
                        .window_id = msg.target_window_id,
                        // Window is now hidden
                        .visible = false,
                        .x = existing_window_entry.x,
                        .y = existing_window_entry.y,
                        .width = existing_window_entry.width,
                        .height = existing_window_entry.height,
                    });

                    // Render after a window is hidden
                    try render_context.render();
                },
                .reparent_notify => |msg| {
                    std.log.info("reparent_notify: {}", .{msg});

                    // "The window is placed on top in the stacking order with respect to siblings."
                    try state.window_stacking_order.reparentChild(msg.window, msg.parent);
                },
                .configure_notify => |msg| {
                    std.log.info("configure_notify: {}", .{msg});

                    // "The window is immediately on top of the specified sibling."
                    if (msg.above_sibling != 0) {
                        const above_sibling_window_id = msg.above_sibling;
                        try state.window_stacking_order.moveChild(
                            msg.window,
                            .after,
                            above_sibling_window_id,
                        );
                    }
                    // "If above-sibling is None, then the window is on the bottom of
                    // the stack with respect to siblings."
                    else {
                        try state.window_stacking_order.moveChild(msg.window, .before, null);
                    }

                    // We expect an entry to already be in the `window_map` because we
                    // should have received a `create_notify` event before this.
                    const existing_window_entry = state.window_map.get(msg.window) orelse return error.ConfigureNotifyWindowNotFound;

                    // Keep track of the new window position and size
                    try state.window_map.put(msg.window, .{
                        .window_id = msg.window,
                        .visible = existing_window_entry.visible,
                        .x = msg.x,
                        .y = msg.y,
                        .width = msg.width,
                        .height = msg.height,
                    });

                    // Add the window to the damage region
                    const region_id = request_connection_id_generator.generateMonotonicId();
                    {
                        var request_message: [x.fixes.create_region_from_window.len]u8 = undefined;
                        x.fixes.create_region_from_window.serialize(&request_message, .{
                            .ext_opcode = fixes_extension.opcode,
                            .region_id = region_id,
                            .window_id = msg.window,
                            .kind = .bounding,
                        });
                        try x_request_connection.send(&request_message);
                    }
                    try state.window_to_region_id_map.put(msg.window, region_id);
                    // TODO: track damage

                    // Render after the window changes position or size
                    try render_context.render();
                },
                .gravity_notify => |msg| {
                    std.log.info("gravity_notify: {}", .{msg});

                    // Render after a window is moved because the parent changed size
                    try render_context.render();
                },
                .circulate_notify => |msg| {
                    std.log.info("circulate_notify: {}", .{msg});

                    // Circulate the window in the stacking order
                    try state.window_stacking_order.moveChild(msg.target_window_id, switch (msg.place) {
                        // 0 -> Top
                        0 => .after,
                        // 1 -> Bottom
                        1 => .before,
                        else => return error.UnexpectedCirculateNotifyPlaceValue,
                    }, null);
                },
                .unhandled => |msg| {
                    // Handle damage notifications
                    const damage_notify = damage_extension.base_event_code;
                    if (@intFromEnum(msg.kind) == damage_notify) {
                        const damage_notify_msg: *x.damage.DamageNotifyEvent = @ptrCast(msg);
                        std.log.info("damage_notify: {}", .{damage_notify_msg});

                        // Render after a region is damaged
                        try render_context.render();

                        // Subtract all the damage, repairing the window.
                        {
                            var message_buffer: [x.damage.subtract.len]u8 = undefined;
                            x.damage.subtract.serialize(&message_buffer, .{
                                .ext_opcode = extensions.damage.opcode,
                                .damage_id = damage_notify_msg.damage_id,
                                // None (0) - So everything is subtracted and repaired
                                .repair_region_id = 0,
                                // None (0) - (this is an output parameter) and we don't care about what was repaired
                                .parts_region_id = 0,
                            });
                            try x_request_connection.send(&message_buffer);
                        }
                    } else {
                        std.log.info("unhandled event: {}", .{msg});
                    }
                },
                else => |msg| {
                    // did not register for these
                    std.log.info("unexpected event: {}", .{msg});
                    return error.UnexpectedEvent;
                },
            }
        }
    }
}

const ChildOutput = struct {
    child_process: *const std.ChildProcess,
    stdout: std.ArrayList(u8),
    stderr: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    /// The process must be started with `stdout_behavior` and `stderr_behavior` set to `.Pipe`
    /// ```
    /// child_process.stdout_behavior = .Pipe;
    /// child_process.stderr_behavior = .Pipe;
    fn init(child_process: *const std.ChildProcess, allocator: std.mem.Allocator) ChildOutput {
        assert(
            child_process.stdout_behavior == .Pipe,
            "child_process.stdout_behavior must be set to .Pipe but saw {}",
            .{child_process.stdout_behavior},
        );
        assert(
            child_process.stderr_behavior == .Pipe,
            "child_process.stderr_behavior must be set to .Pipe {}",
            .{child_process.stderr_behavior},
        );

        return .{
            .child_process = child_process,
            .stdout = std.ArrayList(u8).init(allocator),
            .stderr = std.ArrayList(u8).init(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: @This()) void {
        self.stdout.deinit();
        self.stderr.deinit();
    }

    /// Collect the output text from a child process (stdout and stderr).
    fn collectOutputFromChildProcess(self: *@This()) void {
        self.child_process.collectOutput(
            &self.stdout,
            &self.stderr,
            std.math.maxInt(usize),
        ) catch |err| {
            // Add a placeholder in `stderr` that we failed to collect the logs. This is
            // the most obvious way I can think to communicate this to the user but
            // feels a bit indirect.
            const error_message = std.fmt.allocPrint(
                self.allocator,
                "<Failed to collect output from child process: {}>\n",
                .{err},
            ) catch |allocation_err| {
                // We will give up and just log if we're down to allocation errors
                std.log.err("ChildOutput: Failed to format error message: {} after encountering {}\n", .{ allocation_err, err });
                return;
            };
            defer self.allocator.free(error_message);

            self.stderr.appendSlice(error_message) catch |allocation_err| {
                // We will give up and just log if we're down to allocation errors
                std.log.err("ChildOutput: Failed to append to stderr: {} after encountering {}\n", .{ allocation_err, err });
            };
        };
    }
};

/// Print some debug logs of what the child process printed out (stdout and stderr).
fn printChildOutput(child_output: ChildOutput, allocator: std.mem.Allocator) !void {
    const stdout_separator_spacer = try string_utils.repeatString(
        "=",
        try string_utils.findLengthOfPrintedValue(child_output.stdout.items.len, "{d}", allocator),
        allocator,
    );
    defer allocator.free(stdout_separator_spacer);
    std.debug.print("================= stdout start ({d}) =================\n{s}\n================= stdout end {s}======================\n\n", .{
        child_output.stdout.items.len,
        child_output.stdout.items,
        stdout_separator_spacer,
    });

    const stderr_separator_spacer = try string_utils.repeatString(
        "=",
        try string_utils.findLengthOfPrintedValue(child_output.stderr.items.len, "{d}", allocator),
        allocator,
    );
    defer allocator.free(stderr_separator_spacer);
    std.debug.print("================= stderr start ({d}) =================\n{s}\n================= stderr end {s}======================\n\n", .{
        child_output.stderr.items.len,
        child_output.stderr.items,
        stderr_separator_spacer,
    });
}

// Pulled from `std.ChildProcess.statusToTerm`
fn statusToTerm(status: u32) std.ChildProcess.Term {
    return if (std.os.W.IFEXITED(status))
        .{ .Exited = std.os.W.EXITSTATUS(status) }
    else if (std.os.W.IFSIGNALED(status))
        .{ .Signal = std.os.W.TERMSIG(status) }
    else if (std.os.W.IFSTOPPED(status))
        .{ .Stopped = std.os.W.STOPSIG(status) }
    else
        .{ .Unknown = status };
}

test {
    // https://ziglang.org/documentation/master/#Nested-Container-Tests
    @import("std").testing.refAllDecls(@This());
}

// This test is meant to run on a 300x300 display. Create a virtual display (via Xvfb
// or Xephyr) and point the tests to that display by setting the `DISPLAY` environment
// variable (`DISPLAY=:99 zig build test`).
//
// Example: `Xephyr :99 -screen 1920x1080x24 -retro` (`-retro` to always show cursor)
//
// FIXME: Ideally, this test should be able to be run standalone without any extra setup
// outside to create right size display. By default, it should just run in a headless
// environment and we'd have `Xvfb` as a dependency we build ourselves to run the tests.
// I hate when projects require you to install extra system dependencies to get things
// working. The only thing you should need is the right version of Zig.
test "end-to-end" {
    const allocator = std.testing.allocator;

    // Get ready
    var x_window_finder = try XWindowFinder.init(allocator);
    defer x_window_finder.deinit();

    {
        // Ideally, we'd be able to build and run in the same command like `zig build
        // run-test_window` but https://github.com/ziglang/zig/issues/20853 prevents us from being
        // able to kill the process cleanly. So we have to build and run in separate
        // commands.
        const build_argv = [_][]const u8{ "zig", "build", "main" };
        var build_process = std.ChildProcess.init(&build_argv, allocator);
        // Prevent writing to `stdout` (default is `.Inherit`) so the test runner
        // doesn't hang, see https://github.com/ziglang/zig/issues/15091.
        //
        // We set this to `.Pipe` so we can see the output if the build fails.
        build_process.stdin_behavior = .Ignore;
        build_process.stdout_behavior = .Pipe;
        build_process.stderr_behavior = .Pipe;

        try build_process.spawn();

        // Start collecting logs
        var child_output = ChildOutput.init(&build_process, allocator);
        defer child_output.deinit();
        _ = try std.Thread.spawn(.{}, ChildOutput.collectOutputFromChildProcess, .{&child_output});

        // Wait for the build to finish successfully
        const build_term = try build_process.wait();
        std.testing.expectEqual(std.ChildProcess.Term{ .Exited = 0 }, build_term) catch |err| {
            // Give some more context on why the build failed
            std.debug.print("Failed to build the main compositing manager\n", .{});
            try printChildOutput(child_output, allocator);

            // Return the original assertion error
            return err;
        };
    }

    // Start the compositing manager process.
    const main_process = blk: {
        const main_argv = [_][]const u8{"./zig-out/bin/main"};
        var main_process = std.ChildProcess.init(&main_argv, allocator);
        // Prevent writing to `stdout` (default is `.Inherit`) so the test runner
        // doesn't hang, see https://github.com/ziglang/zig/issues/15091
        //
        // We set this to `.Pipe` so we can see the output if the build fails.
        main_process.stdin_behavior = .Ignore;
        main_process.stdout_behavior = .Pipe;
        main_process.stderr_behavior = .Pipe;

        // Start the compositing manager process.
        try main_process.spawn();

        break :blk &main_process;
    };
    // Start collecting logs
    var main_process_child_output = ChildOutput.init(main_process, allocator);
    defer main_process_child_output.deinit();
    _ = try std.Thread.spawn(.{}, ChildOutput.collectOutputFromChildProcess, .{&main_process_child_output});
    // Kill the process when we're done
    defer _ = main_process.kill() catch |err| {
        std.debug.print("Failed to kill main process: {}\n", .{err});
    };
    // Wait for compositing manager process to be ready. This isn't a perfect solution
    // as we should ideally wait for the window to be mapped and listening for events
    // but it should be good enough and emperically, things seem to work even without
    // waiting here.
    x_window_finder.waitForProcessWindowToBeReady(main_process.id, 1000) catch |err| {
        // Give some more context what happened
        std.debug.print("Failed to find main process window\n", .{});
        try printChildOutput(main_process_child_output, allocator);

        // Return the original assertion error
        return err;
    };

    // Build and create three overlapping test windows
    //
    {
        // Ideally, we'd be able to build and run in the same command like `zig build
        // run-test_window` but https://github.com/ziglang/zig/issues/20853 prevents us from being
        // able to kill the process cleanly. So we have to build and run in separate
        // commands.
        const build_argv = [_][]const u8{ "zig", "build", "test_window" };
        var build_process = std.ChildProcess.init(&build_argv, allocator);
        // Prevent writing to `stdout` (default is `.Inherit`) so the test runner
        // doesn't hang, see https://github.com/ziglang/zig/issues/15091
        //
        // We set this to `.Pipe` so we can see the output if the build fails.
        build_process.stdin_behavior = .Ignore;
        build_process.stdout_behavior = .Pipe;
        build_process.stderr_behavior = .Pipe;

        try build_process.spawn();

        // Start collecting logs
        var child_output = ChildOutput.init(&build_process, allocator);
        defer child_output.deinit();
        _ = try std.Thread.spawn(.{}, ChildOutput.collectOutputFromChildProcess, .{&child_output});

        // Wait for the build to finish successfully
        const build_term = try build_process.wait();
        std.testing.expectEqual(std.ChildProcess.Term{ .Exited = 0 }, build_term) catch |err| {
            // Give some more context on why the build failed
            std.debug.print("Failed to build test window\n", .{});
            try printChildOutput(child_output, allocator);

            // Return the original assertion error
            return err;
        };
    }

    const test_window_process1 = blk: {
        const test_window_argv = [_][]const u8{ "./zig-out/bin/test_window", "50", "0", "0x88ff0000" };
        var test_window_process = std.ChildProcess.init(&test_window_argv, allocator);
        // Prevent writing to `stdout` (default is `.Inherit`) so the test runner
        // doesn't hang, see https://github.com/ziglang/zig/issues/15091
        //
        // We set this to `.Pipe` so we can see the output if the build fails.
        test_window_process.stdin_behavior = .Ignore;
        test_window_process.stdout_behavior = .Pipe;
        test_window_process.stderr_behavior = .Pipe;

        // Start the test_window process.
        try test_window_process.spawn();

        break :blk &test_window_process;
    };
    // Start collecting logs
    var test_window_process1_child_output = ChildOutput.init(test_window_process1, allocator);
    defer test_window_process1_child_output.deinit();
    _ = try std.Thread.spawn(.{}, ChildOutput.collectOutputFromChildProcess, .{&test_window_process1_child_output});
    // Kill the process when we're done
    defer _ = test_window_process1.kill() catch |err| {
        std.debug.print("Failed to kill test window process1: {}\n", .{err});
    };
    // Wait for test window to be ready so we get a consistent stacking order of the test
    // windows. This isn't a perfect solution as we should ideally wait for the window to
    // be mapped but it should be good enough.
    x_window_finder.waitForProcessWindowToBeReady(test_window_process1.id, 1000) catch |err| {
        // Give some more context what happened
        std.debug.print("Failed to find the window for test process1\n", .{});
        try printChildOutput(test_window_process1_child_output, allocator);

        // Return the original assertion error
        return err;
    };

    const test_window_process2 = blk: {
        const test_window_argv = [_][]const u8{ "./zig-out/bin/test_window", "0", "100", "0x8800ff00" };
        var test_window_process = std.ChildProcess.init(&test_window_argv, allocator);
        // Prevent writing to `stdout` (default is `.Inherit`) so the test runner
        // doesn't hang, see https://github.com/ziglang/zig/issues/15091
        //
        // We set this to `.Pipe` so we can see the output if the build fails.
        test_window_process.stdin_behavior = .Ignore;
        test_window_process.stdout_behavior = .Pipe;
        test_window_process.stderr_behavior = .Pipe;

        // Start the test_window process.
        try test_window_process.spawn();

        break :blk &test_window_process;
    };
    // Start collecting logs
    var test_window_process2_child_output = ChildOutput.init(test_window_process2, allocator);
    defer test_window_process2_child_output.deinit();
    _ = try std.Thread.spawn(.{}, ChildOutput.collectOutputFromChildProcess, .{&test_window_process2_child_output});
    // Kill the process when we're done
    defer _ = test_window_process2.kill() catch |err| {
        std.debug.print("Failed to kill test window process2: {}\n", .{err});
    };
    // Wait for test window to be ready so we get a consistent stacking order of the test
    // windows. This isn't a perfect solution as should ideally wait for the window to
    // be mapped but it should be good enough.
    x_window_finder.waitForProcessWindowToBeReady(test_window_process2.id, 1000) catch |err| {
        // Give some more context what happened
        std.debug.print("Failed to find the window for test process2\n", .{});
        try printChildOutput(test_window_process2_child_output, allocator);

        // Return the original assertion error
        return err;
    };

    const test_window_process3 = blk: {
        const test_window_argv = [_][]const u8{ "./zig-out/bin/test_window", "100", "100", "0x880000ff" };
        var test_window_process = std.ChildProcess.init(&test_window_argv, allocator);
        // Prevent writing to `stdout` (default is `.Inherit`) so the test runner
        // doesn't hang, see https://github.com/ziglang/zig/issues/15091
        //
        // We set this to `.Pipe` so we can see the output if the build fails.
        test_window_process.stdin_behavior = .Ignore;
        test_window_process.stdout_behavior = .Pipe;
        test_window_process.stderr_behavior = .Pipe;

        // Start the test_window process.
        try test_window_process.spawn();

        break :blk &test_window_process;
    };
    // Start collecting logs
    var test_window_process3_child_output = ChildOutput.init(test_window_process3, allocator);
    defer test_window_process3_child_output.deinit();
    _ = try std.Thread.spawn(.{}, ChildOutput.collectOutputFromChildProcess, .{&test_window_process3_child_output});
    // Kill the process when we're done
    defer _ = test_window_process3.kill() catch |err| {
        std.debug.print("Failed to kill test window process3: {}\n", .{err});
    };
    // Wait for test window to be ready so we get a consistent stacking order of the test
    // windows. This isn't a perfect solution as should ideally wait for the window to
    // be mapped but it should be good enough.
    x_window_finder.waitForProcessWindowToBeReady(test_window_process3.id, 1000) catch |err| {
        // Give some more context what happened
        std.debug.print("Failed to find the window for test process3\n", .{});
        try printChildOutput(test_window_process3_child_output, allocator);

        // Return the original assertion error
        return err;
    };

    // Just wait some time so we can see that the windows are overlapping and we can see
    // them updating.
    std.time.sleep(2 * std.time.ns_per_s);

    // Assert that the processes are still running succesfully and nothing went wrong
    // during the tests (see
    // https://ziggit.dev/t/any-easy-way-to-check-if-the-childprocess-has-exited/3270)
    const running_test_processes = [_]struct {
        process_description: []const u8,
        child_process: *const std.ChildProcess,
        child_output: ChildOutput,
    }{
        .{
            .process_description = "main compositing manager",
            .child_process = main_process,
            .child_output = main_process_child_output,
        },
        .{
            .process_description = "test window1",
            .child_process = test_window_process1,
            .child_output = test_window_process1_child_output,
        },
        .{
            .process_description = "test window2",
            .child_process = test_window_process2,
            .child_output = test_window_process2_child_output,
        },
        .{
            .process_description = "test window3",
            .child_process = test_window_process3,
            .child_output = test_window_process3_child_output,
        },
    };
    for (running_test_processes) |running_test_process| {
        const wait_result = std.os.waitpid(
            running_test_process.child_process.id,
            // Make `waitpid` run non-blocking
            std.os.W.NOHANG,
        );
        // If `pid` is 0, the process is still running (no state change yet)
        if (wait_result.pid != 0) {
            const term = statusToTerm(wait_result.status);
            std.debug.print(
                "Expected the {s} process to be still be successfully running " ++
                    "at the end of the test but saw {any}\n",
                .{ running_test_process.process_description, term },
            );

            // Give some more context on process might have exited
            try printChildOutput(running_test_process.child_output, allocator);

            return error.ProcessUnexpectedlyNoLongerRunning;
        }
    }
}

// TODO: Test for moving windows around, resizing, stacking order, etc.
