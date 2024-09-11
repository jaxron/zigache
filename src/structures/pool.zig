const std = @import("std");

const Allocator = std.mem.Allocator;

/// Node object pool for managing memory allocations.
///
/// This minimizes allocations and deallocations by reusing memory,
/// which can significantly improve performance in high-churn scenarios
/// by reducing pressure on the allocator and avoiding fragmentation.
pub fn Pool(comptime Node: type) type {
    return struct {
        allocator: Allocator,
        nodes: []*Node,
        available: u32,

        const Self = @This();

        /// Initializes a new pool with the specified allocator and initial size.
        pub fn init(allocator: Allocator, initial_size: u32) !Self {
            const nodes = try allocator.alloc(*Node, initial_size);
            errdefer allocator.free(nodes);

            // Pre-allocate nodes
            for (0..initial_size) |i| {
                const node = try allocator.create(Node);
                node.next = null;
                node.prev = null;
                nodes[i] = node;
            }

            return .{
                .allocator = allocator,
                .nodes = nodes,
                .available = initial_size,
            };
        }

        /// Releases all resources associated with this pool.
        pub fn deinit(self: *Self) void {
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
                return self.allocator.create(Node);
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

const TestNode = struct {
    value: u32,
    next: ?*TestNode = null,
    prev: ?*TestNode = null,
};

test "Pool - init and deinit" {
    var pool = try Pool(TestNode).init(testing.allocator, 10);
    defer pool.deinit();

    try testing.expectEqual(10, pool.available);
    try testing.expectEqual(10, pool.nodes.len);
}

test "Pool - acquire and release" {
    var pool = try Pool(TestNode).init(testing.allocator, 2);
    defer pool.deinit();

    // Acquire nodes until the pool is empty
    const node1 = try pool.acquire();
    try testing.expectEqual(1, pool.available);

    const node2 = try pool.acquire();
    try testing.expectEqual(0, pool.available);

    // Acquire when pool is empty
    const node3 = try pool.acquire();
    try testing.expectEqual(0, pool.available);

    pool.release(node1);
    try testing.expectEqual(1, pool.available);

    pool.release(node2);
    try testing.expectEqual(2, pool.available);

    // Release when pool is full
    pool.release(node3);
    try testing.expectEqual(2, pool.available);
}
