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
    /// The parent stacking context that this window belongs to. This is useful for the
    /// iterator to move back up the hierarchy when it reaches the end of a child list.
    parent_stacking_order: ?*StackingOrder,
    allocator: std.mem.Allocator,

    pub fn init(
        window_id: u32,
        parent_stacking_order: ?*StackingOrder,
        allocator: std.mem.Allocator,
    ) @This() {
        return .{
            .window_id = window_id,
            .parent_stacking_order = parent_stacking_order,
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
    ) !*StackingOrder {
        // Create the new StackingOrder
        var child = try self.allocator.create(StackingOrder);
        child.* = StackingOrder.init(window_id, self, self.allocator);

        // Create the queue node that will hold the pointer to the StackingOrder
        var node = try self.allocator.create(std.TailQueue(*StackingOrder).Node);
        node.* = .{ .data = child };

        self.children.append(node);

        return child;
    }

    /// Return an iterator that walks the stacking order (bottom-to-top) without
    /// consuming it. Invalidated if the heap is modified.
    ///
    /// Bottom-to-top order allows us to iterate through the list to draw the windows in
    /// the correct order, visiting all children before moving to the next sibling.
    pub fn iterator(self: *StackingOrder) BottomToTopStackingOrderIterator {
        return .{ .current = self, .child_node = null };
    }

    pub const BottomToTopStackingOrderIterator = struct {
        current: ?*StackingOrder,
        // With a LinkedList, we track our position by holding onto the current node
        child_node: ?*std.TailQueue(*StackingOrder).Node,

        // Stackless recursive iterator:
        // Our strategy is to dive as deep as possible, iterate over the children, then
        // go back up one layer and move to the next sibling. If there are no siblings,
        // keep going up until we find a parent with a sibling we haven't visited yet.
        //
        // Instead of needing to use `parent_stacking_order`, one alternative would be
        // to keep track of the root StackingOrder and traverse down until we find the
        // current node we're looking for (wasted cycles). Another alternative is to
        // keep a stack of frames as we recurse deeper so we can unwind on the way back
        // up. The stack implementations are nice but require memory allocation or a
        // fixed-size array with a max depth that windows can be nested.
        pub fn next(self: *@This()) ?*StackingOrder {
            // If we have no current node, we're done
            const current = self.current orelse return null;

            // If we haven't started processing this context's children yet
            if (self.child_node == null) {
                // Start with the first child
                if (current.children.first) |first_child| {
                    self.child_node = first_child;
                } else {
                    // If there are no children, we're done. The next iteration of the
                    // loop will return null.
                    self.current = null;
                }

                // Return the current node before processing children
                return current;
            }

            // Check if we have more children to process
            if (self.child_node) |child_node| {
                // If the child has children, go deeper
                if (child_node.data.children.first) |_| {
                    self.current = child_node.data;
                    self.child_node = child_node.data.children.first;
                }
                // Setup the next nodes to visit
                //
                // Move to the next child if available
                else if (child_node.next) |next_child_node| {
                    self.child_node = next_child_node;
                }
                // Otherwise, go back upwards until we reach a layer with the next sibling we haven't visited yet
                else {
                    var needle = current;
                    var opt_parent = current.parent_stacking_order;
                    outer: while (opt_parent) |parent| {
                        // If we're at the last child of the parent, move to the next parent
                        if (parent.children.last) |last_child| {
                            if (last_child.data == needle) {
                                opt_parent = parent.parent_stacking_order;
                                needle = parent;
                                continue;
                            }
                        } else {
                            // This should exist! We're already iterating over one of
                            // the child nodes so the parent should have some "last"
                            // node. This would only happen if the LinkedList was
                            // modified while we were iterating over it.
                            return null;
                        }

                        // Find the `needle` node in the parent's children
                        var opt_parent_child = parent.children.first;
                        while (opt_parent_child) |parent_child| {
                            if (parent_child.data == needle) {
                                self.current = parent;
                                self.child_node = parent_child.next;
                                break :outer;
                            }

                            opt_parent_child = parent_child.next;
                        }
                    } else {
                        // We reached the root node which means we've already visited
                        // everything so we're done. The next iteration of the loop will
                        // return null.
                        self.current = null;
                        self.child_node = null;
                    }
                }

                return child_node.data;
            }

            return null;
        }
    };
};

/// Test utiltity function for `BottomToTopStackingOrderIterator`
fn testIterator(
    it: *StackingOrder.BottomToTopStackingOrderIterator,
    expected_order: []const u32,
    allocator: std.mem.Allocator,
) !void {
    var actual_order = try allocator.alloc(u32, expected_order.len);
    defer allocator.free(actual_order);

    var i: usize = 0;
    while (it.next()) |stacking_order| {
        if (i >= expected_order.len) {
            std.debug.print("Attempting to add another item ({d}) to actual_order={any} but it's already full with {d} items\n", .{
                stacking_order.window_id,
                actual_order,
                actual_order.len,
            });
            return error.MoreElementsThanExpected;
        }

        actual_order[i] = stacking_order.window_id;
        i += 1;
    }

    // std.testing.expectEqual(expected_order, actual_order);
    try std.testing.expectEqualSlices(u32, expected_order, actual_order);
}

test "StackingOrder bottom-to-top iterator" {
    const allocator = std.testing.allocator;

    var root_stacking_order = StackingOrder.init(0, null, allocator);
    defer root_stacking_order.deinit();
    var one_stacking_order = try root_stacking_order.append_child(1);
    var two_stacking_order = try root_stacking_order.append_child(2);
    var three_stacking_order = try root_stacking_order.append_child(3);

    _ = try two_stacking_order.append_child(20);
    _ = try two_stacking_order.append_child(21);

    var thirty_stacking_order = try three_stacking_order.append_child(30);

    var ten_stacking_order = try one_stacking_order.append_child(10);
    _ = try one_stacking_order.append_child(11);

    _ = try ten_stacking_order.append_child(100);
    _ = try ten_stacking_order.append_child(101);

    _ = try two_stacking_order.append_child(22);
    _ = try one_stacking_order.append_child(12);

    _ = try thirty_stacking_order.append_child(300);

    var it = root_stacking_order.iterator();
    try testIterator(
        &it,
        &[_]u32{ 0, 1, 10, 100, 101, 11, 12, 2, 20, 21, 22, 3, 30, 300 },
        allocator,
    );
}

test "StackingOrder bottom-to-top iterator (single item)" {
    const allocator = std.testing.allocator;

    var root_stacking_order = StackingOrder.init(0, null, allocator);

    var it = root_stacking_order.iterator();
    try testIterator(
        &it,
        &[_]u32{0},
        allocator,
    );
}

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
