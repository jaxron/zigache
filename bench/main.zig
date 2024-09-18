const std = @import("std");
const opts = @import("config");
const zigache = @import("zigache");
const utils = @import("utils.zig");

const Benchmark = @import("benchmark.zig").Benchmark;
const Zipfian = @import("Zipfian.zig");
const Allocator = std.mem.Allocator;
const PolicyConfig = zigache.Config.PolicyConfig;
const BenchmarkResult = utils.BenchmarkResult;
const TraceBenchmarkResult = utils.TraceBenchmarkResult;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Generate keys for the benchmark
    const keys = try generateKeys(allocator);
    defer allocator.free(keys);

    // Run benchmarks based on the execution mode
    if (opts.trace orelse false)
        try runTrace(allocator, keys)
    else
        try runNormal(allocator, keys);
}

fn generateKeys(allocator: Allocator) ![]utils.Sample {
    const num_keys = opts.num_keys orelse 1000000;
    const s = opts.zipf orelse 1.0;

    var zipf_distribution: Zipfian = try .init(num_keys, s);
    var prng: std.Random.DefaultPrng = .init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const rand = prng.random();

    const keys = try allocator.alloc(utils.Sample, num_keys);
    errdefer allocator.free(keys);

    for (keys) |*sample| {
        const value = zipf_distribution.next(rand);
        sample.* = .{ .key = value, .value = value };
    }

    return keys;
}

pub fn runNormal(allocator: Allocator, keys: []utils.Sample) !void {
    // Run normal benchmarks
    const config = comptime getConfig(opts.cache_size orelse 10000);
    const benchmark = try runBenchmark(config, allocator, keys);
    defer allocator.free(benchmark);

    // Print results
    try std.io.getStdOut().writer().print("\r", .{});
    try utils.printResults(allocator, benchmark);
}

pub fn runTrace(allocator: Allocator, keys: []utils.Sample) !void {
    // Run trace benchmarks
    const cache_sizes = comptime utils.generateCacheSizes();
    var results: [cache_sizes.len]TraceBenchmarkResult = undefined;

    inline for (cache_sizes, 0..) |cache_size, i| {
        const config = comptime getConfig(cache_size);
        const benchmark = try runBenchmark(config, allocator, keys);
        defer allocator.free(benchmark);

        results[i] = .{
            .cache_size = cache_size,
            .fifo = benchmark[0],
            .lru = benchmark[1],
            .tinylfu = benchmark[2],
            .sieve = benchmark[3],
            .s3fifo = benchmark[4],
        };
    }

    // Write results to CSV files
    const execution_mode = comptime if (getExecutionMode() == .multi) "multi" else "single";
    try utils.generateCSVs(execution_mode, &results);

    std.debug.print("\rBenchmark results have been written to CSV files{s}\n", .{" " ** 30}); // Padding to ensure clean overwrite
}

fn runBenchmark(comptime config: utils.Config, allocator: Allocator, keys: []utils.Sample) ![]BenchmarkResult {
    // Get all eviction policies
    const policies = comptime std.meta.fields(PolicyConfig);
    var results = try allocator.alloc(BenchmarkResult, policies.len);

    // Run benchmarks based on the execution mode
    try printBenchmarkHeader(config);
    inline for (policies, 0..) |policy, i| {
        const policy_config = @unionInit(PolicyConfig, policy.name, .{});
        results[i] = try Benchmark(config, policy_config).bench(allocator, keys);
    }

    return results;
}

fn printBenchmarkHeader(comptime config: utils.Config) !void {
    const stdout = std.io.getStdOut().writer();

    // Print required configuration
    try stdout.print("\r{s}: ", .{if (config.execution_mode == .multi) "Multi Threaded" else "Single Threaded"});
    switch (config.stop_condition) {
        .duration => |ms| try stdout.print("duration={d:.2}s ", .{@as(f64, @floatFromInt(ms)) / 1000}),
        .operations => |ops| try stdout.print("operations={d} ", .{ops}),
    }
    try stdout.print("keys={d} cache-size={d} pool-size={d} zipf={d:.2}", .{ config.num_keys, config.cache_size, config.pool_size orelse config.cache_size, opts.zipf orelse 1.0 });

    // Print additional configuration for multi-threaded benchmarks
    if (config.execution_mode == .multi) {
        try stdout.print(" shards={d} threads={d}", .{ config.shard_count, config.num_threads });
    }

    try stdout.print("{s}\n", .{" " ** 10}); // Padding to ensure clean overwrite
}

fn getConfig(cache_size: u32) utils.Config {
    const mode = getExecutionMode();
    const condition = getStopCondition();
    return .{
        .execution_mode = mode,
        .stop_condition = condition,
        .cache_size = cache_size,
        .pool_size = opts.pool_size,
        .shard_count = opts.shard_count orelse 64,
        .num_keys = opts.num_keys orelse 1000000,
        .num_threads = if (mode == .multi) opts.num_threads orelse 4 else 1,
        .zipf = opts.zipf orelse 1.0,
    };
}

/// Determine the benchmark execution mode based on the configuration
fn getExecutionMode() utils.ExecutionMode {
    const mode = opts.mode orelse return .single;
    return if (std.mem.eql(u8, mode, "multi")) .multi else .single;
}

/// Determine the stop condition based on the configuration
fn getStopCondition() utils.StopCondition {
    return if (opts.duration_ms) |ms|
        .{ .duration = ms }
    else if (opts.max_ops) |ops|
        .{ .operations = ops }
    else
        .{ .duration = 10000 };
}

// Ensure that the zipfian module is included in the build for tests
comptime {
    _ = @import("Zipfian.zig");
}
