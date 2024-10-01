const std = @import("std");
const x = @import("x");
const common = @import("x11/x11_common.zig");
const render = @import("test_window/render.zig");
const AppState = @import("test_window/app_state.zig").AppState;
const render_utils = @import("utils/render_utils.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer switch (gpa.deinit()) {
        .ok => {},
        .leak => std.log.err("GPA allocator: Memory leak detected", .{}),
    };

    try x.wsaStartup();
    const conn = try common.connect(allocator);
    defer std.os.shutdown(conn.sock, .both) catch {};
    defer conn.setup.deinit(allocator);
    const conn_setup_fixed_fields = conn.setup.fixed();
    // Print out some info about the X server we connected to
    {
        inline for (@typeInfo(@TypeOf(conn_setup_fixed_fields.*)).Struct.fields) |field| {
            std.log.debug("{s}: {any}", .{ field.name, @field(conn_setup_fixed_fields, field.name) });
        }
        std.log.debug("vendor: {s}", .{try conn.setup.getVendorSlice(conn_setup_fixed_fields.vendor_len)});
    }

    const screen = common.getFirstScreenFromConnectionSetup(conn.setup);
    inline for (@typeInfo(@TypeOf(screen.*)).Struct.fields) |field| {
        std.log.debug("SCREEN 0| {s}: {any}", .{ field.name, @field(screen, field.name) });
    }

    std.log.info("root window ID {0} 0x{0x}", .{screen.root});
    const ids = render.Ids.init(
        screen.root,
        conn.setup.fixed().resource_id_base,
    );
    std.log.debug("ids: {any}", .{ids});

    const depth = 32;

    // Create a big buffer that we can use to read messages and replies from the X server.
    const double_buffer = try x.DoubleBuffer.init(
        std.mem.alignForward(usize, 8000, std.mem.page_size),
        .{ .memfd_name = "ZigX11DoubleBuffer" },
    );
    defer double_buffer.deinit(); // not necessary but good to test
    std.log.info("Read buffer capacity is {}", .{double_buffer.half_len});
    var buffer = double_buffer.contiguousReadBuffer();
    const buffer_limit = buffer.half_len;

    // TODO: maybe need to call conn.setup.verify or something?

    const state = AppState{
        .window_position = render_utils.Coordinate(i16){ .x = 0, .y = 0 },
        .window_dimensions = render_utils.Dimensions{ .width = 200, .height = 200 },
        .start_timestamp_ms = std.time.milliTimestamp(),
    };

    try render.createResources(
        conn.sock,
        &buffer,
        &ids,
        screen,
        depth,
        &state,
    );

    // Get some font information
    //
    // FIXME: Might be better to use `x.query_font` instead
    {
        // We're using an "m" character because it's typically the widest character in the font
        const text_literal = [_]u16{'m'};
        const text = x.Slice(u16, [*]const u16){ .ptr = &text_literal, .len = text_literal.len };
        var message_buffer: [x.query_text_extents.getLen(text.len)]u8 = undefined;
        x.query_text_extents.serialize(&message_buffer, ids.fg_gc, text);
        try conn.send(&message_buffer);
    }
    const font_dims: render_utils.FontDims = blk: {
        const message_length = try x.readOneMsg(conn.reader(), @alignCast(buffer.nextReadBuffer()));
        try common.checkMessageLengthFitsInBuffer(message_length, buffer_limit);
        switch (x.serverMsgTaggedUnion(@alignCast(buffer.double_buffer_ptr))) {
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
        try conn.send(&msg);
    }

    var render_context = render.RenderContext{
        .sock = &conn.sock,
        .ids = &ids,
        .font_dims = &font_dims,
        .state = &state,
    };

    // Keep drawing the window so the elapsed time is updated
    while (true) {
        try render_context.render();
        // We don't need to render so often as the display refresh rate is only so fast.
        // Let's just say 120hz since it's not that important.
        std.time.sleep(8 * std.time.ns_per_ms);
    }

    // while (true) {
    //     {
    //         const receive_buffer = buffer.nextReadBuffer();
    //         if (receive_buffer.len == 0) {
    //             std.log.err("buffer size {} not big enough!", .{buffer.half_len});
    //             return error.BufferSizeNotBigEnough;
    //         }
    //         const len = try x.readSock(conn.sock, receive_buffer, 0);
    //         if (len == 0) {
    //             std.log.info("X server connection closed", .{});
    //             return;
    //         }
    //         buffer.reserve(len);
    //     }

    //     while (true) {
    //         const data = buffer.nextReservedBuffer();
    //         if (data.len < 32)
    //             break;
    //         const msg_len = x.parseMsgLen(data[0..32].*);
    //         if (data.len < msg_len)
    //             break;
    //         buffer.release(msg_len);

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

    // Clean-up
    try render.cleanupResources(ids);
}
