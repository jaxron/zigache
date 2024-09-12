const std = @import("std");
const zigache = @import("zigache");
const utils = @import("utils.zig");
const single_threaded = @import("single_threaded.zig");
const multi_threaded = @import("multi_threaded.zig");

const EvictionPolicy = zigache.Config.EvictionPolicy;
const BenchmarkResult = utils.BenchmarkResult;
const Config = utils.Config;

pub fn run(comptime config: Config, allocator: std.mem.Allocator) !void {
    // Generate keys for the benchmark
    const keys = try utils.generateKeys(allocator, config.num_keys, config.zipf);
    defer {
        for (keys) |sample| {
            allocator.free(sample.key);
        }
        allocator.free(keys);
    }

    // Run single-threaded benchmark if specified
    if (config.mode == .single or config.mode == .both) {
        std.debug.print("Single Threaded: zipf={d:.2} duration={d:.2}s keys={d} cache-size={d}\n", .{
            config.zipf,
            config.duration_ms / 1000,
            config.num_keys,
            config.cache_size,
        });
        try runBenchmarks(config, single_threaded.SingleThreaded, allocator, keys);
    }

    // Run multi-threaded benchmark if specified
    if (config.mode == .multi or config.mode == .both) {
        std.debug.print("Multi Threaded: zipf={d:.2} duration={d:.2}s keys={d} cache-size={d} shards={d} threads={d}\n", .{
            config.zipf,
            config.duration_ms / 1000,
            config.num_keys,
            config.cache_size,
            config.shard_count,
            config.num_threads,
        });
        try runBenchmarks(config, multi_threaded.MultiThreaded, allocator, keys);
    }
}

fn runBenchmarks(
    comptime config: Config,
    comptime BenchType: fn (comptime Config, comptime EvictionPolicy) type,
    allocator: std.mem.Allocator,
    keys: []const utils.Sample,
) !void {
    // Get all eviction policies
    const policies = comptime std.meta.tags(EvictionPolicy);
    var results = try allocator.alloc(BenchmarkResult, policies.len);
    defer allocator.free(results);

    // Run benchmark for each eviction policy
    inline for (policies, 0..) |policy, i| {
        const Bench = BenchType(config, policy);
        results[i] = try Bench.bench(allocator, keys);
    }

    // Print results
    try std.io.getStdOut().writer().print("\r", .{});
    try utils.printResults(allocator, results);
}
