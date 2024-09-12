const std = @import("std");
const Cache = @import("zigache").Cache;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a cache with string keys and values
    var cache = try Cache([]const u8, []const u8, .{
        .total_size = 1,
        .policy = .SIEVE,
    }).init(allocator);
    defer cache.deinit();

    // Set a key-value pair in the cache
    // Both the key and value must remain valid for as long as they're in the cache
    try cache.set("key1", "value1");

    // Retrieve a value from the cache
    if (cache.get("key1")) |value| {
        std.debug.print("Value: {s}\n", .{value});
    }

    // Remove a value from the cache
    _ = cache.remove("key1");
}
