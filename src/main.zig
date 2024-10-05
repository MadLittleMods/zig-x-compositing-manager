const std = @import("std");
const x = @import("x");
const common = @import("x11/x11_common.zig");
const render = @import("compositing_manager/render.zig");
const app_state = @import("compositing_manager/app_state.zig");
const x11_extension_utils = @import("x11/x11_extension_utils.zig");
const x_composite_extension = @import("x11/x_composite_extension.zig");
const x_shape_extension = @import("x11/x_shape_extension.zig");
const x_render_extension = @import("x11/x_render_extension.zig");
const render_utils = @import("utils/render_utils.zig");

// In order to create the total screen presentation we need to create a render picture
// for the root window (or "composite overlay window" if available), and draw the
// windows on it manually, taking the window hierarchy into account.

// We want to use manual redirection so the window contents will be redirected to
// offscreen storage, but not automatically updated on the screen when they're modified.

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
    //    - One exception is that we have to make `x.create_window` or
    //      `x.change_window_attributes` requests with this connection in order to specify the
    //      events that we want to subscribe to.
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

    try x_composite_extension.ensureCompatibleVersionOfXCompositeExtension(
        x_request_connection,
        &composite_extension,
        .{
            // We require version 0.3 of the X Composite extension for the
            // `x.composite.get_overlay_window` request.
            .major_version = 0,
            .minor_version = 3,
        },
    );

    // We use the X Shape extension to make the debug window click-through-able. If
    // you're familiar with CSS, we use this to apply `pointer-events: none;`.
    const optional_shape_extension = try x11_extension_utils.getExtensionInfo(
        x_request_connection,
        "SHAPE",
    );
    const shape_extension = optional_shape_extension orelse @panic("X SHAPE extension not found");

    try x_shape_extension.ensureCompatibleVersionOfXShapeExtension(
        x_request_connection,
        &shape_extension,
        .{
            // We arbitrarily require version 1.1 of the X Shape extension
            // because that's the latest version and is sufficiently old
            // and ubiquitous.
            .major_version = 1,
            .minor_version = 1,
        },
    );

    // We use the X Render extension for capturing screenshots and splatting them onto
    // our window. Useful because their "composite" request works with mismatched depths
    // between the source and destinations.
    const optional_render_extension = try x11_extension_utils.getExtensionInfo(
        x_request_connection,
        "RENDER",
    );
    const render_extension = optional_render_extension orelse @panic("RENDER extension not found");

    try x_render_extension.ensureCompatibleVersionOfXRenderExtension(
        x_request_connection,
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

    // Assemble a map of X extension info
    const extensions = x11_extension_utils.Extensions(&.{ .composite, .shape, .render }){
        .composite = composite_extension,
        .shape = shape_extension,
        .render = render_extension,
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

    var ids = render.Ids.init(
        screen.root,
        overlay_window_id,
        x_event_connect_result.setup.fixed().resource_id_base,
    );
    std.log.debug("ids: {any}", .{ids});
    var request_id_generator = render.IdGenerator.init(
        x_request_connect_result.setup.fixed().resource_id_base,
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
    const state = app_state.AppState{
        .root_screen_dimensions = root_screen_dimensions,
        .window_map = &window_map,
        .window_to_picture_id_map = &window_to_picture_id_map,
    };

    // Since the `overlay_window_id` isn't necessarily a 32-bit depth window, we're
    // going to create our own window with 32-bit depth with the same dimensions as
    // overlay/root with the `overlay_window_id` as the parent.
    try render.createResources(
        // XXX: We have to use the `x_event_connection` in because this calls
        // `x.create_window` and configures which events we should listen to in the
        // `.event_mask`
        x_event_connection,
        &ids,
        screen,
        &extensions,
        depth,
        &state,
    );

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
        // XXX: We have to use the `x_event_connection` in because we're specifying
        // which events we should listen to in the `.event_mask`
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
        .extensions = &extensions,
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
            const msg_len = x.parseMsgLen(data[0..32].*);
            if (data.len < msg_len)
                break;
            x_event_connection.buffer.release(msg_len);

            //buf.resetIfEmpty();
            switch (x.serverMsgTaggedUnion(@alignCast(data.ptr))) {
                .err => |msg| {
                    std.log.err("Received X error: {}", .{msg});
                    return error.ReceivedXError;
                },
                // When our 32-bit overlay window is mapped/shown
                .expose => |msg| {
                    std.log.info("expose: {}", .{msg});
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
                },
                .destroy_notify => |msg| {
                    std.log.info("destroy_notify: {}", .{msg});
                    _ = state.window_map.remove(msg.target_window_id);
                    _ = state.window_to_picture_id_map.remove(msg.target_window_id);
                },
                .map_notify => |msg| {
                    std.log.info("map_notify: {}", .{msg});

                    // TODO: NameWindowPixmap, 'window' will get a new pixmap allocated
                    // each time it is mapped or resized, so this request will need to
                    // be reinvoked for the client to continue to refer to the storage
                    // holding the current window contents

                    const window_picture_id = request_id_generator.generateMonotonicId();
                    try x_render_extension.createPictureForWindow(
                        x_request_connection,
                        window_picture_id,
                        msg.window,
                        &x11_extension_utils.Extensions(&.{.render}){
                            .render = extensions.render,
                        },
                    );
                    try state.window_to_picture_id_map.put(msg.window, window_picture_id);

                    try render_context.render();
                },
                .unmap_notify => |msg| {
                    std.log.info("unmap_notify: {}", .{msg});
                },
                .reparent_notify => |msg| {
                    std.log.info("reparent_notify: {}", .{msg});
                },
                .configure_notify => |msg| {
                    std.log.info("configure_notify: {}", .{msg});
                },
                .gravity_notify => |msg| {
                    std.log.info("gravity_notify: {}", .{msg});
                },
                .circulate_notify => |msg| {
                    std.log.info("circulate_notify: {}", .{msg});
                },
                else => |msg| {
                    // did not register for these
                    std.log.info("unexpected event: {}", .{msg});
                    return error.UnexpectedEvent;
                },
            }
        }
    }

    // TODO: Remove
    // Keep the process running indefinitely
    while (true) {
        std.time.sleep(60 * std.time.ns_per_s);
    }
}

