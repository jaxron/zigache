const std = @import("std");
// Import the Cache type from the zigache library
const Cache = @import("zigache").Cache;

pub fn main() !void {
    // Set up a general purpose allocator
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Run examples for different key types
    try stringKeys(allocator);
    try integerKeys(allocator);
    try structKeys(allocator);
    try arrayKeys(allocator);
    try pointerKeys(allocator);
    try enumKeys(allocator);
    try optionalKeys(allocator);
}

fn stringKeys(allocator: std.mem.Allocator) !void {
    std.debug.print("\n--- String Keys ---\n", .{});

    // Create a cache with string keys and values
    // The cache size is set to 2 and uses the SIEVE eviction policy
    var cache: Cache([]const u8, []const u8, .{}) = try .init(allocator, .{ .cache_size = 2, .policy = .SIEVE });
    defer cache.deinit(); // Ensure cache resources are freed when we're done

    // Set key-value pairs in the cache
    try cache.put("key1", "value1");
    try cache.put("key2", "value2");

    // Retrieve a value from the cache
    if (cache.get("key1")) |value| {
        std.debug.print("Value for 'key1': {s}\n", .{value});
    }

    // Remove a key-value pair and check if it was successful
    _ = cache.remove("key2");
    std.debug.print("'key2' removed. Contains 'key2': {}\n", .{cache.contains("key2")});
}

fn integerKeys(allocator: std.mem.Allocator) !void {
    std.debug.print("\n--- Integer Keys ---\n", .{});

    // Create a cache with integer keys and string values
    var cache: Cache(i32, []const u8, .{}) = try .init(allocator, .{ .cache_size = 2, .policy = .SIEVE });
    defer cache.deinit();

    try cache.put(1, "one");
    try cache.put(2, "two");

    if (cache.get(1)) |value| {
        std.debug.print("Value for 1: {s}\n", .{value});
    }

    _ = cache.remove(2);
    std.debug.print("2 removed. Contains 2: {}\n", .{cache.contains(2)});
}

fn structKeys(allocator: std.mem.Allocator) !void {
    std.debug.print("\n--- Struct Keys ---\n", .{});

    // Define a custom struct to use as a key
    const Point = struct { x: i32, y: i32 };

    // Create a cache with struct keys and string values
    var cache: Cache(Point, []const u8, .{}) = try .init(allocator, .{ .cache_size = 2, .policy = .SIEVE });
    defer cache.deinit();

    try cache.put(.{ .x = 1, .y = 2 }, "point1");
    try cache.put(.{ .x = 3, .y = 4 }, "point2");

    if (cache.get(.{ .x = 1, .y = 2 })) |value| {
        std.debug.print("Value for (1,2): {s}\n", .{value});
    }

    _ = cache.remove(.{ .x = 3, .y = 4 });
    std.debug.print("(3,4) removed. Contains (3,4): {}\n", .{cache.contains(.{ .x = 3, .y = 4 })});
}

fn arrayKeys(allocator: std.mem.Allocator) !void {
    std.debug.print("\n--- Array Keys ---\n", .{});

    // Create a cache with fixed-size array keys
    var cache: Cache([3]u8, []const u8, .{}) = try .init(allocator, .{ .cache_size = 2, .policy = .SIEVE });
    defer cache.deinit();

    try cache.put([3]u8{ 1, 2, 3 }, "array1");
    try cache.put([3]u8{ 4, 5, 6 }, "array2");

    if (cache.get([3]u8{ 1, 2, 3 })) |value| {
        std.debug.print("Value for [1,2,3]: {s}\n", .{value});
    }

    _ = cache.remove([3]u8{ 4, 5, 6 });
    std.debug.print("[4,5,6] removed. Contains [4,5,6]: {}\n", .{cache.contains([3]u8{ 4, 5, 6 })});
}

fn pointerKeys(allocator: std.mem.Allocator) !void {
    std.debug.print("\n--- Pointer Keys ---\n", .{});

    // Create some values to point to
    var value1: i32 = 10;
    var value2: i32 = 20;

    // Create a cache with pointer keys
    var cache: Cache(*i32, []const u8, .{}) = try .init(allocator, .{ .cache_size = 2, .policy = .SIEVE });
    defer cache.deinit();

    try cache.put(&value1, "pointer1");
    try cache.put(&value2, "pointer2");

    if (cache.get(&value1)) |value| {
        std.debug.print("Value for &value1: {s}\n", .{value});
    }

    _ = cache.remove(&value2);
    std.debug.print("&value2 removed. Contains &value2: {}\n", .{cache.contains(&value2)});
}

fn enumKeys(allocator: std.mem.Allocator) !void {
    std.debug.print("\n--- Enum Keys ---\n", .{});

    // Define an enum to use as keys
    const Color = enum { Red, Green, Blue };

    // Create a cache with enum keys
    var cache: Cache(Color, []const u8, .{}) = try .init(allocator, .{ .cache_size = 2, .policy = .SIEVE });
    defer cache.deinit();

    try cache.put(.Red, "red");
    try cache.put(.Green, "green");

    if (cache.get(.Red)) |value| {
        std.debug.print("Value for Red: {s}\n", .{value});
    }

    _ = cache.remove(.Green);
    std.debug.print("Green removed. Contains Green: {}\n", .{cache.contains(.Green)});
}

fn optionalKeys(allocator: std.mem.Allocator) !void {
    std.debug.print("\n--- Optional Keys ---\n", .{});

    // Create a cache with optional integer keys
    var cache: Cache(?i32, []const u8, .{}) = try .init(allocator, .{ .cache_size = 2, .policy = .SIEVE });
    defer cache.deinit();

    try cache.put(null, "null_value");
    try cache.put(42, "forty_two");

    if (cache.get(null)) |value| {
        std.debug.print("Value for null: {s}\n", .{value});
    }

    _ = cache.remove(42);
    std.debug.print("42 removed. Contains 42: {}\n", .{cache.contains(42)});
}
