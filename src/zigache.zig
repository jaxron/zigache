const std = @import("std");

pub const FIFO = @import("algorithms/fifo.zig").FIFO;
pub const LRU = @import("algorithms/lru.zig").LRU;
pub const TinyLFU = @import("algorithms/tinylfu.zig").TinyLFU;
pub const SIEVE = @import("algorithms/sieve.zig").SIEVE;
pub const S3FIFO = @import("algorithms/s3fifo.zig").S3FIFO;

pub const CountMinSketch = @import("structures/cms.zig").CountMinSketch;
pub const DoublyLinkedList = @import("structures/dbl.zig").DoublyLinkedList;
pub const Map = @import("structures/map.zig").Map;
pub const Node = @import("structures/node.zig").Node;
pub const Pool = @import("structures/pool.zig").Pool;

pub const utils = @import("utils/utils.zig");

pub fn main() !void {}

pub const Config = struct {
    // The maximum number of items the cache can hold before it starts evicting.
    cache_size: u32,

    /// The initial number of nodes to pre-allocate for the entire cache.
    ///
    /// Pre-allocating memory for cache nodes can improve performance by
    /// reducing the number of allocations needed during cache operations.
    /// However, if `cache_size` is a large number, you are highly recommended
    /// to configure this as a high `pool_size` would waste memory if the cache
    /// doesn't fill up.
    ///
    /// If not specified, it defaults to the `cache_size`.
    pool_size: ?u32 = null,

    /// The number of shards to divide the cache into.
    ///
    /// Sharding can reduce contention in concurrent scenarios by dividing
    /// the cache into multiple independent segments, each with its own lock.
    /// This allows for parallel operations on different shards, improving
    /// performance in multi-threaded environments. It also adds overhead.
    ///
    /// This MUST be a power of 2 (e.g., 2, 4, 8, 16, 32, etc.). If not, it will
    /// automatically be rounded up to the nearest power of 2.
    ///
    /// It's recommended to benchmark your specific use case with different
    /// shard counts to find the optimal configuration.
    shard_count: u16 = 1,

    /// Determines whether the cache should be thread-safe using mutexes.
    ///
    /// Using mutexes provides strong consistency guarantees but may introduce
    /// some performance overhead due to lock contention, especially under high
    /// concurrency.
    ///
    /// This works in conjunction with `shard_count` as each shard gets its own
    /// mutex, rather than having a single global lock, which reduces contention
    /// as operations on different shards can proceed in parallel without waiting
    /// for each other.
    ///
    /// Default is true for safety, but can be set to false if you're certain
    /// the cache will only be accessed from a single thread or if you're
    /// managing concurrency yourself.
    thread_safety: bool = true,

    /// Determines whether the Time-To-Live (TTL) functionality is enabled.
    ///
    /// When enabled, TTL is checked only when an item is accessed via the `get`
    /// operation and removed if it has expired. This is crucial for applications
    /// that require the  invalidation of stale entries.
    ///
    /// Disabling this option when TTL is not used will improve performance by
    /// removing unnecessary expiration checks during cache operations.
    ///
    /// Default is false for performance, but can be set to true you use TTL.
    /// A compile-time error will be raised if TTL is disabled but TTL operations
    /// are attempted in the cache.
    ttl_enabled: bool = false,

    /// The eviction policy to use for managing cache entries.
    ///
    /// This field determines the algorithm used to decide which items to remove
    /// when the cache reaches its capacity. Different policies have different
    /// trade-offs in terms of performance, memory usage, and cache hit rate.
    ///
    /// Choose the policy that best fits your workload characteristics and performance requirements.
    policy: EvictionPolicy,

    /// EvictionPolicy determines the algorithm used for cache management.
    pub const EvictionPolicy = enum {
        FIFO,
        LRU,
        TinyLFU,
        SIEVE,
        S3FIFO,
    };
};

