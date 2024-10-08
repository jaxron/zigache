const std = @import("std");
const zigache = @import("../zigache.zig");
const assert = std.debug.assert;

const PolicyOptions = zigache.CacheInitOptions.PolicyOptions;
const CacheTypeOptions = zigache.CacheTypeOptions;
const CountMinSketch = zigache.CountMinSketch;
const Allocator = std.mem.Allocator;

/// W-TinyLFU is a hybrid cache eviction policy that combines a small window
/// cache with a larger main cache. It uses a frequency sketch to estimate item
/// popularity efficiently. This policy aims to capture both short-term and
/// long-term access patterns, providing high hit ratios across various workloads.
///
/// More information can be found here:
/// https://arxiv.org/pdf/1512.00727
pub fn TinyLFU(comptime K: type, comptime V: type, comptime cache_opts: CacheTypeOptions) type {
    const thread_safety = cache_opts.thread_safety;
    const ttl_enabled = cache_opts.ttl_enabled;
    const max_load_percentage = cache_opts.max_load_percentage;

    return struct {
        const CacheRegion = enum { Window, Probationary, Protected };

        const Data = struct {
            // Indicates which part of the cache this node belongs to:
            // Window: Recent entries, not yet in main cache
            // Probationary: Less frequently accessed items in main cache
            // Protected: Frequently accessed items in main cache
            region: CacheRegion,
        };

        const Map = zigache.Map(K, V, Data, ttl_enabled, max_load_percentage);
        const DoublyLinkedList = zigache.DoublyLinkedList(K, V, Data, ttl_enabled);
        const Mutex = if (thread_safety) std.Thread.RwLock else void;
        const Node = Map.Node;

        map: Map,
        window: DoublyLinkedList = .empty,
        probationary: DoublyLinkedList = .empty,
        protected: DoublyLinkedList = .empty,
        mutex: Mutex = if (thread_safety) .{} else {},

        sketch: CountMinSketch,

        window_size: usize,
        probationary_size: usize,
        protected_size: usize,

        const Self = @This();

        /// Initialize a new TinyLFU cache with the given configuration.
        pub fn init(allocator: std.mem.Allocator, cache_size: u32, pool_size: u32, opts: PolicyOptions) !Self {
            const window_size = @max(1, cache_size * opts.TinyLFU.window_size_percent / 100); // 1% window cache
            const main_size = @max(2, cache_size - window_size);
            const protected_size = @max(1, main_size * 8 / 10); // 80% of main cache
            const probationary_size = main_size - protected_size; // 20% of main cache

            const reset_threshold = @as(u32, @intFromFloat(@as(f32, @floatFromInt(cache_size)) * opts.TinyLFU.reset_threshold_multiplier));
            return .{
                .map = try .init(allocator, cache_size, pool_size),
                .sketch = try .init(allocator, cache_size, opts.TinyLFU.cms_depth, reset_threshold),
                .window_size = window_size,
                .probationary_size = probationary_size,
                .protected_size = protected_size,
            };
        }

        /// Cleans up all resources used by the cache.
        pub fn deinit(self: *Self) void {
            self.sketch.deinit();
            self.window.clear();
            self.probationary.clear();
            self.protected.clear();
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
        /// If the key exists and is not expired, it returns the associated value and records the entry's access.
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

                // Record access and promote/update node to maintain recency order
                self.sketch.increment(hash_code);
                self.updateOnHit(node);
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

            const gop = try self.map.getOrPut(key, hash_code);
            const node = gop.node;
            node.update(key, value, ttl, .{
                // New items always start in the window region
                .region = if (gop.found_existing) node.data.region else .Window,
            });

            self.sketch.increment(hash_code);
            if (gop.found_existing) {
                self.updateOnHit(node);
            } else {
                self.insertNew(node);
            }
        }

        /// Removes a key-value pair from the cache if it exists.
        /// Returns true if it was successfully removed, false otherwise.
        pub fn remove(self: *Self, key: K, hash_code: u64) bool {
            if (thread_safety) self.mutex.lock();
            defer if (thread_safety) self.mutex.unlock();

            if (self.map.remove(key, hash_code)) |node| {
                // Remove the node from the respective list as well
                self.removeFromList(node);
                self.map.pool.release(node);
                return true;
            }
            return false;
        }

        /// Removes the node from its current list (Window, Probationary, or Protected) based on its region.
        fn removeFromList(self: *Self, node: *Node) void {
            switch (node.data.region) {
                .Window => self.window.remove(node),
                .Probationary => self.probationary.remove(node),
                .Protected => self.protected.remove(node),
            }
        }

        /// Updates the position of a node depending on the its current region.
        fn updateOnHit(self: *Self, node: *Node) void {
            switch (node.data.region) {
                // In window cache, just move to back (most recently used)
                .Window => self.window.moveToBack(node),
                .Probationary => {
                    // Move from probationary to protected, and potentially
                    // demoting a protected item if the cache is full
                    self.probationary.remove(node);
                    if (self.protected.len >= self.protected_size) {
                        const demoted = self.protected.popFirst().?;
                        demoted.data.region = .Probationary;
                        self.probationary.append(demoted);
                    }
                    node.data.region = .Protected;
                    self.protected.append(node);
                },
                // In protected cache, just move to back (most recently used)
                .Protected => self.protected.moveToBack(node),
            }
        }

        /// Inserts a new node into the cache. If the window cache is full,
        /// it triggers the admission process to the main cache.
        fn insertNew(self: *Self, node: *Node) void {
            if (self.window.len >= self.window_size) {
                const victim = self.window.popFirst().?;
                self.tryAdmitToMain(victim);
            }
            self.window.append(node);
        }

        /// Attempts to admit a candidate from the window cache to the main cache.
        /// Uses the frequency sketch to decide whether to admit the candidate or evict it.
        fn tryAdmitToMain(self: *Self, candidate: *Node) void {
            if (self.probationary.len >= self.probationary_size) {
                const victim = self.probationary.first.?;
                // Use TinyLFU sketch to decide whether to admit the candidate
                const victim_hash = zigache.hash(K, victim.key);
                const candidate_hash = zigache.hash(K, candidate.key);
                if (self.sketch.estimate(victim_hash) > self.sketch.estimate(candidate_hash)) {
                    assert(self.map.remove(candidate.key, candidate_hash) != null);
                    self.map.pool.release(candidate);
                    return;
                }

                assert(self.map.remove(victim.key, null) != null);
                self.probationary.remove(victim);
                self.map.pool.release(victim);
            }

            // Add the window node to probationary segment
            candidate.data.region = .Probationary;
            self.probationary.append(candidate);
        }
    };
}