// This test is meant to run on a 300x300 display. Create a virtual display (via Xvfb
// or Xephyr) and point the tests to that display by setting the `DISPLAY` environment
// variable (`DISPLAY=:99 zig build test`).
//
// FIXME: Ideally, this test should be able to be run standalone without any extra setup
// outside to create right size display. By default, it should just run in a headless
// environment and we'd have `Xvfb` as a dependency we build ourselves to run the tests.
// I hate when projects require you to install extra system dependencies to get things
// working. The only thing you should need is the right version of Zig.
test "end-to-end" {
    const allocator = std.testing.allocator;

    {
        // Ideally, we'd be able to build and run in the same command like `zig build
        // run-test_window` but https://github.com/ziglang/zig/issues/20853 prevents us from being
        // able to kill the process cleanly. So we have to build and run in separate
        // commands.
        const build_argv = [_][]const u8{ "zig", "build", "main" };
        var build_process = std.ChildProcess.init(&build_argv, allocator);
        // Prevent writing to `stdout` so the test runner doesn't hang,
        // see https://github.com/ziglang/zig/issues/15091
        build_process.stdin_behavior = .Ignore;
        build_process.stdout_behavior = .Ignore;
        build_process.stderr_behavior = .Ignore;

        try build_process.spawn();
        const build_term = try build_process.wait();
        try std.testing.expectEqual(std.ChildProcess.Term{ .Exited = 0 }, build_term);
    }

    // Start the compositing manager process.
    const main_process = blk: {
        const main_argv = [_][]const u8{"./zig-out/bin/main"};
        var main_process = std.ChildProcess.init(&main_argv, allocator);
        // Prevent writing to `stdout` so the test runner doesn't hang,
        // see https://github.com/ziglang/zig/issues/15091
        //
        // TODO: Uncomment and make it so we log the output if the test fails
        // main_process.stdin_behavior = .Ignore;
        // main_process.stdout_behavior = .Ignore;
        // main_process.stderr_behavior = .Ignore;

        // Start the compositing manager process.
        try main_process.spawn();

        break :blk &main_process;
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
        // Prevent writing to `stdout` so the test runner doesn't hang,
        // see https://github.com/ziglang/zig/issues/15091
        build_process.stdin_behavior = .Ignore;
        build_process.stdout_behavior = .Ignore;
        build_process.stderr_behavior = .Ignore;

        try build_process.spawn();
        const build_term = try build_process.wait();
        try std.testing.expectEqual(std.ChildProcess.Term{ .Exited = 0 }, build_term);
    }

    const test_window_process1 = blk: {
        const test_window_argv = [_][]const u8{ "./zig-out/bin/test_window", "50", "0", "0xaaff0000" };
        var test_window_process = std.ChildProcess.init(&test_window_argv, allocator);
        // Prevent writing to `stdout` so the test runner doesn't hang,
        // see https://github.com/ziglang/zig/issues/15091
        test_window_process.stdin_behavior = .Ignore;
        test_window_process.stdout_behavior = .Ignore;
        test_window_process.stderr_behavior = .Ignore;

        // Start the test_window process.
        try test_window_process.spawn();

        break :blk &test_window_process;
    };

    const test_window_process2 = blk: {
        const test_window_argv = [_][]const u8{ "./zig-out/bin/test_window", "0", "100", "0xaa00ff00" };
        var test_window_process = std.ChildProcess.init(&test_window_argv, allocator);
        // Prevent writing to `stdout` so the test runner doesn't hang,
        // see https://github.com/ziglang/zig/issues/15091
        test_window_process.stdin_behavior = .Ignore;
        test_window_process.stdout_behavior = .Ignore;
        test_window_process.stderr_behavior = .Ignore;

        // Start the test_window process.
        try test_window_process.spawn();

        break :blk &test_window_process;
    };

    const test_window_process3 = blk: {
        const test_window_argv = [_][]const u8{ "./zig-out/bin/test_window", "100", "100", "0xaa0000ff" };
        var test_window_process = std.ChildProcess.init(&test_window_argv, allocator);
        // Prevent writing to `stdout` so the test runner doesn't hang,
        // see https://github.com/ziglang/zig/issues/15091
        test_window_process.stdin_behavior = .Ignore;
        test_window_process.stdout_behavior = .Ignore;
        test_window_process.stderr_behavior = .Ignore;

        // Start the test_window process.
        try test_window_process.spawn();

        break :blk &test_window_process;
    };

    std.time.sleep(2 * std.time.ns_per_s);

    _ = try test_window_process1.kill();
    _ = try test_window_process2.kill();
    _ = try test_window_process3.kill();
    _ = try main_process.kill();
}