/// Creates a sharded cache for key-value pairs.
/// This function returns a cache type specialized for the given key and value types.
pub fn Cache(comptime K: type, comptime V: type, comptime config: Config) type {
    return struct {
        /// A unified interface for different cache implementations.
        pub const CacheImpl = union(Config.EvictionPolicy) {
            // NOTE: While it's better to implement interface-like behavior using
            // vtables (structs with function pointers), it can introduce complexity
            // or runtime overhead. I have chosen the union approach here as I do not
            // wish to complicate the structure of the code and I am willing to accept
            // the trade-offs for now. I may choose revisit this decision in the future
            // when accepted proposals like pinned structs are implemented in Zig as well
            // as certain safety features.

            const _FIFO = FIFO(K, V, config.thread_safety, config.ttl_enabled);
            const _LRU = LRU(K, V, config.thread_safety, config.ttl_enabled);
            const _TinyLFU = TinyLFU(K, V, config.thread_safety, config.ttl_enabled);
            const _SIEVE = SIEVE(K, V, config.thread_safety, config.ttl_enabled);
            const _S3FIFO = S3FIFO(K, V, config.thread_safety, config.ttl_enabled);

            FIFO: _FIFO,
            LRU: _LRU,
            TinyLFU: _TinyLFU,
            SIEVE: _SIEVE,
            S3FIFO: _S3FIFO,

            pub fn init(allocator: std.mem.Allocator, cache_size: u32, pool_size: u32, policy: Config.EvictionPolicy) !CacheImpl {
                return switch (policy) {
                    .FIFO => .{ .FIFO = try _FIFO.init(allocator, cache_size, pool_size) },
                    .LRU => .{ .LRU = try _LRU.init(allocator, cache_size, pool_size) },
                    .TinyLFU => .{ .TinyLFU = try _TinyLFU.init(allocator, cache_size, pool_size) },
                    .SIEVE => .{ .SIEVE = try _SIEVE.init(allocator, cache_size, pool_size) },
                    .S3FIFO => .{ .S3FIFO = try _S3FIFO.init(allocator, cache_size, pool_size) },
                };
            }

            pub fn deinit(self: *CacheImpl) void {
                switch (self.*) {
                    inline else => |*case| case.deinit(),
                }
            }

            pub fn set(self: *CacheImpl, key: K, value: V, ttl: ?u64, hash_code: u64) !void {
                switch (self.*) {
                    inline else => |*case| try case.set(key, value, ttl, hash_code),
                }
            }

            pub fn get(self: *CacheImpl, key: K, hash_code: u64) ?V {
                return switch (self.*) {
                    inline else => |*case| case.get(key, hash_code),
                };
            }

            pub fn remove(self: *CacheImpl, key: K, hash_code: u64) bool {
                return switch (self.*) {
                    inline else => |*case| case.remove(key, hash_code),
                };
            }

            pub fn contains(self: *CacheImpl, key: K, hash_code: u64) bool {
                return switch (self.*) {
                    inline else => |*case| case.contains(key, hash_code),
                };
            }

            pub fn count(self: *CacheImpl) usize {
                return switch (self.*) {
                    inline else => |*case| case.count(),
                };
            }
        };

        allocator: std.mem.Allocator,
        shards: []CacheImpl,
        shard_mask: u16,

        const Self = @This();

        /// Initialize a new cache with the given configuration.
        pub fn init(allocator: std.mem.Allocator) !Self {
            const shard_count = try std.math.ceilPowerOfTwo(u16, config.shard_count);
            const shard_cache_size = config.cache_size / shard_count;
            // We allocate an extra node to handle the case where the pool is
            // full since we acquire a node before the eviction process. Check
            // the `set` method in the Map implementation for more information.
            const shard_pool_size = (config.pool_size orelse config.cache_size) / shard_count + 1;

            const shards = try allocator.alloc(CacheImpl, shard_count);
            errdefer allocator.free(shards);

            for (shards) |*shard| {
                shard.* = try CacheImpl.init(allocator, shard_cache_size, shard_pool_size, config.policy);
            }

            return .{
                .allocator = allocator,
                .shards = shards,
                .shard_mask = shard_count - 1,
            };
        }

        /// Cleans up all resources used by the cache.
        pub fn deinit(self: *Self) void {
            for (self.shards) |*shard| {
                shard.deinit();
            }
            self.allocator.free(self.shards);
        }

        /// Returns true if a key exists in the cache, false otherwise.
        pub fn contains(self: *Self, key: K) bool {
            const hash_code, const shard = self.getShard(key);
            return shard.contains(key, hash_code);
        }

        /// Returns the total number of items in the cache across all shards.
        pub fn count(self: *Self) usize {
            var total_count: usize = 0;
            for (self.shards) |*shard| {
                total_count += shard.count();
            }
            return total_count;
        }

        /// Set a key-value pair in the cache, evicting an item if necessary.
        /// Both the key and value must remain valid for as long as they're in the cache.
        pub fn set(self: *Self, key: K, value: V) !void {
            const hash_code, const shard = self.getShard(key);
            try shard.set(key, value, null, hash_code);
        }

        /// Sets a key-value pair in the cache with a specified Time-To-Live (TTL),
        /// evicting an item if necessary. The TTL determines how long the item
        /// should be considered valid in the cache before future `get()` calls
        /// for this entry returns a null result and is removed from the cache.
        /// Time is measured in milliseconds.
        pub fn setWithTTL(self: *Self, key: K, value: V, ttl: u64) !void {
            comptime if (!config.ttl_enabled) @compileError("TTL is not enabled for this cache configuration");

            const hash_code, const shard = self.getShard(key);
            try shard.set(key, value, ttl, hash_code);
        }

        /// Retrieve a value from the cache given its key.
        pub fn get(self: *Self, key: K) ?V {
            const hash_code, const shard = self.getShard(key);
            return shard.get(key, hash_code);
        }

        /// Removes a key-value pair from the cache if it exists.
        /// Returns true if it was successfully removed, false otherwise.
        pub fn remove(self: *Self, key: K) bool {
            const hash_code, const shard = self.getShard(key);
            return shard.remove(key, hash_code);
        }

        /// Determines which shard a given key belongs to based on its hash.
        /// This method ensures even distribution of items across shards for load balancing.
        pub fn getShard(self: *Self, key: K) struct { u64, *CacheImpl } {
            const hash_code = utils.hash(K, key);
            return .{ hash_code, &self.shards[hash_code & self.shard_mask] };
        }
    };
}

