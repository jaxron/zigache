const std = @import("std");
const utils = @import("../utils/utils.zig");
const assert = std.debug.assert;

const DoublyLinkedList = @import("../structures/dbl.zig").DoublyLinkedList;
const Map = @import("../structures/map.zig").Map;
const Allocator = std.mem.Allocator;

/// LRU is a cache eviction policy based on usage recency. It keeps track of
/// what items are used and when. When the cache is full, the item that hasn't
/// been used for the longest time is evicted. This policy is based on the idea
/// that items that have been used recently are likely to be used again soon.
pub fn LRU(comptime K: type, comptime V: type) type {
    return struct {
        const Node = @import("../structures/node.zig").Node(K, V, void);

        map: Map(Node),
        list: DoublyLinkedList(Node) = .{},
        mutex: std.Thread.RwLock = .{},

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, total_size: u32, base_size: u32) !Self {
            return .{ .map = try Map(Node).init(allocator, total_size, base_size) };
        }

        pub fn deinit(self: *Self) void {
            self.list.clear();
            self.map.deinit();
        }

        pub fn contains(self: *Self, key: K, hash_code: u64) bool {
            self.mutex.lockShared();
            defer self.mutex.unlockShared();

            return self.map.contains(key, hash_code);
        }

        pub fn count(self: *Self) usize {
            self.mutex.lockShared();
            defer self.mutex.unlockShared();

            return self.map.count();
        }

        pub fn get(self: *Self, key: K, hash_code: u64) ?V {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.map.get(key, hash_code)) |node| {
                if (self.map.checkTTL(node)) {
                    self.list.remove(node);
                    return null;
                }

                // Move the accessed node to the back of the list (most recently used)
                self.list.moveToBack(node);
                return node.value;
            }
            return null;
        }

        pub fn set(self: *Self, key: K, value: V, ttl: ?u64, hash_code: u64) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const node, const found_existing = try self.map.set(key, hash_code);
            node.* = .{
                .key = key,
                .value = value,
                .next = node.next,
                .prev = node.prev,
                .expiry = utils.getExpiry(ttl),
                .data = {},
            };

            if (found_existing) {
                // Move updated node to the back (most recently used)
                self.list.moveToBack(node);
            } else {
                if (self.map.count() > self.map.capacity) self.evict();
                // Add new node to the back of the list (most recently used)
                self.list.append(node);
            }
        }

        pub fn remove(self: *Self, key: K, hash_code: u64) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            return if (self.map.remove(key, hash_code)) |node| {
                self.list.remove(node);
                self.map.pool.release(node);
                return true;
            } else false;
        }

        fn evict(self: *Self) void {
            if (self.list.first) |head| {
                // Remove the least recently used item (at the front of the list)
                assert(self.map.remove(head.key, null) != null);
                self.list.remove(head);
                self.map.pool.release(head);
            }
        }
    };
}

const testing = std.testing;

fn initTestCache(total_size: u32) !utils.TestCache(LRU(u32, []const u8)) {
    return try utils.TestCache(LRU(u32, []const u8)).init(
        testing.allocator,
        total_size,
    );
}

test "LRU - basic insert and get" {
    var cache = try initTestCache(2);
    defer cache.deinit();

    try cache.set(1, "value1");
    try cache.set(2, "value2");

    try testing.expectEqualStrings("value1", cache.get(1).?);
    try testing.expectEqualStrings("value2", cache.get(2).?);
    try testing.expect(cache.get(3) == null);
}

test "LRU - overwrite existing key" {
    var cache = try initTestCache(2);
    defer cache.deinit();

    try cache.set(1, "value1");
    try cache.set(1, "new_value1");

    // Check that the value has been updated
    try testing.expectEqualStrings("new_value1", cache.get(1).?);
}

test "LRU - remove key" {
    var cache = try initTestCache(1);
    defer cache.deinit();

    try cache.set(1, "value1");

    // Remove the key and check that it's no longer present
    try testing.expect(cache.remove(1));
    try testing.expect(cache.get(1) == null);

    // Ensure that a second remove is idempotent
    try testing.expect(!cache.remove(1));
}

test "LRU - eviction" {
    var cache = try initTestCache(4);
    defer cache.deinit();

    try cache.set(1, "value1");
    try cache.set(2, "value2");
    try cache.set(3, "value3");
    try cache.set(4, "value4");

    // Access key1 and key3 to make it the most recently used
    _ = cache.get(1);
    _ = cache.get(3);

    // Insert a new key, which should evict key2 (least recently used)
    try cache.set(5, "value5");

    // Insert another key, which should evict key4 (least recently used)
    try cache.set(6, "value6");

    // Check that key1, key3, and key4 are still in the cache, but key2 is evicted
    try testing.expect(cache.get(1) != null);
    try testing.expect(cache.get(2) == null);
    try testing.expect(cache.get(3) != null);
    try testing.expect(cache.get(4) == null);
    try testing.expect(cache.get(5) != null);
}

test "LRU - TTL functionality" {
    var cache = try initTestCache(1);
    defer cache.deinit();

    try cache.setTTL(1, "value1", 1); // 1ms TTL
    std.time.sleep(2 * std.time.ns_per_ms);
    try testing.expect(cache.get(1) == null);

    try cache.setTTL(2, "value2", 1000); // 1s TTL
    try testing.expect(cache.get(2) != null);
}
