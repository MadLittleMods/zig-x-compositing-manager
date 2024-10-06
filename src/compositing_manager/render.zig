const std = @import("std");
const x = @import("x");
const common = @import("../x11/x11_common.zig");
const x11_extension_utils = @import("../x11/x11_extension_utils.zig");
const x11_render_extension = @import("../x11/x_render_extension.zig");
const AppState = @import("app_state.zig").AppState;
const render_utils = @import("../utils/render_utils.zig");
const FontDims = render_utils.FontDims;

/// Generate new resource IDs for X resources.
pub const IdGenerator = struct {
    /// The base resource ID that we can increment from to assign and designate to new
    /// resources.
    base_resource_id: u32,
    /// (not for external use) - Tracks the current incremented ID
    _current_id: u32,

    pub fn init(base_resource_id: u32) @This() {
        return .{
            .base_resource_id = base_resource_id,
            ._current_id = base_resource_id,
        };
    }

    /// Returns an ever-increasing ID everytime the function is called
    pub fn generateMonotonicId(self: *@This()) u32 {
        const current_id = self._current_id;
        self._current_id += 1;
        return current_id;
    }
};

/// Stores the IDs of the all of the resources used when communicating with the X Window server.
pub const Ids = struct {
    /// The drawable ID of the root window
    root: u32,
    /// The drawable ID of the composite overlay window
    overlay_window_id: u32,

    /// The drawable ID of our window
    window: u32 = 0,

    colormap: u32 = 0,
    /// Background graphics context.
    bg_gc: u32 = 0,
    /// Foreground graphics context
    fg_gc: u32 = 0,
    /// Graphics context for the overlay window
    overlay_gc: u32 = 0,

    // We need to create a "picture" version of every drawable for use with the X Render
    // extension.
    picture_window: u32 = 0,

    pub fn init(root: u32, overlay_window_id: u32, id_generator: *IdGenerator) @This() {
        var ids = Ids{
            .root = root,
            .overlay_window_id = overlay_window_id,
        };

        // For any ID that isn't set yet (still has the default value of 0), generate
        // a new ID. This is a lot more fool-proof than trying to set the IDs manually
        // for each new one added.
        inline for (std.meta.fields(@TypeOf(ids))) |field| {
            if (@field(ids, field.name) == 0) {
                @field(ids, field.name) = id_generator.generateMonotonicId();
            }
        }

        return ids;
    }
};

