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

const WindowList = std.TailQueue(*StackingOrder);

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
    children: WindowList,
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

        // This isn't strictly necessary but it marks the memory as dirty (010101...) in
        // safe modes (https://zig.news/kristoff/what-s-undefined-in-zig-9h)
        self.* = undefined;
    }

    /// Insert a *new* node at the end of the list (top of the stacking order of the siblings)
    pub fn appendNewChild(
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

    /// Insert a *new* node at the start of the list (bottom of the stacking order of the siblings)
    pub fn prependNewChild(
        self: *StackingOrder,
        window_id: u32,
    ) !*StackingOrder {
        // Create the new StackingOrder
        var child = try self.allocator.create(StackingOrder);
        child.* = StackingOrder.init(window_id, self, self.allocator);

        // Create the queue node that will hold the pointer to the StackingOrder
        var node = try self.allocator.create(std.TailQueue(*StackingOrder).Node);
        node.* = .{ .data = child };

        self.children.prepend(node);

        return child;
    }

    /// Move this window under a new parent window.
    ///
    /// Removes the window from its current parent's children and appends it to the new
    /// parent's children (top of the stacking order).
    ///
    /// Searches rescursively in the StackingOrder for the given window ID's.
    pub fn reparentChild(
        self: *StackingOrder,
        window_id: u32,
        new_parent_window_id: u32,
    ) !void {
        // Find the window we're trying to move
        const window_node = self.findLinkedListNodeByWindowIdRecursive(window_id) orelse return error.WindowNotFound;

        // Remove the window from the current position
        if (window_node.data.parent_stacking_order) |parent_stacking_order| {
            parent_stacking_order.children.remove(window_node);
        }

        const new_parent_node = self.findLinkedListNodeByWindowIdRecursive(new_parent_window_id) orelse return error.SiblingWindowNotFound;

        // Places the window at the end of the new parent's children (top of the stacking order)
        new_parent_node.data.children.append(window_node);
    }

    const SiblingInsertionPosition = enum {
        before,
        after,
    };

    /// Move a window relative to another sibling window.
    ///
    /// When `opt_sibling_window_id` is null, the window is inserted at the start or end
    /// of its current StackingOrder according to the `position`.
    ///
    /// Searches rescursively in the StackingOrder for the given window ID's.
    pub fn moveChild(
        self: *StackingOrder,
        window_id: u32,
        position: SiblingInsertionPosition,
        opt_sibling_window_id: ?u32,
    ) !void {
        // Find the window we're trying to move
        const window_node = self.findLinkedListNodeByWindowIdRecursive(window_id) orelse return error.WindowNotFound;

        // Remove the window from the current position
        if (window_node.data.parent_stacking_order) |parent_stacking_order| {
            parent_stacking_order.children.remove(window_node);
        }

        // Insert the window at the new position
        if (opt_sibling_window_id) |sibling_window_id| {
            const sibling_node = self.findLinkedListNodeByWindowIdRecursive(sibling_window_id) orelse return error.SiblingWindowNotFound;
            const sibling_parent_node = sibling_node.data.parent_stacking_order orelse return error.SiblingWindowHasNoParent;

            switch (position) {
                .before => sibling_parent_node.children.insertBefore(sibling_node, window_node),
                .after => sibling_parent_node.children.insertAfter(sibling_node, window_node),
            }
        } else {
            const window_parent_node = window_node.data.parent_stacking_order orelse return error.WindowHasNoParent;

            switch (position) {
                .before => window_parent_node.children.prepend(window_node),
                .after => window_parent_node.children.append(window_node),
            }
        }
    }

    /// Remove a window from the StackingOrder hierarchy and clean up the memory.
    pub fn removeChild(
        self: *StackingOrder,
        window_id: u32,
    ) !void {
        // Find the window we're trying to remove
        const window_node = self.findLinkedListNodeByWindowIdRecursive(window_id) orelse return error.WindowNotFound;

        // Remove the window from the current position
        if (window_node.data.parent_stacking_order) |parent_stacking_order| {
            parent_stacking_order.children.remove(window_node);
        }

        // Clean up the memory for the StackingOrder and the Node
        window_node.data.deinit();
        self.allocator.destroy(window_node.data);
        self.allocator.destroy(window_node);
    }

    /// Find a LinkedList node by window_id in the StackingOrder hierarchy
    pub fn findLinkedListNodeByWindowIdRecursive(
        self: *StackingOrder,
        window_id: u32,
    ) ?*WindowList.Node {
        var it = self.children.first;
        while (it) |node| {
            if (node.data.window_id == window_id) {
                return node;
            }

            if (node.data.children.first) |child| {
                const opt_found_stacking_order = child.data.findLinkedListNodeByWindowIdRecursive(window_id);
                if (opt_found_stacking_order) |found_stacking_order| {
                    return found_stacking_order;
                }
            }

            it = node.next;
        }

        return null;
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

test "StackingOrder bottom-to-top iterator (single item, no children)" {
    const allocator = std.testing.allocator;

    var root_stacking_order = StackingOrder.init(0, null, allocator);
    defer root_stacking_order.deinit();

    var it = root_stacking_order.iterator();
    try testIterator(
        &it,
        &[_]u32{0},
        allocator,
    );
}

test "StackingOrder bottom-to-top iterator (flat list)" {
    const allocator = std.testing.allocator;

    var root_stacking_order = StackingOrder.init(0, null, allocator);
    defer root_stacking_order.deinit();
    _ = try root_stacking_order.appendNewChild(1);
    _ = try root_stacking_order.appendNewChild(2);
    _ = try root_stacking_order.appendNewChild(3);

    var it = root_stacking_order.iterator();
    try testIterator(
        &it,
        &[_]u32{ 0, 1, 2, 3 },
        allocator,
    );
}

test "StackingOrder bottom-to-top iterator (nested children)" {
    const allocator = std.testing.allocator;

    var root_stacking_order = StackingOrder.init(0, null, allocator);
    defer root_stacking_order.deinit();
    var one_stacking_order = try root_stacking_order.appendNewChild(1);
    var two_stacking_order = try root_stacking_order.appendNewChild(2);
    var three_stacking_order = try root_stacking_order.appendNewChild(3);

    _ = try two_stacking_order.appendNewChild(20);
    _ = try two_stacking_order.appendNewChild(21);

    var thirty_stacking_order = try three_stacking_order.appendNewChild(30);

    var ten_stacking_order = try one_stacking_order.appendNewChild(10);
    _ = try one_stacking_order.appendNewChild(11);

    _ = try ten_stacking_order.appendNewChild(100);
    _ = try ten_stacking_order.appendNewChild(101);

    _ = try two_stacking_order.appendNewChild(22);
    _ = try one_stacking_order.appendNewChild(12);

    _ = try thirty_stacking_order.appendNewChild(300);

    var it = root_stacking_order.iterator();
    try testIterator(
        &it,
        &[_]u32{ 0, 1, 10, 100, 101, 11, 12, 2, 20, 21, 22, 3, 30, 300 },
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
