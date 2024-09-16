const std = @import("std");
const math = std.math;

const Allocator = std.mem.Allocator;

/// CountMinSketch is a probabilistic data structure for approximating frequencies of elements in a data stream.
/// It uses multiple hash functions to maintain an array of counters, allowing for efficient frequency estimation.
pub const CountMinSketch = struct {
    allocator: Allocator,
    counters: [][]u4,
    width: usize,
    depth: usize,

    total_count: u64 = 0,
    reset_threshold: u32,

    /// Initialize a new CountMinSketch with the given width and depth.
    pub fn init(allocator: Allocator, width: usize, depth: usize, reset_threshold: u32) !CountMinSketch {
        const counters = try allocator.alloc([]u4, depth);
        errdefer allocator.free(counters);

        var available: usize = 0;
        errdefer {
            for (counters[0..available]) |row| {
                allocator.free(row);
            }
        }

        for (counters) |*row| {
            row.* = try allocator.alloc(u4, width);
            @memset(row.*, 0);
            available += 1;
        }

        return .{
            .allocator = allocator,
            .counters = counters,
            .width = width,
            .depth = depth,
            .reset_threshold = reset_threshold,
        };
    }

    /// Releases all resources associated with this sketch.
    pub fn deinit(self: *CountMinSketch) void {
        for (self.counters) |row| {
            self.allocator.free(row);
        }
        self.allocator.free(self.counters);
    }

    /// Increment the count for an item in the sketch.
    pub fn increment(self: *CountMinSketch, hash_code: u64) void {
        self.total_count += 1;
        for (self.counters, 0..) |row, i| {
            const index: usize = @intCast((hash_code +% i) % self.width);
            row[index] +%= 1;
        }

        if (self.total_count >= self.reset_threshold) {
            self.reset();
        }
    }

    /// Estimate the count of an item in the sketch.
    pub fn estimate(self: CountMinSketch, hash_code: u64) u32 {
        var min_count: u32 = math.maxInt(u32);
        for (self.counters, 0..) |row, i| {
            const index: usize = @intCast((hash_code +% i) % self.width);
            min_count = @min(min_count, row[index]);
        }
        return min_count;
    }

    /// Reset all counters by dividing them by 2. This helps prevent
    /// overflow and allows the sketch to adapt to changing frequencies
    /// over time.
    pub fn reset(self: *CountMinSketch) void {
        for (self.counters) |row| {
            for (row) |*cell| {
                cell.* >>= 1;
            }
        }
        self.total_count >>= 1;
    }
};

const testing = std.testing;

test "CountMinSketch - initialization" {
    var cms: CountMinSketch = try .init(testing.allocator, 10, 5, 10);
    defer cms.deinit();

    try testing.expectEqual(10, cms.width);
    try testing.expectEqual(5, cms.depth);
}

test "CountMinSketch - increment and estimate" {
    var cms: CountMinSketch = try .init(testing.allocator, 100, 5, 100);
    defer cms.deinit();

    const item1: u64 = 123;
    const item2: u64 = 456;

    // Increment item1 three times
    cms.increment(item1);
    cms.increment(item1);
    cms.increment(item1);

    // Increment item2 once
    cms.increment(item2);

    // Check estimates
    try testing.expectEqual(3, cms.estimate(item1));
    try testing.expectEqual(1, cms.estimate(item2));

    // Check estimate for non-existent item
    try testing.expectEqual(0, cms.estimate(321));
}

test "CountMinSketch - overflow and reset" {
    var cms: CountMinSketch = try .init(testing.allocator, 10, 3, 10);
    defer cms.deinit();

    const item: u64 = 123;

    // Increment the item 20 times
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        cms.increment(item);
    }

    // The estimate should be 5 due to the reset
    const estimate = cms.estimate(item);
    try testing.expect(estimate == 5);
}

test "CountMinSketch - multiple items" {
    var cms: CountMinSketch = try .init(testing.allocator, 100, 5, 100);
    defer cms.deinit();

    const items = [_]u64{ 1, 2, 3, 4, 5 };
    const increments = [_]usize{ 3, 1, 4, 1, 5 };

    for (items, increments) |item, count| {
        for (0..count) |_| {
            cms.increment(item);
        }
    }

    for (items, increments) |item, expected| {
        const estimate = cms.estimate(item);
        try testing.expectEqual(expected, estimate);
    }
}
