const std = @import("std");
const config = @import("config");
const utils = @import("utils.zig");
const benchmark = @import("benchmark.zig");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cache_size = config.cache_size orelse 10_000;
    var bench: benchmark.Benchmark(.{
        .execution_mode = getExecutionMode(),
        .stop_condition = getStopCondition(),
        .cache_size = cache_size,
        .pool_size = config.pool_size,
        .shard_count = config.shard_count orelse 1,
        .num_keys = config.num_keys orelse cache_size * 32,
        .num_threads = config.num_threads orelse 4,
        .zipf = config.zipf orelse 0.7,
    }) = try .init(allocator);
    try bench.run();
}

/// Determine the benchmark execution mode based on the configuration
fn getExecutionMode() utils.ExecutionMode {
    const mode = config.mode orelse return .single;
    if (std.mem.eql(u8, mode, "multi")) {
        return .multi;
    } else if (std.mem.eql(u8, mode, "both")) {
        return .both;
    }
    return .single;
}

/// Determine the stop condition based on the configuration
fn getStopCondition() utils.StopCondition {
    if (config.duration_ms) |ms| {
        return .{ .duration = ms };
    } else if (config.max_ops) |ops| {
        return .{ .operations = ops };
    }
    return .{ .duration = 60000 };
}

// Ensure that the zipfian module is included in the build for tests
comptime {
    _ = @import("Zipfian.zig");
}
