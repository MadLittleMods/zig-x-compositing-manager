const std = @import("std");
const render_utils = @import("../utils/render_utils.zig");

pub const Window = struct {
    window_id: u32,
    visible: bool,
    x: i16,
    y: i16,
    width: u16,
    height: u16,
};

/// Holds the overall state of the application. In an ideal world, this would be
/// everything to reproduce the exact way the application looks at any given time.
pub const AppState = struct {
    /// The pixel dimensions of the screen/monitor
    root_screen_dimensions: render_utils.Dimensions,

    // FIXME: It would be good to use a specific `const WindowID = enum(u32) { _ }` type here
    window_map: *std.AutoHashMap(u32, Window),
    /// window_id -> picture_id
    window_to_picture_id_map: *std.AutoHashMap(u32, u32),
    /// window_id -> region_id
    window_to_region_id_map: *std.AutoHashMap(u32, u32),
};
