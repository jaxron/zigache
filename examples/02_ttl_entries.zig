const std = @import("std");
const Cache = @import("zigache").Cache;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var cache: Cache([]const u8, []const u8, .{
        .cache_size = 10,
        .policy = .SIEVE,
        .ttl_enabled = true, // Enable TTL functionality
    }) = try .init(allocator);
    defer cache.deinit();

    // Shows basic TTL functionality
    try basicTTLUsage(&cache);

    // Shows how TTL interacts with cache operations
    try ttlInteractions(&cache);
}

fn basicTTLUsage(cache: anytype) !void {
    std.debug.print("\n--- Basic TTL Usage ---\n", .{});

    // Set an item with a 1 second TTL
    try cache.setWithTTL("short_lived", "i'll be gone soon", 1000);
    std.debug.print("short_lived (immediate): {?s}\n", .{cache.get("short_lived")});

    // Set an item with a longer TTL
    try cache.setWithTTL("long_lived", "i'll stick around", 10000);
    std.debug.print("long_lived (immediate): {?s}\n", .{cache.get("long_lived")});

    // After 1 second, short_lived should be gone, but long_lived should remain
    std.time.sleep(1 * std.time.ns_per_s);
    std.debug.print("short_lived (after 1s): {?s}\n", .{cache.get("short_lived")});
    std.debug.print("long_lived (after 1s): {?s}\n", .{cache.get("long_lived")});
}

fn ttlInteractions(cache: anytype) !void {
    std.debug.print("\n--- TTL Interactions ---\n", .{});

    // Set an item with a 3 second TTL
    try cache.setWithTTL("interactive", "original value", 3000);
    std.debug.print("interactive (immediate): {?s}\n", .{cache.get("interactive")});

    // After 1 second, update the value and TTL
    std.time.sleep(1 * std.time.ns_per_s);
    try cache.setWithTTL("interactive", "updated value", 5000);

    // After 2 more seconds, the item should still be present due to the TTL update
    std.time.sleep(2 * std.time.ns_per_s);
    std.debug.print("interactive (after 3s): {?s}\n", .{cache.get("interactive")});

    // After 3 more seconds, the item should be gone
    std.time.sleep(3 * std.time.ns_per_s);
    std.debug.print("interactive (after 6s): {?s}\n", .{cache.get("interactive")});
}
