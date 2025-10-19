// X Fixes Extension
//
// - Docs: https://www.x.org/releases/current/doc/fixesproto/fixesproto.txt
// - XML definitions of the protocol: https://gitlab.freedesktop.org/xorg/proto/xcbproto/-/blob/4d2879ad9e394ff832762e8961eca9415cc9934c/src/xfixes.xml

const std = @import("std");
const x = @import("x");
const common = @import("./x11_common.zig");
const x11_extension_utils = @import("./x11_extension_utils.zig");

/// Check to make sure we're using a compatible version of the X Fixes extension
/// that supports all of the features we need.
pub fn ensureCompatibleVersionOfXFixesExtension(
    x_connection: common.XConnection,
    fixes_extension: *const x11_extension_utils.ExtensionInfo,
    version: struct {
        major_version: u16,
        minor_version: u16,
    },
) !void {
    {
        var message_buffer: [x.fixes.query_version.len]u8 = undefined;
        x.fixes.query_version.serialize(&message_buffer, .{
            .ext_opcode = fixes_extension.opcode,
            .wanted_major_version = version.major_version,
            .wanted_minor_version = version.minor_version,
        });
        try x_connection.send(&message_buffer);
    }
    const message_length = try x.readOneMsg(x_connection.reader(), @alignCast(x_connection.buffer.nextReadBuffer()));
    try common.checkMessageLengthFitsInBuffer(message_length, x_connection.buffer.half_len);
    switch (x.serverMsgTaggedUnion(@alignCast(x_connection.buffer.double_buffer_ptr))) {
        .reply => |msg_reply| {
            const msg: *x.fixes.query_version.Reply = @ptrCast(msg_reply);
            std.log.info("X Fixes extension: version {}.{}", .{ msg.major_version, msg.minor_version });
            if (msg.major_version != version.major_version) {
                std.log.err("X Fixes extension major version is {} but we expect {}", .{
                    msg.major_version,
                    version.major_version,
                });
                return error.XFixesExtensionTooNew;
            }
            if (msg.minor_version < version.minor_version) {
                std.log.err("X Fixes extension minor version is {}.{} but I've only tested >= {}.{})", .{
                    msg.major_version,
                    msg.minor_version,
                    version.major_version,
                    version.minor_version,
                });
                return error.XFixesExtensionTooOld;
            }
        },
        else => |msg| {
            std.log.err("expected a reply for `x.fixes.query_version` but got {}", .{msg});
            return error.ExpectedReplyButGotSomethingElse;
        },
    }
}
