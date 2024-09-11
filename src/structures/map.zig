const std = @import("std");
const pool = @import("pool.zig");
const utils = @import("../utils/utils.zig");
const assert = std.debug.assert;

const Allocator = std.mem.Allocator;

/// Map is a generic key-value store that supports different types of keys and nodes.
/// It uses a hash map for fast lookups and a node pool for efficient memory management.
pub fn Map(comptime Node: type) type {
    const K = @TypeOf(@field(@as(Node, undefined), "key"));
    return struct {
        /// Uses StringArrayHashMapUnmanaged for string keys,
        /// and AutoArrayHashMapUnmanaged for other types.
        const HashMapType = if (K == []const u8)
            std.StringArrayHashMapUnmanaged(*Node)
        else
            std.AutoArrayHashMapUnmanaged(K, *Node);

        /// A context struct that provides hash and equality functions for hashmap.
        const HashContext = struct {
            hash_code: u64,

            /// Initialize a new HashContext with a pre-computed hash code.
            pub fn init(hash_code: u64) HashContext {
                return .{ .hash_code = hash_code };
            }

            /// Return the pre-computed hash code.
            pub fn hash(self: HashContext, _: K) u32 {
                return @truncate(self.hash_code);
            }

            /// Check equality of two keys.
            pub fn eql(_: HashContext, a: K, b: K, _: usize) bool {
                if (K == []const u8) {
                    return std.mem.eql(u8, a, b);
                }
                return std.meta.eql(a, b);
            }
        };

        allocator: std.mem.Allocator,
        map: HashMapType = .{},
        pool: pool.Pool(Node),
        capacity: usize,

        const Self = @This();

        /// Initializes a new Map with the specified capacity and pre-allocation size.
        pub fn init(allocator: std.mem.Allocator, total_size: u32, base_size: u32) !Self {
            var self = Self{
                .allocator = allocator,
                // We allocate an extra node to handle the case where the pool
                // is full since we acquire a node before the eviction process.
                // Check the `set` method for more information.
                .pool = try pool.Pool(Node).init(allocator, total_size + 1),
                .capacity = total_size,
            };
            try self.map.ensureTotalCapacity(allocator, base_size + 1);

            return self;
        }

        /// Releases all resources associated with this map.
        pub fn deinit(self: *Self) void {
            var iter = self.map.iterator();
            while (iter.next()) |entry| {
                self.pool.release(entry.value_ptr.*);
            }
            self.pool.deinit();
            self.map.deinit(self.allocator);
        }

        /// Returns true if a key exists in the map.
        pub fn contains(self: *Self, key: K, hash_code: u64) bool {
            return self.map.containsAdapted(key, HashContext.init(hash_code));
        }

        /// Returns the number of items in this map.
        pub fn count(self: *Self) usize {
            return self.map.count();
        }

        /// Gets a node based on the given key.
        /// Returns a pointer to the Node if found, or null if not found.
        pub fn get(self: *Self, key: K, hash_code: u64) ?*Node {
            return self.map.getAdapted(key, HashContext.init(hash_code));
        }

        /// Adds or updates a key-value pair in the map.
        /// Returns a tuple containing:
        /// - A pointer to the Node (either newly created or existing)
        /// - A boolean indicating whether an existing entry was returned (true) or a new one was created (false)
        pub fn set(self: *Self, key: K, hash_code: u64) !struct { *Node, bool } {
            // We only use a single `getOrPutAdapted` call here for a performance improvement
            // as compared to a previous implementation where we used separate `getAdapted`
            // and `getOrPutAdapted` calls.
            //
            // However, eviction is now performed after acquiring a node, which requires an
            // extra allocation. But the overall gains from reducing scans outweigh this
            // small downside.
            const gop = try self.map.getOrPutAdapted(self.allocator, key, HashContext.init(hash_code));
            if (!gop.found_existing) {
                const node = try self.pool.acquire();
                gop.key_ptr.* = key;
                gop.value_ptr.* = node;
            }

            return .{ gop.value_ptr.*, gop.found_existing };
        }

        /// Removes a key-value pair from the map if it exists.
        /// The node is not released back to the pool, allowing the caller to reuse it.
        /// Returns the node if it was removed, or null if not found.
        pub fn remove(self: *Self, key: K, hash_code: ?u64) ?*Node {
            const new_ctx = HashContext.init(hash_code orelse utils.hash(K, key));
            const result = self.map.fetchSwapRemoveAdapted(key, new_ctx);

            // NOTE: We don't release the node back to the pool here because
            // the caller might want to reuse it. For instance, the node might
            // need to be removed from a list or processed in some way.
            return if (result) |kv| kv.value else null;
        }

        /// Checks if a node has expired based on its TTL (Time-To-Live).
        /// Returns true if the node has expired and was removed, false otherwise.
        pub fn checkTTL(self: *Self, node: *Node) bool {
            if (node.expiry) |expiry| {
                // If the current time is greater than or equal to the expiry time,
                // the node has expired and should be removed from the map and
                // released back to the node pool.
                const now = std.time.milliTimestamp();
                if (now >= expiry) {
                    assert(self.map.swapRemove(node.key));
                    self.pool.release(node);
                    return true;
                }
            }
            // If there's no expiration set (null) or the expiry time
            // hasn't been reached, the node is still valid.
            return false;
        }
    };
}

