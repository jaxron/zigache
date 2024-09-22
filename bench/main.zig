const std = @import("std");
const opts = @import("config");
const zigache = @import("zigache");
const utils = @import("utils.zig");

const Benchmark = @import("benchmark.zig").Benchmark;
const Zipfian = @import("Zipfian.zig");
const Allocator = std.mem.Allocator;
const PolicyOptions = zigache.CacheInitOptions.PolicyOptions;
const BenchmarkResult = utils.BenchmarkResult;
const ReplayBenchmarkResult = utils.ReplayBenchmarkResult;

const keys_file = "benchmark_keys.bin";

// Default configuration values
const default_auto_sizes = "20:50000";
const default_cache_size: u32 = 100_000;
const default_pool_size: ?u32 = null;
const default_num_keys: u32 = 10_000_000;
const default_shard_count: u16 = 1;
const default_num_threads: u8 = 1;
const default_zipf: f64 = 0.9;
const default_duration_ms: u64 = 10_000;
const default_replay: bool = true;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const keys = if (opts.replay orelse default_replay) try loadOrGenerateKeys(allocator) else try generateKeys(allocator);
    defer allocator.free(keys);

    if (opts.custom orelse false)
        try runCustom(allocator, keys)
    else
        try runDefault(allocator, keys);

    try saveKeys(keys);
}

fn loadOrGenerateKeys(allocator: Allocator) ![]utils.Sample {
    const num_keys = opts.num_keys orelse default_num_keys;
    const file = std.fs.cwd().openFile(keys_file, .{}) catch {
        return generateKeys(allocator);
    };
    defer file.close();

    var gzip_stream = std.compress.gzip.decompressor(file.reader());
    const file_content = gzip_stream.reader().readAllAlloc(allocator, std.math.maxInt(usize)) catch |err| {
        if (err == error.EndOfStream) {
            std.debug.panic("File {s} is corrupted. Please delete it and try again.\n", .{keys_file});
        }
        return err;
    };
    defer allocator.free(file_content);

    const keys_in_file = @divExact(file_content.len, @sizeOf(utils.Sample));
    if (keys_in_file != num_keys) {
        try std.io.getStdOut().writer().print("Number of keys in file ({d}) differs from requested number of keys ({d}). Generating new keys.\n", .{ keys_in_file, num_keys });
        return generateKeys(allocator);
    }

    const keys = try allocator.alloc(utils.Sample, num_keys);
    errdefer allocator.free(keys);

    @memcpy(std.mem.sliceAsBytes(keys), file_content);

    try std.io.getStdOut().writer().print("Replaying {d} keys from file {s}\n", .{ num_keys, keys_file });
    return keys;
}

fn generateKeys(allocator: Allocator) ![]utils.Sample {
    const num_keys = opts.num_keys orelse default_num_keys;
    const s = opts.zipf orelse default_zipf;

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

    try std.io.getStdOut().writer().print("Generated {d} keys with Zipfian distribution (s={d:.2})\n", .{ keys.len, s });
    return keys;
}

fn saveKeys(keys: []const utils.Sample) !void {
    const file = try std.fs.cwd().createFile(keys_file, .{});
    defer file.close();

    var gzip_stream = try std.compress.gzip.compressor(file.writer(), .{});
    try gzip_stream.writer().writeAll(std.mem.sliceAsBytes(keys));
    try gzip_stream.finish();

    try std.io.getStdOut().writer().print("Generated keys have been saved to file {s}\n", .{keys_file});
}

pub fn runDefault(allocator: Allocator, keys: []utils.Sample) !void {
    const cache_sizes = comptime generateCacheSizes();
    var results: [cache_sizes.len]ReplayBenchmarkResult = undefined;

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

    const execution_mode = comptime if (getExecutionMode()) "multi" else "single";
    try utils.generateCSVs(execution_mode, &results);

    // Clear the line and create some space
    const stdout = std.io.getStdOut().writer();
    try stdout.print("\r{s}\r", .{" " ** 150});
    try stdout.print("\rBenchmark results have been written to CSV files\n", .{});
}