const testing = std.testing;

const TestConfig = Config{
    .cache_size = 100,
    .shard_count = 1,
    .policy = .FIFO,
};

test "Zigache - string keys" {
    var cache = try Cache([]const u8, []const u8, TestConfig).init(testing.allocator);
    defer cache.deinit();

    try cache.set("key1", "value1");
    try cache.set("key2", "value2");

    try testing.expectEqualStrings("value1", cache.get("key1").?);
    try testing.expectEqualStrings("value2", cache.get("key2").?);
    try testing.expect(cache.get("key3") == null);
}

test "Zigache - overwrite existing string key" {
    var cache = try Cache([]const u8, []const u8, TestConfig).init(testing.allocator);
    defer cache.deinit();

    try cache.set("key1", "value1");
    try cache.set("key1", "new_value1");

    try testing.expectEqualStrings("new_value1", cache.get("key1").?);
}

test "Zigache - remove string key" {
    var cache = try Cache([]const u8, []const u8, TestConfig).init(testing.allocator);
    defer cache.deinit();

    try cache.set("key1", "value1");
    try testing.expect(cache.remove("key1"));
    try testing.expect(cache.get("key1") == null);
    try testing.expect(!cache.remove("key1"));
}

test "Zigache - integer keys" {
    var cache = try Cache(i32, []const u8, TestConfig).init(testing.allocator);
    defer cache.deinit();

    try cache.set(1, "one");
    try cache.set(-5, "minus five");
    try cache.set(1000, "thousand");

    try testing.expectEqualStrings("one", cache.get(1).?);
    try testing.expectEqualStrings("minus five", cache.get(-5).?);
    try testing.expectEqualStrings("thousand", cache.get(1000).?);
    try testing.expect(cache.get(2) == null);

    try testing.expect(cache.remove(1));
    try testing.expect(cache.get(1) == null);
}

