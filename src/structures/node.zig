const std = @import("std");

/// Node represents an entry in the cache.
/// It contains the key-value pair, linked list pointers, expiration information,
/// and additional data specific to the caching algorithm.
pub fn Node(comptime K: type, comptime V: type, comptime Data: type, comptime ttl_enabled: bool) type {
    return struct {
        pub const empty = .{
            .key = undefined,
            .value = undefined,
            .next = null,
            .prev = null,
            .expiry = if (ttl_enabled) null else {},
            .data = undefined,
        };

        key: K,
        value: V,

        /// Pointer to the next node in the linked list
        next: ?*Self,
        // Pointer to the previous node in the linked list
        prev: ?*Self,

        /// The expiry field stores the timestamp when this cache entry should expire, in milliseconds.
        /// It is of type `?i64`, where:
        /// - `null` indicates that the entry does not expire
        /// - A non-null value represents the expiration time as a Unix timestamp
        ///   (milliseconds since the Unix epoch)
        ///
        /// This field is used in TTL (Time-To-Live) operations to determine if an entry
        /// should be considered valid or if it should be removed from the cache.
        expiry: if (ttl_enabled) ?i64 else void,

        /// Additional data specific to the caching algorithm (e.g., frequency counters, flags)
        data: Data,

        const Self = @This();

        pub fn update(self: *Self, key: K, value: V, ttl: ?u64, data: Data) void {
            self.* = .{
                .key = key,
                .value = value,
                .next = self.next,
                .prev = self.prev,
                // Calculate the expiry time in milliseconds for a given TTL.
                .expiry = if (ttl_enabled)
                    if (ttl) |t| std.time.milliTimestamp() + @as(i64, @intCast(t)) else null
                else {},
                .data = data,
            };
        }
    };
}