pub fn runCustom(allocator: Allocator, keys: []utils.Sample) !void {
    const config = comptime getConfig(opts.cache_size orelse default_cache_size);
    const benchmark = try runBenchmark(config, allocator, keys);
    defer allocator.free(benchmark);

    const stdout = std.io.getStdOut().writer();
    try stdout.print("\r{s}\r", .{" " ** 150});

    try utils.printResults(allocator, benchmark);
}

/// Generate cache sizes based on the configuration.
pub fn generateCacheSizes() []u32 {
    // The format is "count:step" where count is the number of cache sizes to generate
    // and step is the increment value for each consecutive cache size.
    const str = opts.auto orelse default_auto_sizes;

    var iter = std.mem.splitScalar(u8, str, ':');
    const count = std.fmt.parseUnsigned(u32, iter.next().?, 10) catch @compileError("Invalid count value");
    const step = std.fmt.parseUnsigned(u32, iter.next().?, 10) catch @compileError("Invalid step value");

    var sizes: [count]u32 = undefined;
    for (0..count) |i| {
        sizes[i] = (i + 1) * step;
    }

    return &sizes;
}

fn runBenchmark(comptime config: utils.Config, allocator: Allocator, keys: []utils.Sample) ![]BenchmarkResult {
    const policies = std.meta.fields(PolicyOptions);
    const num_policies = if (config.policy) |_| 1 else policies.len;

    var results = try allocator.alloc(BenchmarkResult, num_policies);
    errdefer allocator.free(results);

    try printBenchmarkHeader(config, keys.len);
    inline for (0..num_policies) |i| {
        const policy_name = if (config.policy) |p| p else policies[i].name;
        const policy_config = @unionInit(PolicyOptions, policy_name, .{});
        results[i] = try Benchmark(config, policy_config).bench(allocator, keys);
    }

    return results;
}

fn printBenchmarkHeader(comptime config: utils.Config, num_keys: usize) !void {
    const stdout = std.io.getStdOut().writer();

    // Clear the line and create some space
    try stdout.print("\r{s}\r", .{" " ** 150});

    // Print common configuration
    try stdout.print("{s}: ", .{config.execution_mode.format()});
    switch (config.stop_condition) {
        .duration => |ms| try stdout.print("duration={d:.2}s ", .{@as(f64, @floatFromInt(ms)) / 1000}),
        .operations => |ops| try stdout.print("operations={d} ", .{ops}),
    }

    try stdout.print("zipf={d:.2} keys={d} cache-size={d} pool-size={d}", .{
        opts.zipf orelse default_zipf,
        num_keys,
        config.cache_size,
        config.pool_size orelse config.cache_size,
    });

    // Print multi-threaded specific configuration
    if (config.execution_mode == .multi) {
        try stdout.print(" shards={d} threads={d}", .{ config.shard_count, config.num_threads });
    }

    try stdout.writeByte('\n');
}

fn getConfig(cache_size: u32) utils.Config {
    const mode = getExecutionMode();
    const condition = getStopCondition();
    return .{
        .execution_mode = mode,
        .stop_condition = condition,
        .policy = opts.policy,
        .cache_size = cache_size,
        .pool_size = opts.pool_size,
        .shard_count = opts.shard_count orelse default_shard_count,
        .num_threads = opts.num_threads orelse default_num_threads,
        .zipf = opts.zipf orelse default_zipf,
    };
}

/// Determine the execution mode based on the configuration
fn getExecutionMode() utils.ExecutionMode {
    return if (opts.num_threads orelse default_num_threads > 1)
        .multi
    else
        .single;
}

/// Determine the stop condition based on the configuration
fn getStopCondition() utils.StopCondition {
    return if (opts.duration_ms) |ms|
        .{ .duration = ms }
    else if (opts.max_ops) |ops|
        .{ .operations = ops }
    else
        .{ .duration = default_duration_ms };
}

// Ensure that the zipfian module is included in the build for tests
comptime {
    _ = @import("Zipfian.zig");
}
