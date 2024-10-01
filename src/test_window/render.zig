const std = @import("std");
const x = @import("x");
const common = @import("../x11/x11_common.zig");
const x11_extension_utils = @import("../x11/x11_extension_utils.zig");
const AppState = @import("app_state.zig").AppState;
const render_utils = @import("../utils/render_utils.zig");
const FontDims = render_utils.FontDims;

/// Stores the IDs of the all of the resources used when communicating with the X Window server.
pub const Ids = struct {
    const Self = @This();

    /// The drawable ID of the root window
    root: u32,
    /// The base resource ID that we can increment from to assign and designate to new
    /// resources.
    base_resource_id: u32,
    /// (not for external use) - Tracks the current incremented ID
    _current_id: u32,

    /// The drawable ID of our window
    window: u32 = 0,
    colormap: u32 = 0,
    /// Background graphics context.
    bg_gc: u32 = 0,
    /// Foreground graphics context
    fg_gc: u32 = 0,

    pub fn init(root: u32, base_resource_id: u32) Self {
        var ids = Ids{
            .root = root,
            .base_resource_id = base_resource_id,
            ._current_id = base_resource_id,
        };

        // For any ID that isn't set yet (still has the default value of 0), generate
        // a new ID. This is a lot more fool-proof than trying to set the IDs manually
        // for each new one added.
        inline for (std.meta.fields(@TypeOf(ids))) |field| {
            if (@field(ids, field.name) == 0) {
                @field(ids, field.name) = ids.generateMonotonicId();
            }
        }

        return ids;
    }

    /// Returns an ever-increasing ID everytime the function is called
    fn generateMonotonicId(self: *Ids) u32 {
        const current_id = self._current_id;
        self._current_id += 1;
        return current_id;
    }
};

/// Bootstraps all of the X resources we will need use when rendering the UI.
pub fn createResources(
    sock: std.os.socket_t,
    buffer: *x.ContiguousReadBuffer,
    ids: *const Ids,
    screen: *align(4) x.Screen,
    depth: u8,
    state: *const AppState,
) !void {
    _ = buffer;
    // const reader = common.SocketReader{ .context = sock };
    // const buffer_limit = buffer.half_len;

    const window_position = state.window_position;
    const window_dimensions = state.window_dimensions;
    const window_background_color = state.window_background_color;

    var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_allocator.deinit();
    const allocator = arena_allocator.allocator();
    // We need to find a visual type that matches the depth of our window that we want to create.
    const matching_visual_type = try screen.findMatchingVisualType(
        depth,
        .true_color,
        allocator,
    );
    std.log.debug("matching_visual_type {any}", .{matching_visual_type});

    // We just need some colormap to provide when creating the window in order to avoid
    // a "bad" `match` error when working with a 32-bit depth.
    {
        std.log.debug("Creating colormap {0} 0x{0x}", .{ids.colormap});
        var message_buffer: [x.create_colormap.len]u8 = undefined;
        x.create_colormap.serialize(&message_buffer, .{
            .id = ids.colormap,
            .window_id = ids.root,
            .visual_id = matching_visual_type.id,
            .alloc = .none,
        });
        try common.send(sock, &message_buffer);
    }
    {
        std.log.debug("Creating window_id {0} 0x{0x}", .{ids.window});

        var message_buffer: [x.create_window.max_len]u8 = undefined;
        const len = x.create_window.serialize(&message_buffer, .{
            .window_id = ids.window,
            .parent_window_id = ids.root,
            // Color depth:
            // - 24 for RGB
            // - 32 for ARGB
            .depth = depth,
            .x = window_position.x,
            .y = window_position.y,
            .width = @intCast(window_dimensions.width),
            .height = @intCast(window_dimensions.height),
            // It's unclear what this is for, but we just need to set it to something
            // since it's one of the arguments.
            .border_width = 0,
            .class = .input_output,
            .visual_id = matching_visual_type.id,
        }, .{
            .bg_pixmap = .none,
            // 0xAARRGGBB
            // Required when `depth` is set to 32
            .bg_pixel = window_background_color,
            // .border_pixmap =
            // Required when `depth` is set to 32
            .border_pixel = 0x00000000,
            // Required when `depth` is set to 32
            .colormap = @enumFromInt(ids.colormap),
            // .bit_gravity = .north_west,
            // .win_gravity = .north_east,
            // .backing_store = .when_mapped,
            // .backing_planes = 0x1234,
            // .backing_pixel = 0xbbeeeeff,
            //
            // Whether this window overrides structure control facilities. Basically, a
            // suggestion whether the window manager to decorate this window (false) or
            // we want to override the behavior.
            .override_redirect = false,
            // .save_under = true,
            .event_mask = x.event.key_press | x.event.key_release | x.event.button_press | x.event.button_release | x.event.enter_window | x.event.leave_window | x.event.pointer_motion | x.event.keymap_state | x.event.exposure,
            // .dont_propagate = 1,
        });
        try common.send(sock, message_buffer[0..len]);
    }

    {
        const color_black: u32 = 0xff000000;
        const color_blue: u32 = 0xff0000ff;

        std.log.info("background_graphics_context_id {0} 0x{0x}", .{ids.bg_gc});
        var message_buffer: [x.create_gc.max_len]u8 = undefined;
        const len = x.create_gc.serialize(&message_buffer, .{
            .gc_id = ids.bg_gc,
            .drawable_id = ids.window,
        }, .{
            .background = color_black,
            .foreground = color_blue,
            // This option will prevent `NoExposure` events when we send `CopyArea`.
            // We're no longer using `CopyArea` in favor of X Render `Composite` though
            // so this isn't of much use. Still seems applicable to keep around in the
            // spirit of what we want to do.
            .graphics_exposures = false,
        });
        try common.send(sock, message_buffer[0..len]);
    }
    {
        const color_black: u32 = 0xff000000;
        const color_yellow: u32 = 0xffffff00;

        std.log.info("foreground_graphics_context_id {0} 0x{0x}", .{ids.fg_gc});
        var message_buffer: [x.create_gc.max_len]u8 = undefined;
        const len = x.create_gc.serialize(&message_buffer, .{
            .gc_id = ids.fg_gc,
            .drawable_id = ids.window,
        }, .{
            .background = color_black,
            .foreground = color_yellow,
            // This option will prevent `NoExposure` events when we send `CopyArea`.
            // We're no longer using `CopyArea` in favor of X Render `Composite` though
            // so this isn't of much use. Still seems applicable to keep around in the
            // spirit of what we want to do.
            .graphics_exposures = false,
        });
        try common.send(sock, message_buffer[0..len]);
    }
}

