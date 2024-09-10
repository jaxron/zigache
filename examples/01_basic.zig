const std = @import("std");
const Cache = @import("zigache").Cache;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a cache with string keys and values
    // The cache is configured with:
    // - total_size: 1 (can store 1 item before eviction starts)
    // - shard_count: 1 (no sharding, single shard)
    // - policy: SIEVE (uses the SIEVE eviction policy)
    var cache = try Cache([]const u8, []const u8).init(allocator, .{
        .total_size = 1,
        .shard_count = 1,
        .policy = .SIEVE,
    });
    // Ensure we clean up the cache when we're done
    defer cache.deinit();

    // Set a key-value pair in the cache
    // NOTE: Both the key and value must remain valid for as long as they're in the cache
    try cache.set("key1", "value1");

    // Retrieve a value from the cache
    std.debug.print("We've set the value, let's try to get it\n", .{});
    if (cache.get("key1")) |value| {
        std.debug.print("Value found: {s}\n", .{value});
    } else {
        std.debug.print("Value not found\n", .{});
    }

    // Remove a value from the cache
    // The remove() method returns a boolean indicating success
    _ = cache.remove("key1");

    // Try to get a value that doesn't exist (or has been removed)
    std.debug.print("We've removed the value, let's try to get it again\n", .{});
    if (cache.get("key1")) |value| {
        std.debug.print("Value found: {s}\n", .{value});
    } else {
        std.debug.print("Value not found\n", .{});
    }

    // NOTE: This example uses a cache size of 1, so inserting a second item
    // would cause the first item to be evicted. In real-world usage,
    // you'd typically use a larger cache size.
}