const testing = std.testing;

const TestMap = Map(TestNode);
const TestNode = struct {
    key: []const u8,
    value: u32,
    next: ?*TestNode = null,
    prev: ?*TestNode = null,
    expiry: ?i64,
};

test "Map - init and deinit" {
    var map = try TestMap.init(testing.allocator, 100, 10);
    defer map.deinit();

    try testing.expectEqual(0, map.count());
    try testing.expectEqual(100, map.capacity);
}

test "Map - set and get" {
    var map = try TestMap.init(testing.allocator, 1, 1);
    defer map.deinit();

    const key = "key1";
    const hash_code = utils.hash([]const u8, key);

    // Insert a new entry
    {
        const node, const found_existing = try map.set(key, hash_code);
        try testing.expect(!found_existing);
        node.key = key;
        node.value = 1;
    }

    // Retrieve the entry
    {
        const node = map.get(key, hash_code);
        try testing.expect(node != null);
        try testing.expectEqualStrings(key, node.?.key);
        try testing.expectEqual(1, node.?.value);
    }
}

test "Map - remove" {
    var map = try TestMap.init(testing.allocator, 1, 1);
    defer map.deinit();

    const key = "key1";
    const hash_code = utils.hash([]const u8, key);

    _ = try map.set(key, hash_code);

    const node = map.remove(key, hash_code);
    try testing.expect(node != null);
    try testing.expect(map.get(key, hash_code) == null);
    map.pool.release(node.?);

    // Ensure that a second remove is idempotent
    try testing.expect(map.remove(key, hash_code) == null);
}

test "Map - contains" {
    var map = try TestMap.init(testing.allocator, 2, 2);
    defer map.deinit();

    const key1 = "key1";
    const key2 = "key2";
    const hash_code1 = utils.hash([]const u8, key1);
    const hash_code2 = utils.hash([]const u8, key2);

    _ = try map.set(key1, hash_code1);
    _ = try map.set(key2, hash_code2);

    const node = map.remove(key2, hash_code2);
    try testing.expect(node != null);
    map.pool.release(node.?);

    try testing.expect(map.contains(key1, hash_code1));
    try testing.expect(!map.contains(key2, hash_code2));
}

test "Map - checkTTL" {
    var map = try TestMap.init(testing.allocator, 1, 1);
    defer map.deinit();

    const key = "key1";
    const hash_code = utils.hash([]const u8, key);

    const node, _ = try map.set(key, hash_code);
    node.* = .{
        .key = key,
        .value = 1,
        .expiry = std.time.milliTimestamp() - 1000, // Set expiry to 1 second ago
    };

    try testing.expect(map.checkTTL(node));
    try testing.expect(map.get(key, hash_code) == null);
}

test "Map - update existing entry" {
    var map = try TestMap.init(testing.allocator, 1, 1);
    defer map.deinit();

    const key = "key1";
    const hash_code = utils.hash([]const u8, key);

    // First insertion
    {
        const node, const found_existing = try map.set(key, hash_code);
        try testing.expect(!found_existing);
        node.value = 1;
    }

    // Update existing entry
    {
        const node, const found_existing = try map.set(key, hash_code);
        try testing.expect(found_existing);
        node.value = 10;
    }

    const node = map.get(key, hash_code);
    try testing.expect(node != null);
    try testing.expectEqual(10, node.?.value);
}