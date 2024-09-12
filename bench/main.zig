const std = @import("std");
const config = @import("config");
const utils = @import("utils.zig");
const benchmark = @import("benchmark.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try benchmark.run(.{
        .mode = getMode(),
        .cache_size = config.cache_size orelse 10_000,
        .base_size = config.base_size,
        .shard_count = config.shard_count orelse 1,
        .num_keys = config.num_keys orelse 1_000_000,
        .num_threads = config.num_threads orelse 1,
        .zipf = config.zipf orelse 0.7,
        .duration_ms = config.duration_ms orelse 60_000,
    }, allocator);
}

/// Determine the benchmark mode based on the configuration
fn getMode() utils.Mode {
    const mode = config.mode orelse return .single;
    if (std.mem.eql(u8, mode, "multi")) {
        return .multi;
    } else if (std.mem.eql(u8, mode, "both")) {
        return .both;
    }
    return .single;
}

// Ensure that the zipfian module is included in the build for tests
comptime {
    _ = @import("zipfian.zig");
}
