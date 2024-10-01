// X Composite Extension
//
// - Docs: https://gitlab.freedesktop.org/xorg/proto/xorgproto/-/blob/3076552555c32cb89ec20ddef638317f0ea303b9/compositeproto.txt
// - XML definitions of the protocol: https://gitlab.freedesktop.org/xorg/proto/xcbproto/-/blob/77d7fc04da729ddc5ed4aacf30253726fac24dca/src/composite.xml

const std = @import("std");
const x = @import("x");
const common = @import("./x11_common.zig");
const x11_extension_utils = @import("./x11_extension_utils.zig");

/// Check to make sure we're using a compatible version of the X Composite extension
/// that supports all of the features we need.
pub fn ensureCompatibleVersionOfXCompositeExtension(
    sock: std.os.socket_t,
    buffer: *x.ContiguousReadBuffer,
    composite_extension: *const x11_extension_utils.ExtensionInfo,
    version: struct {
        major_version: u16,
        minor_version: u16,
    },
) !void {
    const reader = common.SocketReader{ .context = sock };
    const buffer_limit = buffer.half_len;

    {
        var message_buffer: [x.composite.query_version.len]u8 = undefined;
        x.composite.query_version.serialize(&message_buffer, .{
            .ext_opcode = composite_extension.opcode,
            .wanted_major_version = version.major_version,
            .wanted_minor_version = version.minor_version,
        });
        try common.send(sock, &message_buffer);
    }
    const message_length = try x.readOneMsg(reader, @alignCast(buffer.nextReadBuffer()));
    try common.checkMessageLengthFitsInBuffer(message_length, buffer_limit);
    switch (x.serverMsgTaggedUnion(@alignCast(buffer.double_buffer_ptr))) {
        .reply => |msg_reply| {
            const msg: *x.composite.query_version.Reply = @ptrCast(msg_reply);
            std.log.info("X Composite extension: version {}.{}", .{ msg.major_version, msg.minor_version });
            if (msg.major_version != version.major_version) {
                std.log.err("X Composite extension major version is {} but we expect {}", .{
                    msg.major_version,
                    version.major_version,
                });
                return error.XCompositeExtensionTooNew;
            }
            if (msg.minor_version < version.minor_version) {
                std.log.err("X Composite extension minor version is {}.{} but I've only tested >= {}.{})", .{
                    msg.major_version,
                    msg.minor_version,
                    version.major_version,
                    version.minor_version,
                });
                return error.XCompositeExtensionTooOld;
            }
        },
        else => |msg| {
            std.log.err("expected a reply for `x.composite.query_version` but got {}", .{msg});
            return error.ExpectedReplyButGotSomethingElse;
        },
    }
}
