const std = @import("std");
const zigache = @import("../zigache.zig");
const assert = std.debug.assert;

const PolicyOptions = zigache.CacheInitOptions.PolicyOptions;
const CacheTypeOptions = zigache.CacheTypeOptions;
const Allocator = std.mem.Allocator;

/// S3FIFO is an advanced FIFO-based caching policy that uses three segments:
/// small, main, and ghost. It aims to combine the simplicity of FIFO with
/// improved performance for various access patterns. S3FIFO can adapt to both
/// recency and frequency of access, making it effective for a wide range of
/// workloads.
///
/// More information can be found here:
/// https://s3fifo.com/
pub fn S3FIFO(comptime K: type, comptime V: type, comptime cache_opts: CacheTypeOptions) type {
    const thread_safety = cache_opts.thread_safety;
    const ttl_enabled = cache_opts.ttl_enabled;
    const max_load_percentage = cache_opts.max_load_percentage;

    return struct {
        const Promotion = enum { SmallToMain, SmallToGhost, GhostToMain };
        const QueueType = enum { Small, Main, Ghost };

        const Data = struct {
            // Indicates which queue (Small, Main, or Ghost) the node is currently in
            queue: QueueType,
            // Tracks the access frequency of the node, used for eviction decisions
            freq: u2,
        };

        const Map = zigache.Map(K, V, Data, ttl_enabled, max_load_percentage);
        const DoublyLinkedList = zigache.DoublyLinkedList(K, V, Data, ttl_enabled);
        const Mutex = if (thread_safety) std.Thread.RwLock else void;
        const Node = Map.Node;

        map: Map,
        small: DoublyLinkedList = .empty,
        main: DoublyLinkedList = .empty,
        ghost: DoublyLinkedList = .empty,
        mutex: Mutex = if (thread_safety) .{} else {},

        max_size: u32,
        main_size: usize,
        small_size: usize,
        ghost_size: usize,

        const Self = @This();

        /// Initialize a new S3FIFO cache with the given configuration.
        pub fn init(allocator: std.mem.Allocator, cache_size: u32, pool_size: u32, opts: PolicyOptions) !Self {
            // Allocate 10% of total size to small queue, and split the rest between main and ghost
            const small_size = @max(1, cache_size * opts.S3FIFO.small_size_percent / 100);
            const other_size = @max(1, (cache_size - small_size) / 2);

            return .{
                .map = try .init(allocator, cache_size, pool_size),
                .max_size = small_size + other_size * 2,
                .main_size = other_size,
                .small_size = small_size,
                .ghost_size = other_size,
            };
        }

        /// Cleans up all resources used by the cache.
        pub fn deinit(self: *Self) void {
            self.small.clear();
            self.main.clear();
            self.ghost.clear();
            self.map.deinit();
        }

        /// Returns true if a key exists in the cache, false otherwise.
        /// This method does not update the cache state or affect eviction order.
        pub inline fn contains(self: *Self, key: K, hash_code: u64) bool {
            if (thread_safety) self.mutex.lockShared();
            defer if (thread_safety) self.mutex.unlockShared();

            return self.map.contains(key, hash_code);
        }

        /// Returns the total number of items currently stored in the cache.
        /// This count includes items in all regions of the cache.
        pub inline fn count(self: *Self) usize {
            if (thread_safety) self.mutex.lockShared();
            defer if (thread_safety) self.mutex.unlockShared();

            return self.map.count();
        }

        /// Retrieves a value from the cache given its key.
        /// If the key exists and is not expired, it returns the associated value and increments the entry's frequency.
        /// If the key doesn't exist or has expired, it returns null.
        pub fn get(self: *Self, key: K, hash_code: u64) ?V {
            if (thread_safety) self.mutex.lock();
            defer if (thread_safety) self.mutex.unlock();

            if (self.map.get(key, hash_code)) |node| {
                if (ttl_enabled and self.map.checkTTL(node, hash_code)) {
                    self.removeFromList(node);
                    self.map.pool.release(node);
                    return null;
                }

                // Increment frequency, capped at 3
                if (node.data.freq < 3) {
                    node.data.freq = @min(node.data.freq + 1, 3);
                }
                return node.value;
            }
            return null;
        }

        /// Inserts or updates a key-value pair in the cache with an optional Time-To-Live (TTL).
        /// If the key already exists, its value and TTL are updated. If the cache is full, it
        /// will trigger an eviction. Both the key and value must remain valid for as long as
        /// they're in the cache.
        pub fn put(self: *Self, key: K, value: V, ttl: ?u64, hash_code: u64) !void {
            if (thread_safety) self.mutex.lock();
            defer if (thread_safety) self.mutex.unlock();

            // Ensure cache size doesn't exceed max_size
            while (self.small.len + self.main.len + self.ghost.len >= self.max_size) {
                self.evict();
            }

            const gop = try self.map.getOrPut(key, hash_code);
            const node = gop.node;
            node.update(key, value, ttl, .{
                .queue = if (gop.found_existing) node.data.queue else .Small,
                .freq = if (gop.found_existing) node.data.freq else 0,
            });

            if (gop.found_existing) {
                if (node.data.queue == .Ghost) {
                    // Move from Ghost to Main on re-insertion
                    node.data.queue = .Main;
                    self.ghost.remove(node);
                    self.main.append(node);
                }
            } else {
                // New items always start in Small queue
                self.small.append(node);
            }
        }

        /// Removes a key-value pair from the cache if it exists.
        /// Returns true if it was successfully removed, false otherwise.
        pub fn remove(self: *Self, key: K, hash_code: u64) bool {
            if (thread_safety) self.mutex.lock();
            defer if (thread_safety) self.mutex.unlock();

            return if (self.map.remove(key, hash_code)) |node| {
                // Remove the node from the respective list as well
                self.removeFromList(node);
                self.map.pool.release(node);
                return true;
            } else false;
        }

        /// Internal method to handle cache eviction in S3FIFO.
        /// Evicts items based on their location in the three segments and their access frequency.
        fn evict(self: *Self) void {
            // Prioritize evicting from Small queue if it's full
            if (self.small.len >= self.small_size) {
                self.evictSmall();
            } else {
                self.evictMain();
            }
        }

        /// Handles the eviction process for the main cache segment.
        /// It removes items with zero frequency and decrements the frequency of others.
        fn evictMain(self: *Self) void {
            while (self.main.popFirst()) |node| {
                if (node.data.freq > 0) {
                    node.data.freq -= 1;
                    self.main.append(node);
                } else {
                    assert(self.map.remove(node.key, null) != null);
                    self.map.pool.release(node);
                    break;
                }
            }
        }

        /// Handles the eviction process for the small cache segment.
        /// It promotes frequently accessed items to the main segment and moves others to the ghost segment.
        fn evictSmall(self: *Self) void {
            while (self.small.popFirst()) |node| {
                // The S3FIFO paper suggests checking if freq > 1, but due to bad hitrate
                // in short to medium term tests, we're using freq > 0 instead.
                if (node.data.freq > 0) {
                    node.data.freq = 0;
                    node.data.queue = .Main;
                    self.main.append(node);
                } else {
                    if (self.ghost.len >= self.main_size) {
                        self.evictGhost();
                    }
                    node.data.queue = .Ghost;
                    self.ghost.append(node);
                    break;
                }
            }
        }

        /// Handles the eviction process for the ghost cache segment.
        /// It removes the oldest item when it reaches capacity.
        fn evictGhost(self: *Self) void {
            if (self.ghost.popFirst()) |node| {
                // Remove oldest ghost entry when ghost queue is full
                assert(self.map.remove(node.key, null) != null);
                self.map.pool.release(node);
            }
        }

        /// Removes the node from its current list (Small, Main, or Ghost) based on its queue type.
        /// This is an internal helper method used during eviction and removal operations.
        fn removeFromList(self: *Self, node: *Node) void {
            switch (node.data.queue) {
                .Small => self.small.remove(node),
                .Main => self.main.remove(node),
                .Ghost => self.ghost.remove(node),
            }
        }
    };
}

