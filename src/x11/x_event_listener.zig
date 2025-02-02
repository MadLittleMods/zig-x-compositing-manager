const std = @import("std");
const builtin = @import("builtin");
const assertions = @import("../utils/assertions.zig");
const assert = assertions.assert;
const x = @import("x");
const common = @import("x11_common.zig");
const x11_extension_utils = @import("x11_extension_utils.zig");
const x_composite_extension = @import("x_composite_extension.zig");

const log = std.log.scoped(.x_event_listener);

const EventTask = struct {
    task_semaphore: std.Thread.Semaphore,
    target_window_id: u32,
    target_event_kind: x.ServerMsgKind,
};

pub const XEventListener = struct {
    allocator: std.mem.Allocator,
    root_window_id: u32,
    x_event_connection: common.XConnection,
    x_request_connection: common.XConnection,
    x_extensions: x11_extension_utils.Extensions(&.{.composite}),
    wm_pid_atom: x.Atom,
    event_task_list: std.ArrayList(EventTask),
    // event_listener_thread: std.Thread,

    pub fn init(allocator: std.mem.Allocator) !@This() {
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
        // 2. Create an X connection for making one-off requests
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

        // We want to know when a window is created/destroyed, moved, resized, show/hide,
        // stacking order change, so we can reflect the change.
        {
            var message_buffer: [x.change_window_attributes.max_len]u8 = undefined;
            const len = x.change_window_attributes.serialize(&message_buffer, screen.root, .{
                // `substructure_notify` allows us to listen for all of the `xxx_notify`
                // events like window creation/destruction (i.e.
                // `create_notify`/`destroy_notify`), moved, resized, visibility, stacking
                // order change, etc of any children of the root window.
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

        const wm_pid_atom = try common.intern_atom(
            x_request_connection.socket,
            x_request_connection.buffer,
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
        const x_connections = [_]common.XConnection{ x_event_connection, x_request_connection };
        for (x_connections) |x_connection| {
            _ = x_connection;
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
        }

        // Assemble a map of X extension info
        const extensions = x11_extension_utils.Extensions(&.{.composite}){
            .composite = composite_extension,
        };

        const x_event_listener = @This(){
            .allocator = allocator,
            .root_window_id = screen.root,
            .x_event_connection = x_event_connection,
            .x_request_connection = x_request_connection,
            .x_extensions = extensions,
            .wm_pid_atom = wm_pid_atom,
            .event_task_list = std.ArrayList(EventTask).init(allocator),
            // .event_listener_thread = undefined,
        };

        const thread = try std.Thread.spawn(.{}, startListeningForXEvents, .{x_event_listener});
        _ = thread;
        // x_event_listener.event_listener_thread = thread;

        return x_event_listener;
    }

    pub fn deinit(self: @This()) void {
        // Clean up our memory.
        //
        // This will also stop the event listener thread (see internal comments) so we
        // can exit.
        self.x_event_connection.deinit();
        self.x_request_connection.deinit();

        self.event_task_list.deinit();
    }

    /// Wait for an event of a specific kind from a specific process. Returns a
    /// semaphore which will be signalled when the event is received. This is just
    /// something you can use to wait until the event is received, ex.
    /// `semaphore.timedWait(1000 * std.time.ns_per_ms)`
    pub fn waitForEventFromProcess(
        self: *@This(),
        process_id: std.ChildProcess.Id,
        target_event_kind: x.ServerMsgKind,
    ) !std.Thread.Semaphore {
        var semaphor = std.Thread.Semaphore{};

        // Find the window ID of the `process_id` via the `_NET_WM_PID` property
        // on the windows
        const opt_window_id = try self.findWindowIdByProcessId(process_id);
        if (opt_window_id) |window_id| {
            try self.event_task_list.append(.{
                .task_semaphore = semaphor,
                .target_window_id = window_id,
                .target_event_kind = target_event_kind,
            });
        } else {
            return error.WindowIdNotFound;
        }

        return semaphor;
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

    fn startListeningForXEvents(self: @This()) !void {
        errdefer std.os.closeSocket(self.x_event_connection.socket);

        std.debug.print("asdf startListeningForXEvents\n", .{});

        while (true) {
            {
                const receive_buffer = self.x_event_connection.buffer.nextReadBuffer();
                if (receive_buffer.len == 0) {
                    log.err("buffer size {} not big enough!", .{self.x_event_connection.buffer.half_len});
                    return error.BufferSizeNotBigEnough;
                }
                const len = try x.readSock(self.x_event_connection.socket, receive_buffer, 0);
                if (len == 0) {
                    log.info("X server connection closed", .{});
                    return;
                }
                self.x_event_connection.buffer.reserve(len);
            }

            while (true) {
                const data = self.x_event_connection.buffer.nextReservedBuffer();
                if (data.len < 32)
                    break;
                const msg_len: u32 = x.parseMsgLen(data[0..32].*);
                if (data.len < msg_len)
                    break;
                self.x_event_connection.buffer.release(msg_len);

                std.debug.print("asdf received event {}\n", .{x.serverMsgTaggedUnion(@alignCast(data.ptr))});

                // TODO: Check self.event_task_list for anything we need to signal

                switch (x.serverMsgTaggedUnion(@alignCast(data.ptr))) {
                    .err => |msg| {
                        log.err("Received X error: {}", .{msg});
                    },
                    .reply => |msg| {
                        log.info("todo: handle a reply message {}", .{msg});
                        return error.TodoHandleReplyMessage;
                    },
                    .generic_extension_event => |msg| {
                        log.info("TODO: handle a GE generic event {}", .{msg});
                        return error.TodoHandleGenericExtensionEvent;
                    },
                    .key_press => |msg| {
                        log.info("key_press: keycode={}", .{msg.keycode});
                    },
                    .key_release => |msg| {
                        log.info("key_release: keycode={}", .{msg.keycode});
                    },
                    .button_press => |msg| {
                        log.info("button_press: {}", .{msg});
                    },
                    .button_release => |msg| {
                        log.info("button_release: {}", .{msg});
                    },
                    .enter_notify => |msg| {
                        log.info("enter_window: {}", .{msg});
                    },
                    .leave_notify => |msg| {
                        log.info("leave_window: {}", .{msg});
                    },
                    .motion_notify => |msg| {
                        // too much logging
                        //log.info("pointer_motion: {}", .{msg});
                        _ = msg;
                    },
                    .keymap_notify => |msg| {
                        log.info("keymap_state: {}", .{msg});
                    },
                    .expose => |msg| {
                        log.info("expose: {}", .{msg});
                    },
                    .create_notify => |msg| {
                        log.info("create_notify: {}", .{msg});
                    },
                    .destroy_notify => |msg| {
                        log.info("destroy_notify: {}", .{msg});
                    },
                    .map_notify => |msg| {
                        log.info("map_notify: {}", .{msg});
                    },
                    .unmap_notify => |msg| {
                        log.info("unmap_notify: {}", .{msg});
                    },
                    .reparent_notify => |msg| {
                        log.info("reparent_notify: {}", .{msg});
                    },
                    .configure_notify => |msg| {
                        log.info("configure_notify: {}", .{msg});
                    },
                    .mapping_notify => |msg| {
                        log.info("mapping_notify: {}", .{msg});
                    },
                    .gravity_notify => |msg| {
                        log.info("gravity_notify: {}", .{msg});
                    },
                    .circulate_notify => |msg| {
                        log.info("circulate_notify: {}", .{msg});
                    },
                    .no_exposure => |msg| std.debug.panic("unexpected no_exposure {}", .{msg}),
                    .unhandled => |msg| {
                        log.info("todo: server msg {}", .{msg});
                        return error.UnhandledServerMsg;
                    },
                }
            }
        }
    }
};
