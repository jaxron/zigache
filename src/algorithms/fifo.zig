const std = @import("std");
const zigache = @import("../zigache.zig");
const assert = std.debug.assert;

const Config = zigache.Config;
const Allocator = std.mem.Allocator;

/// FIFO is a simple cache eviction policy. In this approach, new items are added
/// to the back of the queue. When the cache becomes full, the oldest item,
/// which is at the front of the queue, is evicted to make room for the new item.
pub fn FIFO(comptime K: type, comptime V: type, comptime config: Config) type {
    const thread_safety = config.thread_safety;
    const ttl_enabled = config.ttl_enabled;
    return struct {
        const Map = zigache.Map(K, V, void, ttl_enabled);
        const DoublyLinkedList = zigache.DoublyLinkedList(K, V, void, ttl_enabled);
        const Mutex = if (thread_safety) std.Thread.RwLock else void;

        map: Map,
        list: DoublyLinkedList = .empty,
        mutex: Mutex = if (thread_safety) .{} else {},

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, cache_size: u32, pool_size: u32) !Self {
            return .{ .map = try .init(allocator, cache_size, pool_size) };
        }

        pub fn deinit(self: *Self) void {
            self.list.clear();
            self.map.deinit();
        }

        pub inline fn contains(self: *Self, key: K, hash_code: u64) bool {
            if (thread_safety) self.mutex.lockShared();
            defer if (thread_safety) self.mutex.unlockShared();

            return self.map.contains(key, hash_code);
        }

        pub inline fn count(self: *Self) usize {
            if (thread_safety) self.mutex.lockShared();
            defer if (thread_safety) self.mutex.unlockShared();

            return self.map.count();
        }

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

        pub fn set(self: *Self, key: K, value: V, ttl: ?u64, hash_code: u64) !void {
            if (thread_safety) self.mutex.lock();
            defer if (thread_safety) self.mutex.unlock();

            const node, const found_existing = try self.map.set(key, hash_code);
            node.update(key, value, ttl, {});

            if (!found_existing) {
                if (self.map.count() > self.map.capacity) self.evict();
                // Add new items to the end of the list (FIFO order)
                self.list.append(node);
            }
        }

        pub fn remove(self: *Self, key: K, hash_code: u64) bool {
            if (thread_safety) self.mutex.lock();
            defer if (thread_safety) self.mutex.unlock();

            return if (self.map.remove(key, hash_code)) |node| {
                self.list.remove(node);
                self.map.pool.release(node);
                return true;
            } else false;
        }

        fn evict(self: *Self) void {
            if (self.list.first) |head| {
                // FIFO eviction: remove the oldest item (first in the list)
                assert(self.map.remove(head.key, null) != null);
                self.list.remove(head);
                self.map.pool.release(head);
            }
        }
    };
}

const testing = std.testing;

test "FIFO - basic insert and get" {
    var cache: zigache.Cache(u32, []const u8, .{ .cache_size = 2, .policy = .FIFO }) = try .init(testing.allocator);
    defer cache.deinit();

    try cache.set(1, "value1");
    try cache.set(2, "value2");

    try testing.expectEqualStrings("value1", cache.get(1).?);
    try testing.expectEqualStrings("value2", cache.get(2).?);
}

test "FIFO - overwrite existing key" {
    var cache: zigache.Cache(u32, []const u8, .{ .cache_size = 2, .policy = .FIFO }) = try .init(testing.allocator);
    defer cache.deinit();

    try cache.set(1, "value1");
    try cache.set(1, "new_value1");

    // Check that the value has been updated
    try testing.expectEqualStrings("new_value1", cache.get(1).?);
}

test "FIFO - remove key" {
    var cache: zigache.Cache(u32, []const u8, .{ .cache_size = 1, .policy = .FIFO }) = try .init(testing.allocator);
    defer cache.deinit();

    try cache.set(1, "value1");

    // Remove the key and check that it's no longer present
    try testing.expect(cache.remove(1));
    try testing.expect(cache.get(1) == null);

    // Ensure that a second remove is idempotent
    try testing.expect(!cache.remove(1));
}

test "FIFO - eviction" {
    var cache: zigache.Cache(u32, []const u8, .{ .cache_size = 3, .policy = .FIFO }) = try .init(testing.allocator);
    defer cache.deinit();

    try cache.set(1, "value1");
    try cache.set(2, "value2");
    try cache.set(3, "value3");
    try cache.set(4, "value4");
    try cache.set(5, "value5");

    // Check that the oldest entries (1 and 2) have been evicted
    try testing.expect(cache.get(1) == null);
    try testing.expect(cache.get(2) == null);

    // Check that the newer entries (3, 4, and 5) are still present
    try testing.expectEqualStrings("value3", cache.get(3).?);
    try testing.expectEqualStrings("value4", cache.get(4).?);
    try testing.expectEqualStrings("value5", cache.get(5).?);
}

test "FIFO - TTL functionality" {
    var cache: zigache.Cache(u32, []const u8, .{ .cache_size = 1, .ttl_enabled = true, .policy = .FIFO }) = try .init(testing.allocator);
    defer cache.deinit();

    try cache.setWithTTL(1, "value1", 1); // 1ms TTL
    std.time.sleep(2 * std.time.ns_per_ms);
    try testing.expect(cache.get(1) == null);

    try cache.setWithTTL(2, "value2", 1000); // 1s TTL
    try testing.expect(cache.get(2) != null);
}
