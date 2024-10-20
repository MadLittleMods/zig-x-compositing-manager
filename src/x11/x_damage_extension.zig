// X Damage Extension
//
// - Docs: https://www.x.org/releases/current/doc/damageproto/damageproto.txt
// - XML definitions of the protocol: https://gitlab.freedesktop.org/xorg/proto/xcbproto/-/blob/4d2879ad9e394ff832762e8961eca9415cc9934c/src/damage.xml

const std = @import("std");
const x = @import("x");
const common = @import("./x11_common.zig");
const x11_extension_utils = @import("./x11_extension_utils.zig");

/// Check to make sure we're using a compatible version of the X Damage extension
/// that supports all of the features we need.
pub fn ensureCompatibleVersionOfXDamageExtension(
    x_connection: common.XConnection,
    damage_extension: *const x11_extension_utils.ExtensionInfo,
    version: struct {
        major_version: u16,
        minor_version: u16,
    },
) !void {
    {
        var message_buffer: [x.damage.query_version.len]u8 = undefined;
        x.damage.query_version.serialize(&message_buffer, .{
            .ext_opcode = damage_extension.opcode,
            .wanted_major_version = version.major_version,
            .wanted_minor_version = version.minor_version,
        });
        try common.send(x_connection.socket, &message_buffer);
    }
    const message_length = try x.readOneMsg(x_connection.reader(), @alignCast(x_connection.buffer.nextReadBuffer()));
    try common.checkMessageLengthFitsInBuffer(message_length, x_connection.buffer.half_len);
    switch (x.serverMsgTaggedUnion(@alignCast(x_connection.buffer.double_buffer_ptr))) {
        .reply => |msg_reply| {
            const msg: *x.damage.query_version.Reply = @ptrCast(msg_reply);
            std.log.info("X Damage extension: version {}.{}", .{ msg.major_version, msg.minor_version });
            if (msg.major_version != version.major_version) {
                std.log.err("X Damage extension major version is {} but we expect {}", .{
                    msg.major_version,
                    version.major_version,
                });
                return error.XDamageExtensionTooNew;
            }
            if (msg.minor_version < version.minor_version) {
                std.log.err("X Damage extension minor version is {}.{} but I've only tested >= {}.{})", .{
                    msg.major_version,
                    msg.minor_version,
                    version.major_version,
                    version.minor_version,
                });
                return error.XDamageExtensionTooOld;
            }
        },
        else => |msg| {
            std.log.err("expected a reply for `x.damage.query_version` but got {}", .{msg});
            return error.ExpectedReplyButGotSomethingElse;
        },
    }
}
