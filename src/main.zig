const std = @import("std");

// In order to create the total screen presentation we need to create a render picture
// for the root window (or "composite overlay window" if available), and draw the
// windows on it manually, taking the window hierarchy into account.

// We want to use manual redirection so the window contents will be redirected to
// offscreen storage, but not automatically updated on the screen when they're modified.

pub fn main() void {}

// This test is meant to run on a 400x300 display. Create a virtual display (via Xvfb
// or Xephyr) and point the tests to that display by setting the `DISPLAY` environment
// variable (`DISPLAY=:99 zig build test`).
//
// FIXME: Ideally, this test should be able to be run standalone without any extra setup
// outside to create right size display. By default, it should just run in a headless
// environment and we'd have `Xvfb` as a dependency we build ourselves to run the tests.
// I hate when projects require you to install extra system dependencies to get things
// working. The only thing you should need is the right version of Zig.
test "end-to-end: click to capture screenshot" {
    const allocator = std.testing.allocator;

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

    const test_window_process1 = blk: {
        const test_window_argv = [_][]const u8{ "./zig-out/bin/test_window", "100", "0", "0xaaff0000" };
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
        const test_window_argv = [_][]const u8{ "./zig-out/bin/test_window", "200", "100", "0xaa0000ff" };
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
}
