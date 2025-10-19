const std = @import("std");
const x = @import("x");
const common = @import("../x11/x11_common.zig");

pub fn Coordinate(comptime NumberType: type) type {
    return struct {
        x: NumberType,
        y: NumberType,
    };
}

pub const Dimensions = struct {
    width: i16,
    height: i16,
};

pub const FontDims = struct {
    width: u8,
    height: u8,
    /// pixels to the left of the text basepoint
    font_left: i16,
    /// pixels up from the text basepoint to the top of the text
    font_ascent: i16,
};

pub const XOriginKeyword = enum {
    left,
    center,
    right,
};

pub const YOriginKeyword = enum {
    top,
    center,
    bottom,
};

fn xOriginKeywordToLengthPercentage(keyword: XOriginKeyword) f32 {
    switch (keyword) {
        XOriginKeyword.left => return 0.0,
        XOriginKeyword.center => return 0.5,
        XOriginKeyword.right => return 1.0,
    }
}

fn yOriginKeywordToLengthPercentage(keyword: YOriginKeyword) f32 {
    switch (keyword) {
        YOriginKeyword.top => return 0.0,
        YOriginKeyword.center => return 0.5,
        YOriginKeyword.bottom => return 1.0,
    }
}

pub const OriginValue = union(enum) {
    /// Percentage value from 0.0 to 1.0
    relative: f32,
    /// Absolute value in pixels
    absolute: i16,
};

pub const PositionOrigin = struct {
    x: OriginValue,
    y: OriginValue,

    pub fn init(x_origin: union(enum) {
        keyword: XOriginKeyword,
        relative: f32,
        absolute: i16,
    }, y_origin: union(enum) {
        keyword: YOriginKeyword,
        relative: f32,
        absolute: i16,
    }) @This() {
        return .{
            .x = switch (x_origin) {
                .keyword => OriginValue{ .relative = xOriginKeywordToLengthPercentage(x_origin.keyword) },
                .relative => OriginValue{ .relative = x_origin.relative },
                .absolute => OriginValue{ .absolute = x_origin.absolute },
            },
            .y = switch (y_origin) {
                .keyword => OriginValue{ .relative = yOriginKeywordToLengthPercentage(y_origin.keyword) },
                .relative => OriginValue{ .relative = y_origin.relative },
                .absolute => OriginValue{ .absolute = y_origin.absolute },
            },
        };
    }
};

fn computeOffsetFromOrigin(length: i16, origin: OriginValue) i16 {
    var result: i16 = 0;
    switch (origin) {
        OriginValue.relative => |percentage| {
            result = @intFromFloat(@round(
                @as(f32, @floatFromInt(length)) * percentage,
            ));
        },
        OriginValue.absolute => |offset| {
            result += offset;
        },
    }

    return result;
}

pub fn renderString(
    x_connection: common.XConnection,
    drawable_id: u32,
    fg_gc_id: u32,
    font_dims: FontDims,
    position_x: i16,
    position_y: i16,
    position_origin: PositionOrigin,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    var msg: [x.image_text8.max_len]u8 = undefined;
    const text_buf = msg[x.image_text8.text_offset .. x.image_text8.text_offset + 0xff];
    const text_len: u8 = @intCast((std.fmt.bufPrint(text_buf, fmt, args) catch @panic("string too long")).len);

    const text_width: i16 = @intCast(font_dims.width * text_len);

    // Calculate the baseline position of the text
    const baseline_x = position_x - computeOffsetFromOrigin(text_width, position_origin.x) + font_dims.font_left;
    const baseline_y = position_y - computeOffsetFromOrigin(font_dims.height, position_origin.y) + font_dims.font_ascent;

    x.image_text8.serializeNoTextCopy(&msg, text_len, .{
        .drawable_id = drawable_id,
        .gc_id = fg_gc_id,
        .x = baseline_x,
        .y = baseline_y,
    });
    try x_connection.send(msg[0..x.image_text8.getLen(text_len)]);
}
