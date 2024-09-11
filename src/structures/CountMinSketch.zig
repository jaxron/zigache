const std = @import("std");
const math = std.math;

const Allocator = std.mem.Allocator;

allocator: Allocator,
counters: [][]u4,
width: usize,
depth: usize,

const Self = @This();

pub fn init(allocator: Allocator, width: usize, depth: usize) !Self {
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

pub fn deinit(self: *Self) void {
    for (self.counters) |row| {
        self.allocator.free(row);
    }
    self.allocator.free(self.counters);
}

pub fn increment(self: *Self, hash_code: u64) void {
    for (self.counters, 0..) |row, i| {
        const row_hash = hash_code +% i;
        const index = row_hash % self.width;
        if (row[index] == 15) {
            self.reset();
        }
        row[index] +%= 1;
    }
}

pub fn estimate(self: Self, hash_code: u64) u32 {
    var min_count: u32 = math.maxInt(u32);
    for (self.counters, 0..) |row, i| {
        const row_hash = hash_code +% i;
        const index = row_hash % self.width;
        min_count = @min(min_count, row[index]);
    }
    return min_count;
}

pub fn reset(self: *Self) void {
    for (self.counters) |row| {
        for (row) |*cell| {
            cell.* >>= 1;
        }
    }
}
