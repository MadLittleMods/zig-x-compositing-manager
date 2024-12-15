const std = @import("std");
const builtin = @import("builtin");
const assertions = @import("utils/assertions.zig");
const assert = assertions.assert;
const x = @import("x");
const common = @import("x11/x11_common.zig");

pub const XEventListener = struct {
    x_connection: common.XConnection,

    pub fn init(allocator: std.mem.Allocator) @This() {
        try x.wsaStartup();

        const x_connect_result = try common.connect(allocator);
        defer x_connect_result.setup.deinit(allocator);
        const x_connection = try common.XConnection.init(
            x_connect_result.sock,
            8000,
            allocator,
        );

        const conn_setup_fixed_fields = x_connect_result.setup.fixed();
        // Print out some info about the X server we connected to
        {
            inline for (@typeInfo(@TypeOf(conn_setup_fixed_fields.*)).Struct.fields) |field| {
                std.log.debug("{s}: {any}", .{ field.name, @field(conn_setup_fixed_fields, field.name) });
            }
            std.log.debug("vendor: {s}", .{try x_connect_result.setup.getVendorSlice(conn_setup_fixed_fields.vendor_len)});
        }

        const screen = common.getFirstScreenFromConnectionSetup(x_connect_result.setup);
        // inline for (@typeInfo(@TypeOf(screen.*)).Struct.fields) |field| {
        //     std.log.debug("SCREEN 0| {s}: {any}", .{ field.name, @field(screen, field.name) });
        // }
        // std.log.info("root window ID {0} 0x{0x}", .{screen.root});

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
            try x_connection.send(message_buffer[0..len]);
        }

        return .{
            .x_connection = x_connection,
            .event = undefined,
        };
    }

    pub fn deinit(self: @This()) void {
        self.x_connection.deinit();
    }

    pub fn newWaiterForProcessId(process_id: std.ChildProcess.Id) std.Thread.Semaphore {
        var sem = std.Thread.Semaphore{};

        return sem;
    }
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
}
