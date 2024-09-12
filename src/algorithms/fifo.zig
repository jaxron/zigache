const std = @import("std");
const utils = @import("../utils/utils.zig");
const assert = std.debug.assert;

const DoublyLinkedList = @import("../structures/dbl.zig").DoublyLinkedList;
const Map = @import("../structures/map.zig").Map;
const Allocator = std.mem.Allocator;

/// FIFO is a simple cache eviction policy. In this approach, new items are added
/// to the back of the queue. When the cache becomes full, the oldest item,
/// which is at the front of the queue, is evicted to make room for the new item.
pub fn FIFO(comptime K: type, comptime V: type, comptime thread_safe: bool) type {
    return struct {
        const Node = @import("../structures/node.zig").Node(K, V, void);
        const Mutex = if (thread_safe) std.Thread.RwLock else void;

        map: Map(Node),
        list: DoublyLinkedList(Node) = .{},
        mutex: Mutex = if (thread_safe) .{} else {},

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, total_size: u32, base_size: u32) !Self {
            return .{ .map = try Map(Node).init(allocator, total_size, base_size) };
        }

        pub fn deinit(self: *Self) void {
            self.list.clear();
            self.map.deinit();
        }

        pub fn contains(self: *Self, key: K, hash_code: u64) bool {
            if (thread_safe) self.mutex.lockShared();
            defer if (thread_safe) self.mutex.unlockShared();

            return self.map.contains(key, hash_code);
        }

        pub fn count(self: *Self) usize {
            if (thread_safe) self.mutex.lockShared();
            defer if (thread_safe) self.mutex.unlockShared();

            return self.map.count();
        }

        pub fn get(self: *Self, key: K, hash_code: u64) ?V {
            if (thread_safe) self.mutex.lock();
            defer if (thread_safe) self.mutex.unlock();

            if (self.map.get(key, hash_code)) |node| {
                if (self.map.checkTTL(node)) {
                    self.list.remove(node);
                    return null;
                }
                return node.value;
            }
            return null;
        }

        pub fn set(self: *Self, key: K, value: V, ttl: ?u64, hash_code: u64) !void {
            if (thread_safe) self.mutex.lock();
            defer if (thread_safe) self.mutex.unlock();

            const node, const found_existing = try self.map.set(key, hash_code);
            node.* = .{
                .key = key,
                .value = value,
                .next = node.next,
                .prev = node.prev,
                .expiry = utils.getExpiry(ttl),
                .data = {},
            };

            if (!found_existing) {
                if (self.map.count() > self.map.capacity) self.evict();
                // Add new items to the end of the list (FIFO order)
                self.list.append(node);
            }
        }

        pub fn remove(self: *Self, key: K, hash_code: u64) bool {
            if (thread_safe) self.mutex.lock();
            defer if (thread_safe) self.mutex.unlock();

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

const TestCache = utils.TestCache(FIFO(u32, []const u8, false));

test "FIFO - basic insert and get" {
    var cache = try TestCache.init(testing.allocator, 2);
    defer cache.deinit();

    try cache.set(1, "value1");
    try cache.set(2, "value2");

    try testing.expectEqualStrings("value1", cache.get(1).?);
    try testing.expectEqualStrings("value2", cache.get(2).?);
}

test "FIFO - overwrite existing key" {
    var cache = try TestCache.init(testing.allocator, 2);
    defer cache.deinit();

    try cache.set(1, "value1");
    try cache.set(1, "new_value1");

    // Check that the value has been updated
    try testing.expectEqualStrings("new_value1", cache.get(1).?);
}

test "FIFO - remove key" {
    var cache = try TestCache.init(testing.allocator, 1);
    defer cache.deinit();

    try cache.set(1, "value1");

    // Remove the key and check that it's no longer present
    try testing.expect(cache.remove(1));
    try testing.expect(cache.get(1) == null);

    // Ensure that a second remove is idempotent
    try testing.expect(!cache.remove(1));
}

test "FIFO - eviction" {
    var cache = try TestCache.init(testing.allocator, 3);
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
    var cache = try TestCache.init(testing.allocator, 1);
    defer cache.deinit();

    try cache.setTTL(1, "value1", 1); // 1ms TTL
    std.time.sleep(2 * std.time.ns_per_ms);
    try testing.expect(cache.get(1) == null);

    try cache.setTTL(2, "value2", 1000); // 1s TTL
    try testing.expect(cache.get(2) != null);
}
