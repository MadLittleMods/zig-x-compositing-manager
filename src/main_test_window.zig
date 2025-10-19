const std = @import("std");
const builtin = @import("builtin");
const assertions = @import("utils/assertions.zig");
const assert = assertions.assert;
const x = @import("x");
const common = @import("x11/x11_common.zig");
const render = @import("test_window/render.zig");
const AppState = @import("test_window/app_state.zig").AppState;
const render_utils = @import("utils/render_utils.zig");

/// Renders a 200x200 colored square at the specified coordinates, with text in
/// the center that shows the application's runtime duration since launch
///
/// Example:
/// DISPLAY=:99 zig build run-test_window -- 0 0 0xaaff6622
///
/// Demo mode example:
/// DISPLAY=:99 zig build run-test_window -- 0 0 0xaaff6622 demo 0 3
///
/// Arg 0: X position
/// Arg 1: Y position
/// Arg 2: Window background color
/// Arg 3: Demo mode (optional)
/// Arg 3: Demo mode window index (optional, 0-based)
/// Arg 3: Demo mode number of windows total (optional)
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer switch (gpa.deinit()) {
        .ok => {},
        .leak => std.log.err("GPA allocator: Memory leak detected", .{}),
    };

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const position_x = try std.fmt.parseInt(i16, args[1], 10);
    const position_y = try std.fmt.parseInt(i16, args[2], 10);
    // 0xAARRGGBB
    const window_background_color = try std.fmt.parseInt(
        u32,
        args[3],
        // When the base is 0, it will automatically detect the base from the string prefix
        0,
    );

    // Optional demo mode that will animate the windows around in a pattern
    var demo_mode: bool = false;
    var demo_mode_window_index: u32 = 0;
    var demo_mode_num_windows: u32 = 1;
    if (args.len > 4) {
        demo_mode = args[4].len > 0;
        demo_mode_window_index = try std.fmt.parseInt(u32, args[5], 10);
        demo_mode_num_windows = try std.fmt.parseInt(u32, args[6], 10);
    }

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

    // Since each connection has a `base_resource_id`, let's create most resources with
    // the request connection since that's easier
    var request_connection_id_generator = render.IdGenerator.init(
        x_request_connect_result.setup.fixed().resource_id_base,
    );
    const ids = render.Ids.init(
        screen.root,
        &request_connection_id_generator,
    );
    std.log.debug("ids: {any}", .{ids});
    std.log.info("ids.window {0} 0x{0x}", .{ids.window});

    const depth = 32;

    var state = AppState{
        .window_position = render_utils.Coordinate(i16){ .x = position_x, .y = position_y },
        .window_dimensions = render_utils.Dimensions{ .width = 200, .height = 200 },
        .window_background_color = window_background_color,
        .start_timestamp_ms = std.time.milliTimestamp(),
    };

    try render.createResources(
        x_request_connection,
        &ids,
        screen,
        depth,
        &state,
    );
    // Clean-up and free resources
    defer render.cleanupResources(x_request_connection, &ids) catch |err| {
        std.log.err("Failed to cleanup resoures: {}", .{err});
    };

    // Set the `_NET_WM_PID` atom so we can later find the window ID by the PID
    {
        const wm_pid_atom = try common.intern_atom(
            x_request_connection,
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
            .window_id = ids.window,
            .property = wm_pid_atom,
            .type = x.Atom.CARDINAL,
            .values = x.Slice(u16, [*]const u32){ .ptr = &pid_array, .len = pid_array.len },
        });
        try x_request_connection.send(message_buffer[0..]);
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
            .window_id = ids.window,
            .property = x.Atom.WM_CLIENT_MACHINE,
            .type = x.Atom.STRING,
            .values = x.Slice(u16, [*]const u8){ .ptr = machine_name.ptr, .len = @intCast(machine_name.len) },
        });
        try x_request_connection.send(message_buffer);
    }

    // Get some font information
    //
    // FIXME: Might be better to use `x.query_font` instead
    {
        // We're using an "m" character because it's typically the widest character in the font
        const text_literal = [_]u16{'m'};
        const text = x.Slice(u16, [*]const u16){ .ptr = &text_literal, .len = text_literal.len };
        var message_buffer: [x.query_text_extents.getLen(text.len)]u8 = undefined;
        x.query_text_extents.serialize(&message_buffer, ids.fg_gc, text);
        try x_request_connection.send(&message_buffer);
    }
    const font_dims: render_utils.FontDims = blk: {
        const message_length = try x.readOneMsg(x_request_connection.reader(), @alignCast(x_request_connection.buffer.nextReadBuffer()));
        try common.checkMessageLengthFitsInBuffer(message_length, x_request_connection.buffer.half_len);
        switch (x.serverMsgTaggedUnion(@alignCast(x_request_connection.buffer.double_buffer_ptr))) {
            .reply => |msg_reply| {
                const msg: *x.ServerMsg.QueryTextExtents = @ptrCast(msg_reply);
                break :blk .{
                    .width = @intCast(msg.overall_width),
                    .height = @intCast(msg.font_ascent + msg.font_descent),
                    .font_left = @intCast(msg.overall_left),
                    .font_ascent = msg.font_ascent,
                };
            },
            else => |msg| {
                std.log.err("expected a reply for `x.query_text_extents` but got {}", .{msg});
                return error.ExpectedReplyForQueryTextExtents;
            },
        }
    };

    // Show the window. In the X11 protocol is called mapping a window, and hiding a
    // window is called unmapping. When windows are initially created, they are unmapped
    // (or hidden).
    {
        var msg: [x.map_window.len]u8 = undefined;
        x.map_window.serialize(&msg, ids.window);
        try x_request_connection.send(&msg);
    }

    var render_context = render.RenderContext{
        .x_connection = x_request_connection,
        .ids = &ids,
        .font_dims = &font_dims,
        .state = &state,
    };

    var demo_animation = DemoAnimation.init(.{
        .window_index = demo_mode_window_index,
        .num_windows = demo_mode_num_windows,
    }, &state);

    var previous_timestamp_ms = std.time.milliTimestamp();
    while (true) {
        if (demo_mode) {
            // Calculate delta time
            const current_timestamp_ms = std.time.milliTimestamp();
            defer previous_timestamp_ms = current_timestamp_ms;
            const delta_time_ms = current_timestamp_ms - previous_timestamp_ms;
            const delta_time_ms_float = @as(f32, @floatFromInt(delta_time_ms));

            demo_animation.animate(delta_time_ms_float);

            // Update the window
            {
                var msg: [x.configure_window.max_len]u8 = undefined;
                const len = x.configure_window.serialize(&msg, .{
                    .window_id = ids.window,
                }, .{
                    .x = state.window_position.x,
                    .y = state.window_position.y,
                    .width = @intCast(state.window_dimensions.width),
                    .height = @intCast(state.window_dimensions.height),
                });
                try x_request_connection.send(msg[0..len]);
            }
        }

        // Keep drawing the window so the elapsed time is updated. We just want *something*
        // that changes to show that the window contents are being updated when using the
        // "compositing manager".
        try render_context.render();

        // We don't need to render so often as the display refresh rate is only so fast.
        // Let's just say 120hz since it's not that important. This is just a cheap way
        // to prevent "spinning" and doesn't account for the rest of the time it takes
        // to render the window.
        std.time.sleep(8 * std.time.ns_per_ms);
    }

    // while (true) {
    //     {
    //         const receive_buffer = x_event_connection.buffer.nextReadBuffer();
    //         if (receive_buffer.len == 0) {
    //             std.log.err("buffer size {} not big enough!", .{x_event_connection.buffer.half_len});
    //             return error.BufferSizeNotBigEnough;
    //         }
    //         const len = try x.readSock(x_event_connection.socket, receive_buffer, 0);
    //         if (len == 0) {
    //             std.log.info("X server connection closed", .{});
    //             return;
    //         }
    //         x_event_connection.buffer.reserve(len);
    //     }

    //     while (true) {
    //         const data = x_event_connection.buffer.nextReservedBuffer();
    //         if (data.len < 32)
    //             break;
    //         const msg_len = x.parseMsgLen(data[0..32].*);
    //         if (data.len < msg_len)
    //             break;
    //         x_event_connection.buffer.release(msg_len);

    //         //buf.resetIfEmpty();
    //         switch (x.serverMsgTaggedUnion(@alignCast(data.ptr))) {
    //             .err => |msg| {
    //                 std.log.err("Received X error: {}", .{msg});
    //                 return error.ReceivedXError;
    //             },
    //             .reply => |msg| {
    //                 std.log.info("todo: handle a reply message {}", .{msg});
    //                 return error.TodoHandleReplyMessage;
    //             },
    //             .generic_extension_event => |msg| {
    //                 std.debug.panic("unexpected generic extension event {}", .{msg});
    //             },
    //             .key_press => |msg| {
    //                 std.log.info("key_press: keycode={}", .{msg.keycode});
    //             },
    //             .key_release => |msg| {
    //                 std.log.info("key_release: keycode={}", .{msg.keycode});
    //             },
    //             .button_press => |msg| {
    //                 std.log.info("button_press: {}", .{msg});
    //             },
    //             .button_release => |msg| {
    //                 std.log.info("button_release: {}", .{msg});
    //             },
    //             .enter_notify => |msg| {
    //                 std.log.info("enter_window: {}", .{msg});
    //             },
    //             .leave_notify => |msg| {
    //                 std.log.info("leave_window: {}", .{msg});
    //             },
    //             .motion_notify => |_| {
    //                 // too much logging
    //                 //std.log.info("pointer_motion: {}", .{msg});
    //             },
    //             .keymap_notify => |msg| {
    //                 std.log.info("keymap_state: {}", .{msg});
    //             },
    //             .expose => |msg| {
    //                 std.log.info("expose: {}", .{msg});
    //                 try render_context.render();
    //             },
    //             .mapping_notify => |msg| {
    //                 std.log.info("mapping_notify: {}", .{msg});
    //             },
    //             .no_exposure => |msg| {
    //                 std.debug.panic("unexpected no_exposure event {}", .{msg});
    //             },
    //             .unhandled => |msg| {
    //                 std.log.info("todo: server msg {}", .{msg});
    //                 return error.UnhandledServerMsg;
    //             },
    //             .map_notify,
    //             .reparent_notify,
    //             .configure_notify,
    //             => unreachable, // did not register for these
    //         }
    //     }
    // }
}