const testing = std.testing;

test "TinyLFU - basic insert and get" {
    var cache: zigache.Cache(u32, []const u8, .{}) = try .init(testing.allocator, .{ .cache_size = 2, .policy = .{ .TinyLFU = .{} } });
    defer cache.deinit();

    try cache.put(1, "value1");
    try cache.put(2, "value2");

    try testing.expectEqualStrings("value1", cache.get(1).?);
    try testing.expectEqualStrings("value2", cache.get(2).?);
}

test "TinyLFU - overwrite existing key" {
    var cache: zigache.Cache(u32, []const u8, .{}) = try .init(testing.allocator, .{ .cache_size = 2, .policy = .{ .TinyLFU = .{} } });
    defer cache.deinit();

    try cache.put(1, "value1");
    try cache.put(1, "new_value1");

    // Check that the value has been updated
    try testing.expectEqualStrings("new_value1", cache.get(1).?);
}

test "TinyLFU - remove key" {
    var cache: zigache.Cache(u32, []const u8, .{}) = try .init(testing.allocator, .{ .cache_size = 1, .policy = .{ .TinyLFU = .{} } });
    defer cache.deinit();

    try cache.put(1, "value1");

    // Remove the key and check that it's no longer present
    try testing.expect(cache.remove(1));
    try testing.expect(cache.get(1) == null);

    // Ensure that a second remove is idempotent
    try testing.expect(!cache.remove(1));
}

test "TinyLFU - eviction and promotion" {
    var cache: zigache.Cache(u32, []const u8, .{}) = try .init(testing.allocator, .{ .cache_size = 5, .policy = .{ .TinyLFU = .{} } }); // Total size: 5 (window: 1, probationary: 1, protected: 3)
    defer cache.deinit();

    // Fill the cache
    try cache.put(1, "value1"); // 1 moves to window
    try cache.put(2, "value2"); // 2 moves to window, 1 moves to probationary
    _ = cache.get(1); // 1 moves to protected
    try cache.put(3, "value3"); // 3 moves to window, 2 moves to probationary
    _ = cache.get(2); // 2 moves to protected
    try cache.put(4, "value4"); // 4 moves to window, 3 moves to probationary
    _ = cache.get(3); // 3 moves to protected
    try cache.put(5, "value5"); // 5 moves to window, 4 moves to probationary

    // Access 4 multiple times to increase its frequency
    _ = cache.get(4);
    _ = cache.get(4);
    _ = cache.get(4);

    // Insert a new key, which should evict the least frequently used key
    try cache.put(6, "value6"); // 6 moves to window, 5 is compared with 4, 4 moves to protected

    // We expect key 5 to be evicted due to lower frequency
    try testing.expect(cache.get(1) != null);
    try testing.expect(cache.get(2) != null);
    try testing.expect(cache.get(3) != null);
    try testing.expect(cache.get(4) != null);
    try testing.expect(cache.get(5) == null);
    try testing.expect(cache.get(6) != null);
}

test "TinyLFU - TTL functionality" {
    var cache: zigache.Cache(u32, []const u8, .{ .ttl_enabled = true }) = try .init(testing.allocator, .{ .cache_size = 1, .policy = .{ .TinyLFU = .{} } });
    defer cache.deinit();

    try cache.putWithTTL(1, "value1", 1); // 1ms TTL
    std.time.sleep(2 * std.time.ns_per_ms);
    try testing.expect(cache.get(1) == null);

    try cache.putWithTTL(2, "value2", 1000); // 1s TTL
    try testing.expect(cache.get(2) != null);
}
