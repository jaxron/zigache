const std = @import("std");
const utils = @import("../utils/utils.zig");
const assert = std.debug.assert;

const DoublyLinkedList = @import("../structures/dbl.zig").DoublyLinkedList;
const Map = @import("../structures/map.zig").Map;
const Allocator = std.mem.Allocator;

/// SIEVE is an simple caching policy designed to balance between recency and
/// frequency of access. It aims to keep both recently accessed and frequently
/// accessed items in the cache, providing a good compromise between LRU and LFU
/// policies.
///
/// More information can be found here:
/// https://cachemon.github.io/SIEVE-website/
pub fn SIEVE(comptime K: type, comptime V: type) type {
    return struct {
        const Node = @import("../structures/node.zig").Node(K, V, struct {
            visited: bool,
        });

        map: Map(K, Node),
        list: DoublyLinkedList(Node) = .{},
        mutex: std.Thread.RwLock = .{},
        hand: ?*Node = null,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, total_size: u32, base_size: u32) !Self {
            return .{ .map = try Map(K, Node).init(allocator, total_size, base_size) };
        }

        pub fn deinit(self: *Self) void {
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

                // Mark as visited to protect from immediate eviction
                node.data.visited = true;
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
                .next = if (found_existing) node.next else null,
                .prev = if (found_existing) node.prev else null,
                .expiry = utils.getExpiry(ttl),
                .data = .{ .visited = false },
            };

            if (!found_existing) {
                if (self.map.count() > self.map.capacity) self.evict();
                // Add new items to the front of the list
                self.list.prepend(node);
            }
        }

        pub fn remove(self: *Self, key: K, hash_code: u64) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            return if (self.map.remove(key, hash_code)) |node| {
                // Adjust the hand if it's pointing to the removed node
                if (self.hand == node) self.hand = node.prev;

                self.list.remove(node);
                self.map.pool.release(node);
                return true;
            } else false;
        }

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

fn initTestCache(total_size: u32) !utils.TestCache(SIEVE(u32, []const u8)) {
    return try utils.TestCache(SIEVE(u32, []const u8)).init(testing.allocator, total_size);
}

test "SIEVE - basic insert and get" {
    var cache = try initTestCache(2);
    defer cache.deinit();

    try cache.set(1, "value1");
    try cache.set(2, "value2");

    try testing.expectEqualStrings("value1", cache.get(1).?);
    try testing.expectEqualStrings("value2", cache.get(2).?);
}

test "SIEVE - overwrite existing key" {
    var cache = try initTestCache(2);
    defer cache.deinit();

    try cache.set(1, "value1");
    try cache.set(1, "new_value1");

    // Check that the value has been updated
    try testing.expectEqualStrings("new_value1", cache.get(1).?);
}

test "SIEVE - remove key" {
    var cache = try initTestCache(1);
    defer cache.deinit();

    try cache.set(1, "value1");

    // Remove the key and check that it's no longer present
    try testing.expect(cache.remove(1));
    try testing.expect(cache.get(1) == null);

    // Ensure that a second remove is idempotent
    try testing.expect(!cache.remove(1));
}

test "SIEVE - eviction" {
    var cache = try initTestCache(3);
    defer cache.deinit();

    try cache.set(1, "value1");
    try cache.set(2, "value2");
    try cache.set(3, "value3");

    // Access key1 and key3 to mark them as visited
    _ = cache.get(1);
    _ = cache.get(3);

    // Insert a new key, which should evict key2 (unvisited)
    try cache.set(4, "value4");

    // Check that key1, key3, and key4 are still in the cache
    try testing.expect(cache.get(1) != null);
    try testing.expect(cache.get(2) == null);
    try testing.expect(cache.get(3) != null);
    try testing.expect(cache.get(4) != null);
}

test "SIEVE - TTL functionality" {
    var cache = try initTestCache(1);
    defer cache.deinit();

    try cache.setTTL(1, "value1", 1); // 1ms TTL
    std.time.sleep(2 * std.time.ns_per_ms);
    try testing.expect(cache.get(1) == null);

    try cache.setTTL(2, "value2", 1000); // 1s TTL
    try testing.expect(cache.get(2) != null);
}
