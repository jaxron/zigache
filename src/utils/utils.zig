const std = @import("std");

const Allocator = std.mem.Allocator;

/// TestCache is a wrapper around a Cache implementation that simplifies testing
/// by providing a consistent interface for different cache algorithms.
pub fn TestCache(comptime Cache: type) type {
    return struct {
        const K = u32;
        const V = []const u8;

        cache: Cache,

        const Self = @This();

        pub fn init(allocator: Allocator, cache_size: K) !Self {
            return .{
                .cache = try Cache.init(allocator, cache_size, cache_size),
            };
        }

        pub fn deinit(self: *Self) void {
            self.cache.deinit();
        }

        pub fn set(self: *Self, key: K, value: V) !void {
            try self.cache.set(key, value, null, hash(K, key));
        }

        pub fn setTTL(self: *Self, key: K, value: V, ttl: u64) !void {
            try self.cache.set(key, value, ttl, hash(K, key));
        }

        pub fn get(self: *Self, key: K) ?V {
            return self.cache.get(key, hash(K, key));
        }

        pub fn remove(self: *Self, key: K) bool {
            return self.cache.remove(key, hash(K, key));
        }
    };
}

/// Compute a hash for the given key.
pub fn hash(comptime K: type, key: K) u64 {
    if (K == []const u8) {
        return std.hash.Wyhash.hash(0, key);
    } else {
        if (std.meta.hasUniqueRepresentation(K)) {
            return std.hash.Wyhash.hash(0, std.mem.asBytes(&key));
        } else {
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHash(&hasher, key);
            return hasher.final();
        }
    }
}

/// Calculate the expiry time for a given TTL.
/// Returns the current time plus the TTL in milliseconds, or null if no TTL is provided.
pub inline fn getExpiry(ttl: ?u64) ?i64 {
    return if (ttl) |t|
        std.time.milliTimestamp() + @as(i64, @intCast(t))
    else
        null;
}
