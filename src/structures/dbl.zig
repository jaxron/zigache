const std = @import("std");

const assert = std.debug.assert;

/// A generic doubly-linked list modified from Zig's std library.
/// The implementation uses asserts to check for impossible cases, which
/// helps catch bugs and invalid states during development and testing.
/// All operations have O(1) time complexity.
pub fn DoublyLinkedList(comptime Node: type) type {
    return struct {
        first: ?*Node = null,
        last: ?*Node = null,
        len: usize = 0,

        const Self = @This();

        /// Insert a new node after an existing one.
        pub fn insertAfter(self: *Self, node: *Node, new_node: *Node) void {
            assert(new_node != node);
            assert(new_node.prev == null and new_node.next == null);

            new_node.prev = node;
            if (node.next) |next_node| {
                // Intermediate node.
                new_node.next = next_node;
                next_node.prev = new_node;
            } else {
                // Last element of the self.
                new_node.next = null;
                self.last = new_node;
            }
            node.next = new_node;

            self.len += 1;
        }

        /// Insert a new node before an existing one.
        pub fn insertBefore(self: *Self, node: *Node, new_node: *Node) void {
            assert(new_node != node);
            assert(new_node.prev == null and new_node.next == null);

            new_node.next = node;
            if (node.prev) |prev_node| {
                // Intermediate node.
                new_node.prev = prev_node;
                prev_node.next = new_node;
            } else {
                // First element of the self.
                new_node.prev = null;
                self.first = new_node;
            }
            node.prev = new_node;

            self.len += 1;
        }

        /// Insert a new node at the end of the self.
        pub fn append(self: *Self, new_node: *Node) void {
            if (self.last) |last| {
                assert(self.len > 0);

                // Insert after last.
                self.insertAfter(last, new_node);
            } else {
                assert(self.first == null);
                assert(self.len == 0);

                // Empty self.
                self.prepend(new_node);
            }
        }

        /// Insert a new node at the beginning of the self.
        pub fn prepend(self: *Self, new_node: *Node) void {
            if (self.first) |first| {
                assert(self.len > 0);

                // Insert before first.
                self.insertBefore(first, new_node);
            } else {
                assert(self.last == null);
                assert(self.len == 0);

                // Empty self.
                self.first = new_node;
                self.last = new_node;
                new_node.prev = null;
                new_node.next = null;

                self.len = 1;
            }
        }

        /// Remove a node from the self.
        pub fn remove(self: *Self, node: *Node) void {
            assert(!(self.len > 1 and node.prev == null and node.next == null));
            assert(node.prev != node and node.next != node);
            assert(self.len > 0);

            if (node.prev) |prev_node| {
                // Intermediate node.
                prev_node.next = node.next;
            } else {
                // First element of the self.
                self.first = node.next;
            }

            if (node.next) |next_node| {
                // Intermediate node.
                next_node.prev = node.prev;
            } else {
                // Last element of the self.
                self.last = node.prev;
            }

            node.prev = null;
            node.next = null;
            self.len -= 1;
        }

        /// Remove and return the last node in the self.
        pub fn pop(self: *Self) ?*Node {
            if (self.last) |last| {
                self.remove(last);
                return last;
            }
            return null;
        }

        /// Remove and return the first node in the self.
        /// This operation has O(1) time complexity.
        pub fn popFirst(self: *Self) ?*Node {
            if (self.first) |first| {
                self.remove(first);
                return first;
            }
            return null;
        }

        /// Move a node to the end of the self.
        pub inline fn moveToBack(self: *Self, node: *Node) void {
            self.remove(node);
            self.append(node);
        }
    };
}
