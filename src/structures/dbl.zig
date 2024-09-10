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
        pub fn insertAfter(list: *Self, node: *Node, new_node: *Node) void {
            assert(new_node != node);
            assert(new_node.prev == null and new_node.next == null);

            new_node.prev = node;
            if (node.next) |next_node| {
                // Intermediate node.
                new_node.next = next_node;
                next_node.prev = new_node;
            } else {
                // Last element of the list.
                new_node.next = null;
                list.last = new_node;
            }
            node.next = new_node;

            list.len += 1;
        }

        /// Insert a new node before an existing one.
        pub fn insertBefore(list: *Self, node: *Node, new_node: *Node) void {
            assert(new_node != node);
            assert(new_node.prev == null and new_node.next == null);

            new_node.next = node;
            if (node.prev) |prev_node| {
                // Intermediate node.
                new_node.prev = prev_node;
                prev_node.next = new_node;
            } else {
                // First element of the list.
                new_node.prev = null;
                list.first = new_node;
            }
            node.prev = new_node;

            list.len += 1;
        }

        /// Insert a new node at the end of the list.
        pub fn append(list: *Self, new_node: *Node) void {
            if (list.last) |last| {
                assert(list.len > 0);

                // Insert after last.
                list.insertAfter(last, new_node);
            } else {
                assert(list.first == null);
                assert(list.len == 0);

                // Empty list.
                list.prepend(new_node);
            }
        }

        /// Insert a new node at the beginning of the list.
        pub fn prepend(list: *Self, new_node: *Node) void {
            if (list.first) |first| {
                assert(list.len > 0);

                // Insert before first.
                list.insertBefore(first, new_node);
            } else {
                assert(list.last == null);
                assert(list.len == 0);

                // Empty list.
                list.first = new_node;
                list.last = new_node;
                new_node.prev = null;
                new_node.next = null;

                list.len = 1;
            }
        }

        /// Remove a node from the list.
        pub fn remove(list: *Self, node: *Node) void {
            assert(!(list.len > 1 and node.prev == null and node.next == null));
            assert(node.prev != node and node.next != node);
            assert(list.len > 0);

            if (node.prev) |prev_node| {
                // Intermediate node.
                prev_node.next = node.next;
            } else {
                // First element of the list.
                list.first = node.next;
            }

            if (node.next) |next_node| {
                // Intermediate node.
                next_node.prev = node.prev;
            } else {
                // Last element of the list.
                list.last = node.prev;
            }

            node.prev = null;
            node.next = null;
            list.len -= 1;
        }

        /// Remove and return the last node in the list.
        pub fn pop(list: *Self) ?*Node {
            if (list.last) |last| {
                list.remove(last);
                return last;
            }
            return null;
        }

        /// Remove and return the first node in the list.
        /// This operation has O(1) time complexity.
        pub fn popFirst(list: *Self) ?*Node {
            if (list.first) |first| {
                list.remove(first);
                return first;
            }
            return null;
        }

        /// Move a node to the end of the list.
        pub inline fn moveToBack(list: *Self, node: *Node) void {
            list.remove(node);
            list.append(node);
        }
    };
}
