const std = @import("std");
const zigache = @import("zigache");
const utils = @import("utils.zig");
const single_threaded = @import("single_threaded.zig");
const multi_threaded = @import("multi_threaded.zig");

const EvictionPolicy = zigache.Config.EvictionPolicy;
const BenchmarkResult = utils.BenchmarkResult;
const RunConfig = utils.RunConfig;

pub fn run(allocator: std.mem.Allocator, config: RunConfig) !void {
    const keys = try utils.generateKeys(allocator, config.num_keys, config.zipf);
    defer {
        for (keys) |sample| {
            allocator.free(sample.key);
        }
        allocator.free(keys);
    }

    const policies = [_]EvictionPolicy{
        .FIFO,
        .LRU,
        .TinyLFU,
        .SIEVE,
        .S3FIFO,
    };

    if (config.mode == .single or config.mode == .both) {
        std.debug.print("Single Threaded: zipf={d:.2} duration={d:.2}s keys={d} cache-size={d}\n", .{
            config.zipf,
            config.duration_ms / 1000,
            config.num_keys,
            config.cache_size,
        });
        try runBenchmarks(allocator, config, keys, &policies, single_threaded.benchSingle);
    }

    if (config.mode == .multi or config.mode == .both) {
        std.debug.print("Multi Threaded: zipf={d:.2} duration={d:.2}s keys={d} cache-size={d} shards={d} threads={d}\n", .{
            config.zipf,
            config.duration_ms / 1000,
            config.num_keys,
            config.cache_size,
            config.shard_count,
            config.num_threads,
        });
        try runBenchmarks(allocator, config, keys, &policies, multi_threaded.benchMulti);
    }
}

fn runBenchmarks(
    allocator: std.mem.Allocator,
    config: RunConfig,
    keys: []const utils.Sample,
    policies: []const EvictionPolicy,
    benchFn: fn (std.mem.Allocator, RunConfig, []const utils.Sample, EvictionPolicy) anyerror!BenchmarkResult,
) !void {
    var results = try allocator.alloc(BenchmarkResult, policies.len);
    defer allocator.free(results);

    for (policies, 0..) |policy, i| {
        results[i] = try benchFn(allocator, config, keys, policy);
    }

    try std.io.getStdOut().writer().print("\r", .{});
    try utils.printResults(allocator, results);
}
