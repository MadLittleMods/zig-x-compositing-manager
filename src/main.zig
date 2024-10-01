const std = @import("std");
const x = @import("x");
const common = @import("x11/x11_common.zig");
const render = @import("compositing_manager/render.zig");
const AppState = @import("compositing_manager/app_state.zig").AppState;
const x11_extension_utils = @import("x11/x11_extension_utils.zig");
const x_composite_extension = @import("x11/x_composite_extension.zig");

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

    // Create a big buffer that we can use to read messages and replies from the X server.
    const double_buffer = try x.DoubleBuffer.init(
        std.mem.alignForward(usize, 8000, std.mem.page_size),
        .{ .memfd_name = "ZigX11DoubleBuffer" },
    );
    defer double_buffer.deinit(); // not necessary but good to test
    std.log.info("Read buffer capacity is {}", .{double_buffer.half_len});
    var buffer = double_buffer.contiguousReadBuffer();
    // const buffer_limit = buffer.half_len;

    // We use the X Composite extension to redirect the rendering of the windows to offscreen storage.
    const optional_composite_extension = try x11_extension_utils.getExtensionInfo(
        conn.sock,
        &buffer,
        "Composite",
    );
    const composite_extension = optional_composite_extension orelse @panic("X Composite extension extension not found");

    try x_composite_extension.ensureCompatibleVersionOfXCompositeExtension(
        conn.sock,
        &buffer,
        &composite_extension,
        .{
            // We require version 0.3 of the X Composite extension for the
            // `x.composite.get_overlay_window` request.
            .major_version = 0,
            .minor_version = 3,
        },
    );

    {
        var message_buffer: [x.composite.redirect_subwindows.len]u8 = undefined;
        x.composite.redirect_subwindows.serialize(&message_buffer, composite_extension.opcode, .{
            .window_id = ids.root,
            .update_type = .manual,
        });
        try conn.send(&message_buffer);
    }

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
        main_process.stdin_behavior = .Ignore;
        main_process.stdout_behavior = .Ignore;
        main_process.stderr_behavior = .Ignore;

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
