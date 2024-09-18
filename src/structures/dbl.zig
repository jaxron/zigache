const std = @import("std");
const zigache = @import("../zigache.zig");
const assert = std.debug.assert;

/// A generic doubly-linked list modified from Zig's std library.
/// The implementation uses asserts to check for impossible cases, which
/// helps catch bugs and invalid states during development and testing.
/// All operations have O(1) time complexity, except for `clear()` which is O(n).
pub fn DoublyLinkedList(comptime K: type, comptime V: type, comptime Data: type, comptime ttl_enabled: bool) type {
    return struct {
        pub const Node = zigache.Map(K, V, Data, ttl_enabled).Node;

        pub const empty: Self = .{
            .first = null,
            .last = null,
            .len = 0,
        };

        first: ?*Node,
        last: ?*Node,
        len: usize,

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

        /// Remove all nodes from the list.
        pub fn clear(self: *Self) void {
            while (self.popFirst()) |_| {}

            assert(self.first == null);
            assert(self.last == null);
            assert(self.len == 0);
        }
    };
}

const testing = std.testing;

const TestList = DoublyLinkedList(u32, u32, void, false);
const TestNode = zigache.Map(u32, u32, void, false).Node;

fn initTestNode(value: u32) TestNode {
    return .{
        .key = value,
        .value = value,
        .prev = null,
        .next = null,
        .expiry = {},
        .data = {},
    };
}

test "DoublyLinkedList - basic operations" {
    var list: TestList = .empty;
    var node1 = initTestNode(1);
    var node2 = initTestNode(2);
    var node3 = initTestNode(3);

    // Test append
    list.append(&node1);
    try testing.expectEqual(1, list.len);
    try testing.expectEqual(&node1, list.first);
    try testing.expectEqual(&node1, list.last);

    // Test prepend
    list.prepend(&node2);
    try testing.expectEqual(2, list.len);
    try testing.expectEqual(&node2, list.first);
    try testing.expectEqual(&node1, list.last);

    // Test insertAfter
    list.insertAfter(&node2, &node3);
    try testing.expectEqual(3, list.len);
    try testing.expectEqual(&node3, node2.next);
    try testing.expectEqual(&node1, node3.next);

    // Test remove
    list.remove(&node3);
    try testing.expectEqual(2, list.len);
    try testing.expectEqual(&node1, node2.next);
    try testing.expectEqual(&node2, node1.prev);

    // Test pop
    var popped = list.pop();
    try testing.expectEqual(&node1, popped);
    try testing.expectEqual(1, list.len);
    try testing.expectEqual(&node2, list.first);
    try testing.expectEqual(&node2, list.last);

    // Test popFirst
    popped = list.popFirst();
    try testing.expectEqual(&node2, popped);
    try testing.expectEqual(0, list.len);
    try testing.expectEqual(null, list.first);
    try testing.expectEqual(null, list.last);
}

test "DoublyLinkedList - edge cases" {
    var list: TestList = .empty;
    var node1 = initTestNode(1);
    var node2 = initTestNode(2);

    // Test empty list
    try testing.expectEqual(null, list.pop());
    try testing.expectEqual(null, list.popFirst());

    // Test single element
    list.append(&node1);
    try testing.expectEqual(1, list.len);
    try testing.expectEqual(&node1, list.first);
    try testing.expectEqual(&node1, list.last);

    // Test removing single element
    list.remove(&node1);
    try testing.expectEqual(0, list.len);
    try testing.expectEqual(null, list.first);
    try testing.expectEqual(null, list.last);

    // Test insertBefore on empty list
    list.prepend(&node1);
    list.insertBefore(&node1, &node2);
    try testing.expectEqual(2, list.len);
    try testing.expectEqual(&node2, list.first);
    try testing.expectEqual(&node1, list.last);
}

test "DoublyLinkedList - moveToBack" {
    var list: TestList = .empty;
    var node1 = initTestNode(1);
    var node2 = initTestNode(2);
    var node3 = initTestNode(3);

    list.append(&node1);
    list.append(&node2);
    list.append(&node3);

    list.moveToBack(&node1);
    try testing.expectEqual(&node2, list.first);
    try testing.expectEqual(&node1, list.last);
    try testing.expectEqual(3, list.len);
}

test "DoublyLinkedList - clear" {
    var list: TestList = .empty;
    var node1 = initTestNode(1);
    var node2 = initTestNode(2);

    list.append(&node1);
    list.append(&node2);

    list.clear();
    try testing.expectEqual(0, list.len);
    try testing.expectEqual(null, list.first);
    try testing.expectEqual(null, list.last);
}
