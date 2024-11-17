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

/// Holds the stacking order of windows.
/// Bottom-to-top stacking order of windows (DoublyLinkedList)
///
/// Since each window can have any number of children, we use a recursive data structure
/// where each window can have it's own StackingOrder context with more children.
pub const StackingOrder = struct {
    /// The window ID of the parent window
    window_id: u32,
    /// Bottom-to-top stacking order of child windows (DoublyLinkedList)
    // Bottom-to-top order allows us to iterate through the list to draw the windows in
    // the correct order.
    children: std.TailQueue(*StackingOrder),
    allocator: std.mem.Allocator,

    pub fn init(
        window_id: u32,
        allocator: std.mem.Allocator,
    ) @This() {
        return .{
            .window_id = window_id,
            .children = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StackingOrder) void {
        // Loop through the DoublyLinkedList and deinit each Node and it's data (the StackingOrder)
        var it = self.children.first;
        while (it) |node| {
            const next = node.next;
            node.data.deinit();
            self.allocator.destroy(node.data);
            self.allocator.destroy(node);
            // Move to the next node in the linked list
            it = next;
        }
    }

    /// Insert a new node at the end of the list (top of the stacking order)
    pub fn append_child(
        self: *StackingOrder,
        window_id: u32,
    ) !void {
        // Create the new StackingOrder
        var child = try self.allocator.create(StackingOrder);
        child.* = StackingOrder.init(window_id, self.allocator);

        // Create the queue node that will hold the pointer to the StackingOrder
        var node = try self.allocator.create(std.TailQueue(*StackingOrder).Node);
        node.* = .{ .data = child };

        self.children.append(node);
    }

    /// Return an iterator that walks the stacking order (bottom-to-top) without
    /// consuming it. Invalidated if the heap is modified.
    ///
    /// Bottom-to-top order allows us to iterate through the list to draw the windows in
    /// the correct order.
    pub fn iterator(self: *StackingOrder) BottomToTopStackingOrderIterator {
        return .{ .current_node = self.children.first };
    }

    pub const BottomToTopStackingOrderIterator = struct {
        current_node: ?*std.TailQueue(*StackingOrder).Node,

        pub fn next(self: *BottomToTopStackingOrderIterator) ?*StackingOrder {
            if (self.current_node) |current_node| {
                const data = current_node.data;
                self.current_node = current_node.next;
                return data;
            }

            return null;
        }
    };
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
    /// Bottom-to-top stacking order of windows (DoublyLinkedList)
    window_stacking_order: *StackingOrder,
};
