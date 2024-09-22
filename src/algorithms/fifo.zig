const std = @import("std");
const zigache = @import("../zigache.zig");
const assert = std.debug.assert;

const PolicyOptions = zigache.CacheInitOptions.PolicyOptions;
const CacheTypeOptions = zigache.CacheTypeOptions;
const Allocator = std.mem.Allocator;

/// FIFO is a simple cache eviction policy. In this approach, new items are added
/// to the back of the queue. When the cache becomes full, the oldest item,
/// which is at the front of the queue, is evicted to make room for the new item.
pub fn FIFO(comptime K: type, comptime V: type, comptime cache_opts: CacheTypeOptions) type {
    const thread_safety = cache_opts.thread_safety;
    const ttl_enabled = cache_opts.ttl_enabled;
    const max_load_percentage = cache_opts.max_load_percentage;

    return struct {
        const Map = zigache.Map(K, V, void, ttl_enabled, max_load_percentage);
        const DoublyLinkedList = zigache.DoublyLinkedList(K, V, void, ttl_enabled);
        const Mutex = if (thread_safety) std.Thread.RwLock else void;

        map: Map,
        list: DoublyLinkedList = .empty,
        mutex: Mutex = if (thread_safety) .{} else {},

        const Self = @This();

        /// Initialize a new FIFO cache with the given configuration.
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
        /// If the key exists and is not expired, it returns the associated value.
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
            node.update(key, value, ttl, {});

            if (!gop.found_existing) {
                if (self.map.count() > self.map.capacity) self.evict();
                // Add new items to the end of the list (FIFO order)
                self.list.append(node);
            }
        }

        /// Removes a key-value pair from the cache if it exists.
        /// Returns true if it was successfully removed, false otherwise.
        pub fn remove(self: *Self, key: K, hash_code: u64) bool {
            if (thread_safety) self.mutex.lock();
            defer if (thread_safety) self.mutex.unlock();

            return if (self.map.remove(key, hash_code)) |node| {
                self.list.remove(node);
                self.map.pool.release(node);
                return true;
            } else false;
        }

        /// Internal method to handle cache eviction in FIFO.
        /// Removes the oldest item (at the front of the queue) when the cache is full.
        fn evict(self: *Self) void {
            if (self.list.first) |head| {
                // FIFO eviction: remove the oldest item (first in the list)
                self.list.remove(head);

                assert(self.map.remove(head.key, null) != null);
                self.map.pool.release(head);
            }
        }
    };
}

const testing = std.testing;

test "FIFO - basic insert and get" {
    var cache: zigache.Cache(u32, []const u8, .{}) = try .init(testing.allocator, .{ .cache_size = 2, .policy = .FIFO });
    defer cache.deinit();

    try cache.put(1, "value1");
    try cache.put(2, "value2");

    try testing.expectEqualStrings("value1", cache.get(1).?);
    try testing.expectEqualStrings("value2", cache.get(2).?);
}

test "FIFO - overwrite existing key" {
    var cache: zigache.Cache(u32, []const u8, .{}) = try .init(testing.allocator, .{ .cache_size = 2, .policy = .FIFO });
    defer cache.deinit();

    try cache.put(1, "value1");
    try cache.put(1, "new_value1");

    // Check that the value has been updated
    try testing.expectEqualStrings("new_value1", cache.get(1).?);
}

test "FIFO - remove key" {
    var cache: zigache.Cache(u32, []const u8, .{}) = try .init(testing.allocator, .{ .cache_size = 1, .policy = .FIFO });
    defer cache.deinit();

    try cache.put(1, "value1");

    // Remove the key and check that it's no longer present
    try testing.expect(cache.remove(1));
    try testing.expect(cache.get(1) == null);

    // Ensure that a second remove is idempotent
    try testing.expect(!cache.remove(1));
}

test "FIFO - eviction" {
    var cache: zigache.Cache(u32, []const u8, .{}) = try .init(testing.allocator, .{ .cache_size = 3, .policy = .FIFO });
    defer cache.deinit();

    try cache.put(1, "value1");
    try cache.put(2, "value2");
    try cache.put(3, "value3");
    try cache.put(4, "value4");
    try cache.put(5, "value5");

    // Check that the oldest entries (1 and 2) have been evicted
    try testing.expect(cache.get(1) == null);
    try testing.expect(cache.get(2) == null);

    // Check that the newer entries (3, 4, and 5) are still present
    try testing.expectEqualStrings("value3", cache.get(3).?);
    try testing.expectEqualStrings("value4", cache.get(4).?);
    try testing.expectEqualStrings("value5", cache.get(5).?);
}

test "FIFO - TTL functionality" {
    var cache: zigache.Cache(u32, []const u8, .{ .ttl_enabled = true }) = try .init(testing.allocator, .{ .cache_size = 1, .policy = .FIFO });
    defer cache.deinit();

    try cache.putWithTTL(1, "value1", 1); // 1ms TTL
    std.time.sleep(2 * std.time.ns_per_ms);
    try testing.expect(cache.get(1) == null);

    try cache.putWithTTL(2, "value2", 1000); // 1s TTL
    try testing.expect(cache.get(2) != null);
}
