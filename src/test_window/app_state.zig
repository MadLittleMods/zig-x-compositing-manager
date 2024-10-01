const render_utils = @import("../utils/render_utils.zig");

/// Holds the overall state of the application. In an ideal world, this would be
/// everything to reproduce the exact way the application looks at any given time.
pub const AppState = struct {
    window_position: render_utils.Coordinate(i16),
    /// The pixel dimensions of our window
    window_dimensions: render_utils.Dimensions,

    /// 0xAARRGGBB
    window_background_color: u32,

    /// When the application started
    start_timestamp_ms: i64,
};
