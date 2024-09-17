const std = @import("std");
const opts = @import("config");
const zigache = @import("zigache");
const utils = @import("utils.zig");
const single_threaded = @import("single_threaded.zig");
const multi_threaded = @import("multi_threaded.zig");

const Zipfian = @import("Zipfian.zig");
const Allocator = std.mem.Allocator;
const PolicyConfig = zigache.Config.PolicyConfig;
const BenchmarkResult = utils.BenchmarkResult;

pub const TraceBenchmarkResult = struct {
    cache_size: u32,
    fifo: BenchmarkResult,
    lru: BenchmarkResult,
    tinylfu: BenchmarkResult,
    sieve: BenchmarkResult,
    s3fifo: BenchmarkResult,
};

const BenchmarkMetric = enum {
    ns_per_op,
    hit_rate,
    ops_per_second,

    fn header(self: BenchmarkMetric) []const u8 {
        return switch (self) {
            .ns_per_op => "ns/op",
            .hit_rate => "Hit Rate (%)",
            .ops_per_second => "ops/s",
        };
    }
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Generate keys for the benchmark
    const keys = try generateKeys(allocator, opts.num_keys orelse 1000000, opts.zipf orelse 1.0);
    defer allocator.free(keys);

    // Run benchmarks based on the execution mode
    if (opts.trace orelse false)
        try runTrace(allocator, keys)
    else
        try runNormal(allocator, keys);
}

fn generateKeys(allocator: Allocator, num_keys: u32, s: f64) ![]utils.Sample {
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
        sample.key = value;
        sample.value = value;
    }

    return keys;
}

pub fn runNormal(allocator: Allocator, keys: []const utils.Sample) !void {
    // Run normal benchmarks
    const config = comptime getConfig(opts.cache_size orelse 10000);
    const benchmark = try runBenchmark(config, allocator, keys);
    defer allocator.free(benchmark);

    // Print results
    try std.io.getStdOut().writer().print("\r", .{});
    try utils.printResults(allocator, benchmark);
}

pub fn runTrace(allocator: Allocator, keys: []const utils.Sample) !void {
    // Run trace benchmarks
    const cache_sizes = comptime generateCacheSizes();
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
    try generateCSVs(execution_mode, &results);

    std.debug.print("\rBenchmark results have been written to CSV files{s}\n", .{" " ** 30}); // Padding to ensure clean overwrite
}

fn runBenchmark(comptime config: utils.Config, allocator: Allocator, keys: []const utils.Sample) ![]BenchmarkResult {
    // Get all eviction policies
    const policies = comptime std.meta.fields(PolicyConfig);
    var results = try allocator.alloc(BenchmarkResult, policies.len);

    // Run benchmarks based on the execution mode
    switch (config.execution_mode) {
        .single => {
            try printBenchmarkHeader(config);
            inline for (policies, 0..) |policy, i| {
                const policy_config = @unionInit(PolicyConfig, policy.name, .{});
                results[i] = try single_threaded.SingleThreaded(config, policy_config).bench(allocator, keys);
            }
        },
        .multi => {
            try printBenchmarkHeader(config);
            inline for (policies, 0..) |policy, i| {
                const policy_config = @unionInit(PolicyConfig, policy.name, .{});
                results[i] = try multi_threaded.MultiThreaded(config, policy_config).bench(allocator, keys);
            }
        },
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

fn generateCSVs(comptime execution_type: []const u8, results: []const TraceBenchmarkResult) !void {
    try generateCSV("benchmark_nsop_" ++ execution_type ++ ".csv", .ns_per_op, results);
    try generateCSV("benchmark_hitrate_" ++ execution_type ++ ".csv", .hit_rate, results);
    try generateCSV("benchmark_opspersecond_" ++ execution_type ++ ".csv", .ops_per_second, results);
}

fn generateCSV(filename: []const u8, metric: BenchmarkMetric, results: []const TraceBenchmarkResult) !void {
    const file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();

    const writer = file.writer();

    // Write header
    const header = metric.header();
    try writer.print("Cache Size,FIFO {s},LRU {s},TinyLFU {s},SIEVE {s},S3FIFO {s}\n", .{
        header,
        header,
        header,
        header,
        header,
    });

    // Write results
    for (results) |result| {
        try writer.print("{}", .{result.cache_size});
        inline for (.{ "fifo", "lru", "tinylfu", "sieve", "s3fifo" }) |policy| {
            const value = switch (metric) {
                .ns_per_op => @field(result, policy).ns_per_op,
                .hit_rate => @field(result, policy).hit_rate * 100,
                .ops_per_second => @field(result, policy).ops_per_second,
            };
            try writer.print(",{d:.2}", .{value});
        }
        try writer.writeByte('\n');
    }
}

fn getConfig(cache_size: u32) utils.Config {
    return .{
        .execution_mode = getExecutionMode(),
        .stop_condition = getStopCondition(),
        .cache_size = cache_size,
        .pool_size = opts.pool_size,
        .shard_count = opts.shard_count orelse 64,
        .num_keys = opts.num_keys orelse 1000000,
        .num_threads = opts.num_threads orelse 4,
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

/// Generate cache sizes for the trace benchmarks
fn generateCacheSizes() [20]u32 {
    var sizes: [20]u32 = undefined;
    for (0..20) |i| {
        sizes[i] = (i + 1) * 5000;
    }
    return sizes;
}

// Ensure that the zipfian module is included in the build for tests
comptime {
    _ = @import("Zipfian.zig");
}