pub fn cleanupResources(
    sock: std.os.socket_t,
    ids: *const Ids,
) !void {
    {
        var message_buffer: [x.free_pixmap.len]u8 = undefined;
        x.free_pixmap.serialize(&message_buffer, ids.pixmap);
        try common.send(sock, &message_buffer);
    }

    {
        var message_buffer: [x.free_colormap.len]u8 = undefined;
        x.free_colormap.serialize(&message_buffer, ids.colormap);
        try common.send(sock, &message_buffer);
    }

    // TODO: free_gc

    // TODO: x.render.free_picture
}

/// Context struct pattern where we can hold some state that we can access in any of the
/// methods. This is useful because we have to call `render()` in many places and we
/// don't want to have to wrangle all of those arguments each time.
pub const RenderContext = struct {
    sock: *const std.os.socket_t,
    ids: *const Ids,
    font_dims: *const FontDims,
    state: *const AppState,

    /// Renders the UI to our window.
    pub fn render(self: *const @This()) !void {
        const sock = self.sock.*;

        const current_timestamp_ms = std.time.milliTimestamp();
        const elapsed_ms = current_timestamp_ms - self.state.start_timestamp_ms;

        // Render some text to the center of the window
        //
        // It would be nice if we could use `font-variant-numeric: tabular-nums;` (from
        // CSS) to make the numbers not jiggle as much when they change. We could also
        // use a monospace font as a cheap way out.
        try render_utils.renderString(
            sock,
            self.ids.window,
            self.ids.fg_gc,
            self.font_dims,
            @divFloor(self.state.window_dimensions.width, 2),
            @divFloor(self.state.window_dimensions.height, 2),
            render_utils.PositionOrigin.init(.{ .keyword = .center }, .{ .keyword = .center }),
            // To stop things from jiggling around, just pad this number with spaces.
            // This strategy is flawed as it will start jiggling once enough time has
            // elapsed (1 hour) and what we really want is to be able to do is specify
            // the ms precision/padding that we want.
            "Elapsed time: {s:<10}",
            .{
                std.fmt.fmtDurationSigned(std.time.ns_per_ms * elapsed_ms),
            },
        );
    }
};
