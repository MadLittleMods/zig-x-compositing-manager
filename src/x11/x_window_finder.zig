const std = @import("std");
const builtin = @import("builtin");
const assertions = @import("../utils/assertions.zig");
const assert = assertions.assert;
const x = @import("x");
const common = @import("x11_common.zig");
const x11_extension_utils = @import("x11_extension_utils.zig");
const x_composite_extension = @import("x_composite_extension.zig");

const log = std.log.scoped(.x_window_finder);

/// Good to wait or find a X11 window to be created and ready for a given process ID.
pub const XWindowFinder = struct {
    allocator: std.mem.Allocator,
    root_window_id: u32,
    x_request_connection: common.XConnection,
    x_extensions: x11_extension_utils.Extensions(&.{.composite}),
    wm_pid_atom: x.Atom,

    pub fn init(allocator: std.mem.Allocator) !@This() {
        try x.wsaStartup();

        // Create an X connection for making one-off requests
        const x_event_connect_result = try common.connect(allocator);
        defer x_event_connect_result.setup.deinit(allocator);
        const x_request_connect_result = try common.connect(allocator);
        defer x_request_connect_result.setup.deinit(allocator);
        const x_request_connection = try common.XConnection.init(
            x_request_connect_result.sock,
            8000,
            allocator,
        );

        const screen = common.getFirstScreenFromConnectionSetup(x_event_connect_result.setup);
        // inline for (@typeInfo(@TypeOf(screen.*)).Struct.fields) |field| {
        //     log.debug("SCREEN 0| {s}: {any}", .{ field.name, @field(screen, field.name) });
        // }
        // log.info("root window ID {0} 0x{0x}", .{screen.root});

        const wm_pid_atom = try common.intern_atom(
            x_request_connection,
            comptime x.Slice(u16, [*]const u8).initComptime("_NET_WM_PID"),
        );

        // We use the X Composite extension to get the composite overlay window ID
        // because it does not show up when you list the windows via `query_tree`
        // (hidden to clients).
        const optional_composite_extension = try x11_extension_utils.getExtensionInfo(
            x_request_connection,
            "Composite",
        );
        const composite_extension = optional_composite_extension orelse @panic("X Composite extension extension not found");

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

        // Assemble a map of X extension info
        const extensions = x11_extension_utils.Extensions(&.{.composite}){
            .composite = composite_extension,
        };

        const x_event_listener = @This(){
            .allocator = allocator,
            .root_window_id = screen.root,
            .x_request_connection = x_request_connection,
            .x_extensions = extensions,
            .wm_pid_atom = wm_pid_atom,
        };

        return x_event_listener;
    }

    pub fn deinit(self: @This()) void {
        // Clean up our memory.
        self.x_request_connection.deinit();
    }

    /// Wait until we see a X window for the given process ID.
    pub fn waitForProcessWindowToBeReady(
        self: *@This(),
        process_id: std.ChildProcess.Id,
        timeout_ms: u64,
    ) !void {
        const start_time_ts = std.time.milliTimestamp();

        while (true) {
            const current_time_ts = std.time.milliTimestamp();
            if (current_time_ts - start_time_ts > timeout_ms) {
                return error.Timeout;
            }

            const opt_window_id = try self.findWindowIdByProcessId(process_id);
            if (opt_window_id) |window_id| {
                _ = window_id;
                return;
            }

            // Prevent tight-looping and hogging the CPU/socket traffic
            std.time.sleep(10);
        }
    }

    /// This only looks in the direct children of the root window.
    fn findWindowIdByProcessId(self: @This(), process_id: std.ChildProcess.Id) !?u32 {
        const allocator = self.allocator;

        // First, list all the child windows of the root window
        {
            var message_buffer: [x.query_tree.len]u8 = undefined;
            x.query_tree.serialize(&message_buffer, self.root_window_id);
            try self.x_request_connection.send(message_buffer[0..]);
        }
        const window_list = blk: {
            const message_length = try x.readOneMsg(self.x_request_connection.reader(), @alignCast(self.x_request_connection.buffer.nextReadBuffer()));
            try common.checkMessageLengthFitsInBuffer(message_length, self.x_request_connection.buffer.half_len);
            switch (x.serverMsgTaggedUnion(@alignCast(self.x_request_connection.buffer.double_buffer_ptr))) {
                .reply => |msg_reply| {
                    const msg: *x.query_tree.Reply = @ptrCast(msg_reply);
                    log.debug("query_tree found {d} child windows", .{msg.num_windows});

                    const owned_window_list = try allocator.alignedAlloc(u32, 4, msg.num_windows);
                    @memcpy(owned_window_list, msg.getWindowList());

                    break :blk owned_window_list;
                },
                else => |msg| {
                    log.err("expected a reply for `x.query_tree` but got {}", .{msg});
                    return error.ExpectedReplyForQueryTree;
                },
            }
        };
        defer allocator.free(window_list);

        for (window_list) |window_id| {
            const opt_process_id = try self.fetchProcessIdForWindowId(window_id);
            if (opt_process_id) |window_process_id| {
                if (window_process_id == process_id) {
                    return window_id;
                }
            }
        }

        // As a last ditch effort, check for the composite overlay window which is
        // normally not available to clients.
        {
            {
                var message_buffer: [x.composite.get_overlay_window.len]u8 = undefined;
                x.composite.get_overlay_window.serialize(&message_buffer, self.x_extensions.composite.opcode, .{
                    .window_id = self.root_window_id,
                });
                try self.x_request_connection.send(&message_buffer);
            }
            const overlay_window_id = blk: {
                const message_length = try x.readOneMsg(
                    self.x_request_connection.reader(),
                    @alignCast(self.x_request_connection.buffer.nextReadBuffer()),
                );
                // const msg = try common.asReply(
                //     x.composite.get_overlay_window.Reply,
                //     @alignCast(x_request_connection.buffer.double_buffer_ptr[0..message_length]),
                // );
                // break :blk msg.overlay_window_id;

                try common.checkMessageLengthFitsInBuffer(message_length, self.x_request_connection.buffer.half_len);
                switch (x.serverMsgTaggedUnion(@alignCast(self.x_request_connection.buffer.double_buffer_ptr))) {
                    .reply => |msg_reply| {
                        const msg: *x.composite.get_overlay_window.Reply = @ptrCast(msg_reply);
                        break :blk msg.overlay_window_id;
                    },
                    else => |msg| {
                        log.err("expected a reply for `x.composite.get_overlay_window` but got {}", .{msg});
                        return error.ExpectedReplyForGetOverlayWindow;
                    },
                }
            };

            const opt_process_id = try self.fetchProcessIdForWindowId(overlay_window_id);
            if (opt_process_id) |window_process_id| {
                if (window_process_id == process_id) {
                    return overlay_window_id;
                }
            }
        }

        return null;
    }

    /// Fetch the process ID property (`_NET_WM_PID` atom) of the window
    fn fetchProcessIdForWindowId(self: @This(), window_id: u32) !?u32 {
        {
            var message_buffer: [x.get_property.len]u8 = undefined;
            x.get_property.serialize(&message_buffer, .{
                .window_id = window_id,
                .property = self.wm_pid_atom,
                .type = x.Atom.CARDINAL,
                .offset = 0,
                .len = 8,
                .delete = false,
            });
            try self.x_request_connection.send(message_buffer[0..]);
        }
        const message_length = try x.readOneMsg(self.x_request_connection.reader(), @alignCast(self.x_request_connection.buffer.nextReadBuffer()));
        try common.checkMessageLengthFitsInBuffer(message_length, self.x_request_connection.buffer.half_len);
        switch (x.serverMsgTaggedUnion(@alignCast(self.x_request_connection.buffer.double_buffer_ptr))) {
            .reply => |msg_reply| {
                const msg: *x.get_property.Reply = @ptrCast(msg_reply);
                const opt_window_process_id_bytes = try msg.getValueBytes();
                if (opt_window_process_id_bytes) |window_process_id_bytes| {
                    const window_process_id = x.readIntNative(u32, window_process_id_bytes.ptr);
                    return window_process_id;
                }
            },
            else => |msg| {
                log.err("expected a reply for `x.get_property` but got {}", .{msg});
                return error.ExpectedReplyForGetProperty;
            },
        }

        return null;
    }
};
