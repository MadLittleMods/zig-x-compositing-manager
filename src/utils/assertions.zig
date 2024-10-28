const std = @import("std");

/// Comptime assert with custom message
pub fn comptime_assert(comptime ok: bool, comptime msg: []const u8, args: anytype) void {
    if (!ok) {
        @compileLog(std.fmt.comptimePrint(msg, args));
        @compileError("comptime_assert failed");
    }
}

/// Assert with custom message
pub fn assert(ok: bool, comptime msg: []const u8, args: anytype) void {
    if (std.debug.runtime_safety and !ok) {
        std.debug.panic(msg, args);
        // This alternative doesn't work right (seems like UB given this branch is unreachable)
        // std.debug.print(msg, args);
        // unreachable;
    }
}