const DemoAnimationConfig = struct {
    center_x: f32 = 75,
    center_y: f32 = 75,
    radius: f32 = 75,
    speed_radians_per_ms: f32 = (@as(f32, 0.5) * std.math.pi) / std.time.ms_per_s,
    scale_per_ms: f32 = @as(f32, 4) / std.time.ms_per_s,

    window_index: u32,
    num_windows: u32,
};

const DemoAnimation = struct {
    app_state: *AppState,

    config: DemoAnimationConfig,
    start_timestamp_ms: i64,
    current_angle_radians: f32,

    fn init(config: DemoAnimationConfig, app_state: *AppState) DemoAnimation {
        assert(config.num_windows > 0, "num_windows must be greater than 0", .{});

        return .{
            .app_state = app_state,
            .start_timestamp_ms = std.time.milliTimestamp(),
            .config = config,
            .current_angle_radians = (2 * std.math.pi) * (@as(f32, @floatFromInt(config.window_index + 1)) /
                @as(f32, @floatFromInt(config.num_windows))),
        };
    }

    fn animate(self: *@This(), delta_time_ms_float: f32) void {
        const current_timestamp_ms = std.time.milliTimestamp();
        const elapsed_ms = current_timestamp_ms - self.start_timestamp_ms;
        const elapsed_ms_float: f32 = @floatFromInt(elapsed_ms);

        const new_angle_radians = self.current_angle_radians + (delta_time_ms_float * (self.config.speed_radians_per_ms));
        defer self.current_angle_radians = new_angle_radians;

        const x_position: f32 = self.config.center_x + self.config.radius * @cos(
            new_angle_radians,
        );
        const y_position: f32 = self.config.center_y + self.config.radius * @sin(
            new_angle_radians,
        );

        self.app_state.window_position.x = @intFromFloat(x_position);
        self.app_state.window_position.y = @intFromFloat(y_position);

        const scale_normalized = pingPong(elapsed_ms_float * self.config.scale_per_ms);

        self.app_state.window_dimensions.width = @intFromFloat(200 - (200 * 0.2 * scale_normalized));
        self.app_state.window_dimensions.height = @intFromFloat(200 - (200 * 0.2 * scale_normalized));
    }
};

/// A periodic function that generates a triangle wave oscillating between 0 and 1.
//
// We could also accomplish this with `((arcsin(sin(pi*x - (pi/2)))) / pi) + 0.5` but
// this is probably simpler
fn pingPong(t: f32) f32 {
    const asdf: f32 = (t - 1.0) / 2.0;
    const fractional_part = asdf - @floor(asdf);
    std.debug.print("asdf t: {d}, asdf: {d} {d}, fractional_part: {d} - {d} {d}\n", .{ t, asdf, @floor(asdf), fractional_part, fractional_part * 2.0 - 1.0, std.math.fabs(fractional_part * 2.0 - 1.0) });
    return std.math.fabs(fractional_part * 2.0 - 1.0);
}
