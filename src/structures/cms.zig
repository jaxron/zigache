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

    /// Initialize a new CountMinSketch with the given width and depth.
    pub fn init(allocator: Allocator, width: usize, depth: usize) !CountMinSketch {
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
        for (self.counters, 0..) |row, i| {
            const index: usize = @intCast((hash_code +% i) % self.width);
            if (row[index] == 15) {
                self.reset();
            }
            row[index] +%= 1;
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
    }
};
