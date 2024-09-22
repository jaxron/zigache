const std = @import("std");
const zigache = @import("../zigache.zig");
const assert = std.debug.assert;

const PolicyOptions = zigache.CacheInitOptions.PolicyOptions;
const CacheTypeOptions = zigache.CacheTypeOptions;
const Allocator = std.mem.Allocator;

/// SIEVE is an simple caching policy designed to balance between recency and
/// frequency of access. It aims to keep both recently accessed and frequently
/// accessed items in the cache, providing a good compromise between LRU and LFU
/// policies.
///
/// More information can be found here:
/// https://cachemon.github.io/SIEVE-website/
pub fn SIEVE(comptime K: type, comptime V: type, comptime cache_opts: CacheTypeOptions) type {
    const thread_safety = cache_opts.thread_safety;
    const ttl_enabled = cache_opts.ttl_enabled;
    const max_load_percentage = cache_opts.max_load_percentage;

    return struct {
        const Data = struct {
            visited: bool,
        };

        const Map = zigache.Map(K, V, Data, ttl_enabled, max_load_percentage);
        const DoublyLinkedList = zigache.DoublyLinkedList(K, V, Data, ttl_enabled);
        const Mutex = if (thread_safety) std.Thread.RwLock else void;
        const Node = Map.Node;

        map: Map,
        list: DoublyLinkedList = .empty,
        mutex: Mutex = if (thread_safety) .{} else {},
        hand: ?*Node = null,

        const Self = @This();

        /// Initialize a new SIEVE cache with the given configuration.
        pub fn init(allocator: std.mem.Allocator, cache_size: u32, pool_size: u32, _: PolicyOptions) !Self {
            return .{ .map = try .init(allocator, cache_size, pool_size) };
        }

        /// Cleans up all resources used by the cache.
        pub fn deinit(self: *Self) void {
            self.list.clear();
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
        pub inline fn count(self: *Self) usize {
            if (thread_safety) self.mutex.lockShared();
            defer if (thread_safety) self.mutex.unlockShared();

            return self.map.count();
        }

        /// Retrieves a value from the cache given its key.
        /// If the key exists and is not expired, it returns the associated value and marks the entry as visited.
        /// If the key doesn't exist or has expired, it returns null.
        pub fn get(self: *Self, key: K, hash_code: u64) ?V {
            if (thread_safety) self.mutex.lock();
            defer if (thread_safety) self.mutex.unlock();

            if (self.map.get(key, hash_code)) |node| {
                if (ttl_enabled and self.map.checkTTL(node, hash_code)) {
                    self.list.remove(node);
                    self.map.pool.release(node);
                    return null;
                }

                // Mark as visited to protect from immediate eviction
                node.data.visited = true;
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
            node.update(key, value, ttl, .{ .visited = false });

            if (!gop.found_existing) {
                if (self.map.count() > self.map.capacity) self.evict();
                // Add new items to the front of the list
                self.list.prepend(node);
            }
        }

        /// Removes a key-value pair from the cache if it exists.
        /// Returns true if it was successfully removed, false otherwise.
        pub fn remove(self: *Self, key: K, hash_code: u64) bool {
            if (thread_safety) self.mutex.lock();
            defer if (thread_safety) self.mutex.unlock();

            return if (self.map.remove(key, hash_code)) |node| {
                // Adjust the hand if it's pointing to the removed node
                if (self.hand == node) self.hand = node.prev;

                self.list.remove(node);
                self.map.pool.release(node);
                return true;
            } else false;
        }

        /// Internal method to handle cache eviction in SIEVE.
        /// Moves the "hand" through the cache, evicting the first unvisited item it encounters.
        fn evict(self: *Self) void {
            // We implement the core eviction logic of SIEVE:
            // 1. It starts from the current hand position, or the tail if hand is null.
            // 2. It continually moves the hand, searching for a non-visited node.
            // 3. When a non-visited node is found, it's evicted immediately.
            // 4. If all nodes are initially visited, it keeps cycling through the list.
            //    This is crucial because each pass resets visited flags, ensuring
            //    an eviction will eventually occur.
            var hand = self.hand orelse self.list.last;
            while (hand) |node| : (hand = node.prev orelse self.list.last) {
                if (!node.data.visited) {
                    // Evict the first non-visited node encountered
                    self.hand = node.prev;

                    assert(self.map.remove(node.key, null) != null);
                    self.list.remove(node);
                    self.map.pool.release(node);
                    return;
                }
                // Reset visited flag, ensuring eventual eviction
                node.data.visited = false;
            }
        }
    };
}

const testing = std.testing;

test "SIEVE - basic insert and get" {
    var cache: zigache.Cache(u32, []const u8, .{}) = try .init(testing.allocator, .{ .cache_size = 2, .policy = .SIEVE });
    defer cache.deinit();

    try cache.put(1, "value1");
    try cache.put(2, "value2");

    try testing.expectEqualStrings("value1", cache.get(1).?);
    try testing.expectEqualStrings("value2", cache.get(2).?);
}

test "SIEVE - overwrite existing key" {
    var cache: zigache.Cache(u32, []const u8, .{}) = try .init(testing.allocator, .{ .cache_size = 2, .policy = .SIEVE });
    defer cache.deinit();

    try cache.put(1, "value1");
    try cache.put(1, "new_value1");

    // Check that the value has been updated
    try testing.expectEqualStrings("new_value1", cache.get(1).?);
}

test "SIEVE - remove key" {
    var cache: zigache.Cache(u32, []const u8, .{}) = try .init(testing.allocator, .{ .cache_size = 1, .policy = .SIEVE });
    defer cache.deinit();

    try cache.put(1, "value1");

    // Remove the key and check that it's no longer present
    try testing.expect(cache.remove(1));
    try testing.expect(cache.get(1) == null);

    // Ensure that a second remove is idempotent
    try testing.expect(!cache.remove(1));
}

test "SIEVE - eviction" {
    var cache: zigache.Cache(u32, []const u8, .{}) = try .init(testing.allocator, .{ .cache_size = 3, .policy = .SIEVE });
    defer cache.deinit();

    try cache.put(1, "value1");
    try cache.put(2, "value2");
    try cache.put(3, "value3");

    // Access key1 and key3 to mark them as visited
    _ = cache.get(1);
    _ = cache.get(3);

    // Insert a new key, which should evict key2 (unvisited)
    try cache.put(4, "value4");

    // Check that key1, key3, and key4 are still in the cache
    try testing.expect(cache.get(1) != null);
    try testing.expect(cache.get(2) == null);
    try testing.expect(cache.get(3) != null);
    try testing.expect(cache.get(4) != null);
}

test "SIEVE - TTL functionality" {
    var cache: zigache.Cache(u32, []const u8, .{ .ttl_enabled = true }) = try .init(testing.allocator, .{ .cache_size = 1, .policy = .SIEVE });
    defer cache.deinit();

    try cache.putWithTTL(1, "value1", 1); // 1ms TTL
    std.time.sleep(2 * std.time.ns_per_ms);
    try testing.expect(cache.get(1) == null);

    try cache.putWithTTL(2, "value2", 1000); // 1s TTL
    try testing.expect(cache.get(2) != null);
}
