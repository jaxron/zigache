const std = @import("std");
const zigache = @import("../zigache.zig");
const assert = std.debug.assert;

const Allocator = std.mem.Allocator;

/// Node object pool for managing memory allocations.
///
/// This minimizes allocations and deallocations by reusing memory,
/// which can significantly improve performance in high-churn scenarios
/// by reducing pressure on the allocator and avoiding fragmentation.
pub fn Pool(comptime K: type, comptime V: type, comptime Data: type, comptime ttl_enabled: bool) type {
    return struct {
        /// Node represents an item in the cache.
        /// It contains the key-value pair, expiry information (if TTL is enabled),
        /// custom data, and pointers for the doubly-linked list structure.
        pub const Node = struct {
            prev: ?*Node,
            next: ?*Node,
            key: K,
            value: V,
            expiry: if (ttl_enabled) ?i64 else void,
            data: Data,

            pub inline fn update(self: *Node, key: K, value: V, ttl: ?u64, data: Data) void {
                self.* = .{
                    .prev = self.prev,
                    .next = self.next,
                    .key = key,
                    .value = value,
                    .expiry = if (ttl_enabled)
                        if (ttl) |t| std.time.milliTimestamp() + @as(i64, @intCast(t)) else null
                    else {},
                    .data = data,
                };
            }
        };

        allocator: Allocator,
        nodes: []*Node,
        available: usize,

        const Self = @This();

        /// Initializes a new pool with the specified allocator and initial size.
        pub fn init(allocator: Allocator, initial_size: u32) !Self {
            const nodes = try allocator.alloc(*Node, initial_size);
            errdefer allocator.free(nodes);

            var available: usize = 0;
            errdefer {
                for (nodes[0..available]) |node| {
                    allocator.destroy(node);
                }
            }

            for (0..initial_size) |i| {
                const node = try allocator.create(Node);
                node.prev = null;
                node.next = null;
                nodes[i] = node;
                available += 1;
            }

            return .{
                .allocator = allocator,
                .nodes = nodes,
                .available = available,
            };
        }

        /// Releases all resources associated with this pool.
        pub fn deinit(self: *Self) void {
            assert(self.available == self.nodes.len);
            for (self.nodes) |node| {
                self.allocator.destroy(node);
            }
            self.allocator.free(self.nodes);
        }

        /// Acquires a Node from the pool or creates a new one if the pool is empty.
        /// The caller is responsible for releasing the node back to the pool when done.
        pub fn acquire(self: *Self) !*Node {
            const available = self.available;
            if (available == 0) {
                // Pool is empty, create a new node
                const node = try self.allocator.create(Node);
                node.prev = null;
                node.next = null;
                return node;
            }

            // Get a node from the pool
            const index = available - 1;
            self.available = index;
            return self.nodes[index];
        }

        /// Releases a Node back to the pool or destroys it if the pool is full.
        /// This should be called when the node is no longer needed.
        pub fn release(self: *Self, node: *Node) void {
            const available = self.available;
            if (available == self.nodes.len) {
                // Pool is full, destroy the node
                self.allocator.destroy(node);
                return;
            }

            // Return the node to the pool
            self.nodes[available] = node;
            self.available += 1;
        }
    };
}

const testing = std.testing;

const TestPool = zigache.Pool(u32, u32, void, false);

test "Pool - init and deinit" {
    const initial_size: u32 = 10;
    var pool: TestPool = try .init(testing.allocator, initial_size);
    defer pool.deinit();

    try testing.expectEqual(initial_size, pool.available);
    try testing.expectEqual(initial_size, pool.nodes.len);

    // Ensure all nodes are properly initialized
    for (pool.nodes) |node| {
        try testing.expect(node.prev == null);
        try testing.expect(node.next == null);
    }
}

test "Pool - acquire and release" {
    const initial_size: u32 = 2;
    var pool: TestPool = try .init(testing.allocator, initial_size);
    defer pool.deinit();

    // Acquire nodes until the pool is empty
    const node1 = try pool.acquire();
    try testing.expectEqual(1, pool.available);

    const node2 = try pool.acquire();
    try testing.expectEqual(0, pool.available);

    // Acquire when pool is empty (should create a new node)
    const node3 = try pool.acquire();
    try testing.expectEqual(0, pool.available);

    // Release nodes back to the pool
    pool.release(node1);
    try testing.expectEqual(1, pool.available);

    pool.release(node2);
    try testing.expectEqual(2, pool.available);

    // Release when pool is full (should destroy the node)
    const initial_ptr = node3;
    pool.release(node3);
    try testing.expectEqual(2, pool.available);

    // Verify that acquiring now returns a pooled node, not the destroyed one
    const new_node = try pool.acquire();
    try testing.expect(new_node != initial_ptr);
    try testing.expectEqual(1, pool.available);
    pool.release(new_node);
}

test "Pool - node reuse" {
    const initial_size: u32 = 1;
    var pool: TestPool = try .init(testing.allocator, initial_size);
    defer pool.deinit();

    const node1 = try pool.acquire();
    try testing.expectEqual(0, pool.available);

    pool.release(node1);
    try testing.expectEqual(1, pool.available);

    const node2 = try pool.acquire();
    try testing.expectEqual(0, pool.available);

    // Verify that the same node was reused
    try testing.expectEqual(@intFromPtr(node1), @intFromPtr(node2));
    pool.release(node2);
}

test "Pool - update node" {
    var pool: TestPool = try .init(testing.allocator, 1);
    defer pool.deinit();

    const node = try pool.acquire();
    node.update(0, 100, null, {});

    try testing.expectEqual(0, node.key);
    try testing.expectEqual(100, node.value);
    pool.release(node);
}