/// Bootstraps all of the X resources we will need use when rendering the UI.
pub fn createResources(
    x_connection: common.XConnection,
    ids: *const Ids,
    screen: *align(4) x.Screen,
    extensions: *const x11_extension_utils.Extensions(&.{ .composite, .shape, .render }),
    depth: u8,
    state: *const AppState,
) !void {
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
        try x_connection.send(&message_buffer);
    }

    // Since the `overlay_window_id` isn't necessarily a 32-bit depth window, we're
    // going to create our own window with 32-bit depth with the same dimensions as
    // overlay/root with the `overlay_window_id` as the parent.
    {
        std.log.debug("Creating window_id {0} 0x{0x}", .{ids.window});

        var message_buffer: [x.create_window.max_len]u8 = undefined;
        const len = x.create_window.serialize(&message_buffer, .{
            .window_id = ids.window,
            // Parent our window to the overlay window
            .parent_window_id = ids.overlay_window_id,
            // Color depth:
            // - 24 for RGB
            // - 32 for ARGB
            .depth = depth,
            .x = 0,
            .y = 0,
            .width = @intCast(state.root_screen_dimensions.width),
            .height = @intCast(state.root_screen_dimensions.height),
            // It's unclear what this is for, but we just need to set it to something
            // since it's one of the arguments.
            .border_width = 0,
            .class = .input_output,
            .visual_id = matching_visual_type.id,
        }, .{
            .bg_pixmap = .none,
            // 0xAARRGGBB
            // Required when `depth` is set to 32
            .bg_pixel = 0x00000000,
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

            // We don't need to know about any events for this window as everything is
            // just passed through to the actual underlying windows.
            //
            // .event_mask = x.event.key_press | x.event.key_release | x.event.button_press | x.event.button_release | x.event.enter_window | x.event.leave_window | x.event.pointer_motion | x.event.keymap_state | x.event.exposure,

            // .dont_propagate = 1,
        });
        try x_connection.send(message_buffer[0..len]);
    }

    const opt_matching_picture_format = try x11_render_extension.findPictureFormatForVisualId(
        x_connection,
        matching_visual_type.id,
        &x11_extension_utils.Extensions(&.{.render}){
            .render = extensions.render,
        },
    );
    const matching_picture_format = opt_matching_picture_format orelse {
        return error.NoMatchingPictureFormatForWindowVisualType;
    };

    // We need to create a picture for every drawable that we want to use with the X
    // Render extension
    // =============================================================================
    //
    // Create a picture for the our window that we can copy and composite things onto
    {
        var message_buffer: [x.render.create_picture.max_len]u8 = undefined;
        const len = x.render.create_picture.serialize(&message_buffer, extensions.render.opcode, .{
            .picture_id = ids.picture_window,
            .drawable_id = ids.window,
            .format_id = matching_picture_format.picture_format_id,
            .options = .{},
        });
        try x_connection.send(message_buffer[0..len]);
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
        try x_connection.send(message_buffer[0..len]);
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
        try x_connection.send(message_buffer[0..len]);
    }

    {
        const color_black: u32 = 0xff000000;
        const color_red: u32 = 0xffff0000;

        std.log.info("foreground_graphics_context_id {0} 0x{0x}", .{ids.fg_gc});
        var message_buffer: [x.create_gc.max_len]u8 = undefined;
        const len = x.create_gc.serialize(&message_buffer, .{
            .gc_id = ids.overlay_gc,
            .drawable_id = ids.overlay_window_id,
        }, .{
            .background = color_black,
            .foreground = color_red,
            // This option will prevent `NoExposure` events when we send `CopyArea`.
            // We're no longer using `CopyArea` in favor of X Render `Composite` though
            // so this isn't of much use. Still seems applicable to keep around in the
            // spirit of what we want to do.
            .graphics_exposures = false,
        });
        try x_connection.send(message_buffer[0..len]);
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
    extensions: *const x11_extension_utils.Extensions(&.{ .composite, .shape, .render }),
    state: *const AppState,

    /// Renders the UI to our window.
    pub fn render(self: *const @This()) !void {
        const sock = self.sock.*;

        var window_map_iterator = self.state.window_map.iterator();
        while (window_map_iterator.next()) |window_entry| {
            const window_id = window_entry.key_ptr.*;
            const window = window_entry.value_ptr;

            const opt_picture_id = self.state.window_to_picture_id_map.get(window_id);
            if (opt_picture_id) |picture_id| {
                // We use the `x.render.composite` request to instead of `x.copy_area`
                // because it supports copying from windows with differing depths and we
                // want the alpha/transparency support which only `x.render.composite`
                // can do.
                var msg: [x.render.composite.len]u8 = undefined;
                x.render.composite.serialize(&msg, self.extensions.render.opcode, .{
                    .picture_operation = .over,
                    .src_picture_id = picture_id,
                    .mask_picture_id = 0,
                    .dst_picture_id = self.ids.picture_window,
                    .src_x = 0,
                    .src_y = 0,
                    .mask_x = 0,
                    .mask_y = 0,
                    .dst_x = window.x,
                    .dst_y = window.y,
                    .width = window.width,
                    .height = window.height,
                });
                try common.send(sock, &msg);
            } else {
                std.log.err("No picture ID found for window_id {}", .{window_id});
                continue;
            }
        }
    }
};
