const std = @import("std");
const zigache = @import("../zigache.zig");
const hash = zigache.hash;
const assert = std.debug.assert;

const Allocator = std.mem.Allocator;

/// Map is a generic key-value store that supports different types of keys and nodes.
/// It uses a hash map for fast lookups and a node pool for efficient memory management.
pub fn Map(
    comptime K: type,
    comptime V: type,
    comptime Data: type,
    comptime ttl_enabled: bool,
    comptime max_load_percentage: u64,
) type {
    return struct {
        pub const Pool = zigache.Pool(K, V, Data, ttl_enabled);
        pub const Node = Pool.Node;

        /// A struct that represents the result of a `getOrPut` operation.
        pub const GetOrPutResult = struct {
            node: *Node,
            found_existing: bool,
        };

        /// Uses StringHashMap for string keys and AutoHashMap for other types.
        ///
        /// `HashMap` is chosen over `ArrayHashMap` for its overall better performance,
        /// especially at larger cache sizes. While `HashMap` generally has faster
        /// lookup, insert, and delete operations, it does incur some overhead from
        /// rehashing to clean up tombstones after excessive deletes.
        ///
        /// At smaller cache sizes, `HashMap` might perform slightly worse due
        /// to the rehashing overhead. However, as cache size increases, `HashMap`'s
        /// performance advantages become more noticeable, outweighing the occasional
        /// rehashing cost and outperforming `ArrayHashMap`.
        ///
        /// The `checkAndRehash` method is used to mitigate the impact of tombstones,
        /// maintaining good performance even under heavy delete scenarios. Although
        /// this design choice is not the best, it works well across a wide range of
        /// cache sizes, particularly larger caches.
        const HashMapType = std.HashMapUnmanaged(K, *Node, MapContext, max_load_percentage);

        /// A context struct that provides hash and equality functions for hashmap.
        const MapContext = struct {
            pub fn hash(_: MapContext, key: K) u64 {
                return zigache.hash(K, key);
            }

            pub fn eql(_: MapContext, a: K, b: K) bool {
                return std.meta.eql(a, b);
            }
        };

        /// A context struct that provides stores a pre-generated hash.
        const HashContext = struct {
            hash_code: u64,

            /// Initialize a new HashContext with a pre-computed hash code.
            pub fn init(hash_code: u64) HashContext {
                return .{ .hash_code = hash_code };
            }

            /// Return the pre-computed hash code.
            pub fn hash(self: HashContext, _: K) u64 {
                return self.hash_code;
            }

            /// Check equality of two keys.
            pub fn eql(_: HashContext, a: K, b: K) bool {
                return if (K == []const u8) std.mem.eql(u8, a, b) else std.meta.eql(a, b);
            }
        };

        allocator: Allocator,
        map: HashMapType = .empty,
        pool: Pool,
        capacity: usize,
        tombstones: usize = 0,
        ctx: MapContext,

        const Self = @This();

        /// Initializes a new Map with the specified capacity and pre-allocation size.
        pub fn init(allocator: std.mem.Allocator, cache_size: u32, pool_size: u32) !Self {
            var self = Self{
                .allocator = allocator,
                .pool = try .init(allocator, pool_size),
                .capacity = cache_size,
                .ctx = undefined, // ctx is zero-sized so this is safe
            };
            try self.map.ensureTotalCapacity(allocator, pool_size);

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
        pub inline fn contains(self: *Self, key: K, hash_code: u64) bool {
            return self.map.containsAdapted(key, HashContext.init(hash_code));
        }

        /// Returns the number of items in this map.
        pub inline fn count(self: *Self) usize {
            return self.map.count();
        }

        /// Gets a node based on the given key.
        /// Returns a pointer to the Node if found, or null if not found.
        pub inline fn get(self: *Self, key: K, hash_code: u64) ?*Node {
            return self.map.getAdapted(key, HashContext.init(hash_code));
        }

        /// If an entry for the key does not exist in the map, a new node is created and inserted.
        /// Returns a `GetOrPutResult` struct containing the node and whether it existed before.
        pub fn getOrPut(self: *Self, key: K, hash_code: u64) !GetOrPutResult {
            self.checkAndRehash();

            // We only use a single `getOrPutAdapted` call here for a performance improvement
            // as compared to a previous implementation where we used separate `getAdapted`
            // and `getOrPutAdapted` calls.
            //
            // However, we only perform the eviction after acquiring a node because we need to
            // know whether the node already exists so we don't evict for no reason, which
            // requires an extra allocation for the cache.
            //
            // On the other hand, if we did the eviction before acquiring a node, there's a chance
            // that the node already exists and we evict a different node, which would be unnecessary.
            // This could also affect the hit rate of the cache, which is not desirable.
            const gop = try self.map.getOrPutAdapted(self.allocator, key, HashContext.init(hash_code));
            if (!gop.found_existing) {
                const node = try self.pool.acquire();
                gop.key_ptr.* = key;
                gop.value_ptr.* = node;
            }

            return .{
                .node = gop.value_ptr.*,
                .found_existing = gop.found_existing,
            };
        }

        /// Removes a key-value pair from the map if it exists.
        /// The node is not released back to the pool, allowing the caller to reuse it.
        /// Returns the node if it was removed, or null if not found.
        pub fn remove(self: *Self, key: K, hash_code: ?u64) ?*Node {
            self.checkAndRehash();

            const new_ctx = HashContext.init(hash_code orelse hash(K, key));
            const result = self.map.fetchRemoveAdapted(key, new_ctx);

            if (result) |kv| {
                self.tombstones += 1;
                // NOTE: We don't release the node back to the pool here because
                // there's a possibility it might be destroyed and the caller might
                // want to reuse it. For instance, the node might need to be removed
                // from a list or processed in some way.
                return kv.value;
            } else return null;
        }

        /// Checks if a node has expired based on its TTL (Time-To-Live).
        /// The node is not released back to the pool, allowing the caller to reuse it.
        /// Returns true if the node has expired and was removed, false otherwise.
        pub fn checkTTL(self: *Self, node: *Node, hash_code: ?u64) bool {
            if (node.expiry) |expiry| {
                // If the current time is greater than or equal to the expiry time,
                // the node has expired and should be removed from the map.
                const now = std.time.milliTimestamp();
                if (now >= expiry) {
                    const expired_node = self.remove(node.key, hash_code);
                    assert(expired_node == node);

                    return true;
                }
            }
            // If there's no expiration set (null) or the expiry time
            // hasn't been reached, the node is still valid.
            return false;
        }

        /// Rehash when number of tombstones reaches the configured maximum load. It's
        /// frequent enough to prevent significant performance degradation, and not so
        /// frequent that we waste time on unnecessary rehashes.
        ///
        /// This approach helps mitigate the impact of tombstones in delete-heavy scenarios.
        /// By rehashing, we're actively maintaining the hash table's performance, ensuring
        /// that operations like lookups remain efficient even as the table grows and changes.
        ///
        /// For more information, view Zig's issue #17851.
        inline fn checkAndRehash(self: *Self) void {
            const max_load = (self.map.size * max_load_percentage) / 100;
            if (self.tombstones >= max_load) {
                self.map.rehash(self.ctx);
                self.tombstones = 0;
            }
        }
    };
}

const testing = std.testing;

const TestMap = Map([]const u8, u32, void, true, 60);

test "Map - init and deinit" {
    var map: TestMap = try .init(testing.allocator, 100, 10);
    defer map.deinit();

    try testing.expectEqual(0, map.count());
    try testing.expectEqual(100, map.capacity);
}

test "Map - put and get" {
    var map: TestMap = try .init(testing.allocator, 1, 1);
    defer map.deinit();

    const key = "key1";
    const hash_code = hash([]const u8, key);

    // Insert a new entry
    {
        const gop = try map.getOrPut(key, hash_code);
        const node = gop.node;

        try testing.expect(!gop.found_existing);
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
    var map: TestMap = try .init(testing.allocator, 1, 1);
    defer map.deinit();

    const key = "key1";
    const hash_code = hash([]const u8, key);

    _ = try map.getOrPut(key, hash_code);

    const node = map.remove(key, hash_code);
    try testing.expect(node != null);
    try testing.expect(map.get(key, hash_code) == null);
    map.pool.release(node.?);

    // Ensure that a second remove is idempotent
    try testing.expect(map.remove(key, hash_code) == null);
}

test "Map - contains" {
    var map: TestMap = try .init(testing.allocator, 2, 2);
    defer map.deinit();

    const key1 = "key1";
    const key2 = "key2";
    const hash_code1 = hash([]const u8, key1);
    const hash_code2 = hash([]const u8, key2);

    _ = try map.getOrPut(key1, hash_code1);
    _ = try map.getOrPut(key2, hash_code2);

    const node = map.remove(key2, hash_code2);
    try testing.expect(node != null);
    map.pool.release(node.?);

    try testing.expect(map.contains(key1, hash_code1));
    try testing.expect(!map.contains(key2, hash_code2));
}

test "Map - checkTTL" {
    var map: TestMap = try .init(testing.allocator, 1, 1);
    defer map.deinit();

    const key = "key1";
    const hash_code = hash([]const u8, key);

    const gop = try map.getOrPut(key, hash_code);
    const node = gop.node;
    node.* = .{
        .key = key,
        .value = 1,
        .next = null,
        .prev = null,
        .expiry = std.time.milliTimestamp() - 1000,
        .data = {},
    };

    try testing.expect(map.checkTTL(node, hash_code));
    try testing.expect(map.get(key, hash_code) == null);
    map.pool.release(node);
}

test "Map - update existing entry" {
    var map: TestMap = try .init(testing.allocator, 1, 1);
    defer map.deinit();

    const key = "key1";
    const hash_code = hash([]const u8, key);

    // First insertion
    {
        const gop = try map.getOrPut(key, hash_code);
        const node = gop.node;
        try testing.expect(!gop.found_existing);
        node.value = 1;
    }

    // Update existing entry
    {
        const gop = try map.getOrPut(key, hash_code);
        const node = gop.node;
        try testing.expect(gop.found_existing);
        node.value = 10;
    }

    const node = map.get(key, hash_code);
    try testing.expect(node != null);
    try testing.expectEqual(10, node.?.value);
}