test "Zigache - struct keys" {
    const Point = struct { x: i32, y: i32 };

    var cache = try Cache(Point, []const u8, TestConfig).init(testing.allocator);
    defer cache.deinit();

    try cache.set(.{ .x = 1, .y = 2 }, "point one-two");
    try cache.set(.{ .x = -5, .y = -5 }, "point minus five-minus five");
    try cache.set(.{ .x = 1000, .y = 1000 }, "point thousand-thousand");

    try testing.expectEqualStrings("point one-two", cache.get(.{ .x = 1, .y = 2 }).?);
    try testing.expectEqualStrings("point minus five-minus five", cache.get(.{ .x = -5, .y = -5 }).?);
    try testing.expectEqualStrings("point thousand-thousand", cache.get(.{ .x = 1000, .y = 1000 }).?);
    try testing.expect(cache.get(.{ .x = 3, .y = 4 }) == null);

    try testing.expect(cache.remove(.{ .x = 1, .y = 2 }));
    try testing.expect(cache.get(.{ .x = 1, .y = 2 }) == null);
}

test "Zigache - array keys" {
    var cache = try Cache([3]u8, []const u8, TestConfig).init(testing.allocator);
    defer cache.deinit();

    try cache.set([3]u8{ 1, 2, 3 }, "one-two-three");
    try cache.set([3]u8{ 4, 5, 6 }, "four-five-six");
    try cache.set([3]u8{ 7, 8, 9 }, "seven-eight-nine");

    try testing.expectEqualStrings("one-two-three", cache.get([3]u8{ 1, 2, 3 }).?);
    try testing.expectEqualStrings("four-five-six", cache.get([3]u8{ 4, 5, 6 }).?);
    try testing.expectEqualStrings("seven-eight-nine", cache.get([3]u8{ 7, 8, 9 }).?);
    try testing.expect(cache.get([3]u8{ 0, 0, 0 }) == null);

    try testing.expect(cache.remove([3]u8{ 1, 2, 3 }));
    try testing.expect(cache.get([3]u8{ 1, 2, 3 }) == null);
}

test "Zigache - pointer keys" {
    var value1: i32 = 0;
    var value2: i32 = 100;
    var value3: i32 = 200;

    var cache = try Cache(*i32, []const u8, TestConfig).init(testing.allocator);
    defer cache.deinit();

    try cache.set(&value1, "pointer to 0");
    try cache.set(&value2, "pointer to 100");
    try cache.set(&value3, "pointer to 200");

    try testing.expectEqualStrings("pointer to 0", cache.get(&value1).?);
    try testing.expectEqualStrings("pointer to 100", cache.get(&value2).?);
    try testing.expectEqualStrings("pointer to 200", cache.get(&value3).?);
    try testing.expect(cache.get(&value1) != null);

    try testing.expect(cache.remove(&value2));
    try testing.expect(cache.get(&value2) == null);
}

test "Zigache - enum keys" {
    const Color = enum {
        Red,
        Green,
        Blue,
    };

    var cache = try Cache(Color, []const u8, TestConfig).init(testing.allocator);
    defer cache.deinit();

    try cache.set(.Red, "crimson");
    try cache.set(.Green, "emerald");
    try cache.set(.Blue, "sapphire");

    try testing.expectEqualStrings("crimson", cache.get(.Red).?);
    try testing.expectEqualStrings("emerald", cache.get(.Green).?);
    try testing.expectEqualStrings("sapphire", cache.get(.Blue).?);

    try testing.expect(cache.remove(.Green));
    try testing.expect(cache.get(.Green) == null);
}

test "Zigache - optional keys" {
    var cache = try Cache(?i32, []const u8, TestConfig).init(testing.allocator);
    defer cache.deinit();

    try cache.set(null, "no value");
    try cache.set(0, "zero");
    try cache.set(-1, "negative one");

    try testing.expectEqualStrings("no value", cache.get(null).?);
    try testing.expectEqualStrings("zero", cache.get(0).?);
    try testing.expectEqualStrings("negative one", cache.get(-1).?);

    try testing.expect(cache.remove(null));
    try testing.expect(cache.get(null) == null);
}