const testing = std.testing;

test "S3FIFO - basic insert and get" {
    var cache: zigache.Cache(u32, []const u8, .{}) = try .init(testing.allocator, .{ .cache_size = 2, .policy = .{ .S3FIFO = .{} } });
    defer cache.deinit();

    try cache.put(1, "value1");
    try cache.put(2, "value2");

    try testing.expectEqualStrings("value1", cache.get(1).?);
    try testing.expectEqualStrings("value2", cache.get(2).?);
}

test "S3FIFO - overwrite existing key" {
    var cache: zigache.Cache(u32, []const u8, .{}) = try .init(testing.allocator, .{ .cache_size = 2, .policy = .{ .S3FIFO = .{} } });
    defer cache.deinit();

    try cache.put(1, "value1");
    try cache.put(1, "new_value1");

    // Check that the value has been updated
    try testing.expectEqualStrings("new_value1", cache.get(1).?);
}

test "S3FIFO - remove key" {
    var cache: zigache.Cache(u32, []const u8, .{}) = try .init(testing.allocator, .{ .cache_size = 1, .policy = .{ .S3FIFO = .{} } });
    defer cache.deinit();

    try cache.put(1, "value1");

    // Remove the key and check that it's no longer present
    try testing.expect(cache.remove(1));
    try testing.expect(cache.get(1) == null);

    // Ensure that a second remove is idempotent
    try testing.expect(!cache.remove(1));
}

test "S3FIFO - eviction and promotion" {
    var cache: zigache.Cache(u32, []const u8, .{}) = try .init(testing.allocator, .{ .cache_size = 5, .policy = .{ .S3FIFO = .{} } }); // Total size: 5 (small: 1, main: 2, ghost: 2)
    defer cache.deinit();

    // Fill the cache
    try cache.put(1, "value1");
    try cache.put(2, "value2");
    try cache.put(3, "value3");
    try cache.put(4, "value4");
    try cache.put(5, "value5");

    // Access increase the frequency of 1, 2, 3, 4
    _ = cache.get(1);
    _ = cache.get(2);
    _ = cache.get(3);
    _ = cache.get(4);

    // Insert a new key, which should evict key 1 (least frequently used )
    try cache.put(6, "value6"); // 6 moves to small, 5 is evicted to ghost, everything else moves to main

    // We expect key 5 to be in the ghost cache
    try testing.expect(cache.get(1) == null);
    try testing.expect(cache.get(2) != null);
    try testing.expect(cache.get(3) != null);
    try testing.expect(cache.get(4) != null);
    try testing.expect(cache.get(5) != null);
    try testing.expect(cache.get(6) != null);
}

test "S3FIFO - TTL functionality" {
    var cache: zigache.Cache(u32, []const u8, .{ .ttl_enabled = true }) = try .init(testing.allocator, .{ .cache_size = 1, .policy = .{ .S3FIFO = .{} } });
    defer cache.deinit();

    try cache.putWithTTL(1, "value1", 1); // 1ms TTL
    std.time.sleep(2 * std.time.ns_per_ms);
    try testing.expect(cache.get(1) == null);

    try cache.putWithTTL(2, "value2", 1000); // 1s TTL
    try testing.expect(cache.get(2) != null);
}
