const std = @import("std");
const config = @import("config");
const utils = @import("utils.zig");
const benchmark = @import("benchmark.zig");

const TraceBenchmarkResult = benchmark.TraceBenchmarkResult;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const trace_mode = config.trace orelse false;
    if (trace_mode) {
        try runTraceBenchmarks(allocator);
    } else {
        try runNormalBenchmarks(allocator);
    }
}

fn runTraceBenchmarks(allocator: std.mem.Allocator) !void {
    const cache_sizes = comptime generateCacheSizes();
    var results: [cache_sizes.len]TraceBenchmarkResult = undefined;

    inline for (cache_sizes, 0..) |cache_size, i| {
        var bench: benchmark.Benchmark(getConfig(cache_size)) = try .init(allocator);
        results[i] = try bench.runTrace();
    }

    try generateNsOpCSV(&results);
    try generateHitRateCSV(&results);
    try generateOpsPerSecondCSV(&results);

    std.debug.print("\rBenchmark results have been written to CSV files{s}\n", .{" " ** 30}); // Padding to ensure clean overwrite
}

fn runNormalBenchmarks(allocator: std.mem.Allocator) !void {
    var bench: benchmark.Benchmark(getConfig(config.cache_size orelse 10_000)) = try .init(allocator);
    try bench.runNormal();
}

fn getConfig(cache_size: u32) utils.Config {
    return .{
        .execution_mode = getExecutionMode(),
        .stop_condition = getStopCondition(),
        .cache_size = cache_size,
        .pool_size = config.pool_size,
        .shard_count = config.shard_count orelse 64,
        .num_keys = config.num_keys orelse 1000000,
        .num_threads = config.num_threads orelse 4,
        .zipf = config.zipf orelse 1.0,
    };
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
    return .{ .duration = 10000 };
}

/// Generate cache sizes for the trace benchmarks
fn generateCacheSizes() [20]u32 {
    var sizes: [20]u32 = undefined;
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        sizes[i] = (i + 1) * 5000;
    }
    return sizes;
}

fn generateNsOpCSV(results: []TraceBenchmarkResult) !void {
    const file = try std.fs.cwd().createFile("benchmark_nsop.csv", .{});
    defer file.close();

    const writer = file.writer();

    try writer.writeAll("Cache Size (number of entries),FIFO ns/op,LRU ns/op,TinyLFU ns/op,SIEVE ns/op,S3FIFO ns/op\n");
    for (results) |result| {
        try writer.print("{},{d:.2},{d:.2},{d:.2},{d:.2},{d:.2}\n", .{
            result.cache_size,
            result.fifo.ns_per_op,
            result.lru.ns_per_op,
            result.tinylfu.ns_per_op,
            result.sieve.ns_per_op,
            result.s3fifo.ns_per_op,
        });
    }
}

fn generateHitRateCSV(results: []TraceBenchmarkResult) !void {
    const file = try std.fs.cwd().createFile("benchmark_hitrate.csv", .{});
    defer file.close();

    const writer = file.writer();

    try writer.writeAll("Cache Size,FIFO Hit Rate (%),LRU Hit Rate (%),TinyLFU Hit Rate (%),SIEVE Hit Rate (%),S3FIFO Hit Rate (%)\n");
    for (results) |result| {
        try writer.print("{},{d:.2},{d:.2},{d:.2},{d:.2},{d:.2}\n", .{
            result.cache_size,
            result.fifo.hit_rate * 100,
            result.lru.hit_rate * 100,
            result.tinylfu.hit_rate * 100,
            result.sieve.hit_rate * 100,
            result.s3fifo.hit_rate * 100,
        });
    }
}

fn generateOpsPerSecondCSV(results: []TraceBenchmarkResult) !void {
    const file = try std.fs.cwd().createFile("benchmark_opspersecond.csv", .{});
    defer file.close();

    const writer = file.writer();

    try writer.writeAll("Cache Size,FIFO ops/s,LRU ops/s,TinyLFU ops/s,SIEVE ops/s,S3FIFO ops/s\n");
    for (results) |result| {
        try writer.print("{},{d:.2},{d:.2},{d:.2},{d:.2},{d:.2}\n", .{
            result.cache_size,
            result.fifo.ops_per_second,
            result.lru.ops_per_second,
            result.tinylfu.ops_per_second,
            result.sieve.ops_per_second,
            result.s3fifo.ops_per_second,
        });
    }
}

// Ensure that the zipfian module is included in the build for tests
comptime {
    _ = @import("Zipfian.zig");
}
