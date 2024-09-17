const std = @import("std");
const zigache = @import("zigache");
const utils = @import("utils.zig");
const single_threaded = @import("single_threaded.zig");
const multi_threaded = @import("multi_threaded.zig");

const Zipfian = @import("Zipfian.zig");
const Allocator = std.mem.Allocator;
const EvictionPolicy = zigache.Config.EvictionPolicy;
const BenchmarkResult = utils.BenchmarkResult;
const Config = utils.Config;
const ExecutionMode = utils.ExecutionMode;

pub const TraceBenchmarkResult = struct {
    cache_size: u32,
    fifo: BenchmarkResult,
    lru: BenchmarkResult,
    tinylfu: BenchmarkResult,
    sieve: BenchmarkResult,
    s3fifo: BenchmarkResult,
};

pub fn Benchmark(comptime config: Config) type {
    return struct {
        allocator: Allocator,

        const Self = @This();

        pub fn init(allocator: Allocator) !Self {
            return .{ .allocator = allocator };
        }

        pub fn runNormal(self: *Self) !void {
            // Generate keys for the benchmark
            const keys = try self.generateKeys(config.num_keys, config.zipf);
            defer self.allocator.free(keys);

            // Run benchmarks based on the execution mode
            if (config.execution_mode == .single or config.execution_mode == .both) {
                try printBenchmarkHeader(false);
                try self.runNormalBenchmarks(single_threaded.SingleThreaded, keys);
            }

            if (config.execution_mode == .multi or config.execution_mode == .both) {
                try printBenchmarkHeader(true);
                try self.runNormalBenchmarks(multi_threaded.MultiThreaded, keys);
            }
        }

        fn runNormalBenchmarks(self: *Self, comptime BenchType: fn (comptime Config, comptime EvictionPolicy) type, keys: []const utils.Sample) !void {
            // Get all eviction policies
            const policies = comptime std.meta.tags(EvictionPolicy);
            var results = try self.allocator.alloc(BenchmarkResult, policies.len);
            defer self.allocator.free(results);

            // Run benchmark for each eviction policy
            inline for (policies, 0..) |policy, i| {
                results[i] = try BenchType(config, policy).bench(self.allocator, keys);
            }

            // Print results
            try std.io.getStdOut().writer().print("\r", .{});
            try utils.printResults(self.allocator, results);
        }

        pub fn runTrace(self: *Self) !TraceBenchmarkResult {
            const keys = try self.generateKeys(config.num_keys, config.zipf);
            defer self.allocator.free(keys);

            if (config.execution_mode == .single) {
                try printBenchmarkHeader(false);
                return self.runTraceBenchmarks(single_threaded.SingleThreaded, keys);
            }

            if (config.execution_mode == .multi) {
                try printBenchmarkHeader(true);
                return self.runTraceBenchmarks(multi_threaded.MultiThreaded, keys);
            }

            return error.ExecutionModeNotSpecific;
        }

        fn runTraceBenchmarks(self: *Self, comptime BenchType: fn (comptime Config, comptime EvictionPolicy) type, keys: []const utils.Sample) !TraceBenchmarkResult {
            return .{
                .cache_size = config.cache_size,
                .fifo = try BenchType(config, .FIFO).bench(self.allocator, keys),
                .lru = try BenchType(config, .LRU).bench(self.allocator, keys),
                .tinylfu = try BenchType(config, .TinyLFU).bench(self.allocator, keys),
                .sieve = try BenchType(config, .SIEVE).bench(self.allocator, keys),
                .s3fifo = try BenchType(config, .S3FIFO).bench(self.allocator, keys),
            };
        }

        fn generateKeys(self: *Self, num_keys: u32, s: f64) ![]utils.Sample {
            var zipf_distribution: Zipfian = try .init(num_keys, s);
            var prng: std.Random.DefaultPrng = .init(blk: {
                var seed: u64 = undefined;
                try std.posix.getrandom(std.mem.asBytes(&seed));
                break :blk seed;
            });
            const rand = prng.random();

            const keys = try self.allocator.alloc(utils.Sample, num_keys);
            errdefer self.allocator.free(keys);

            for (keys) |*sample| {
                const value = zipf_distribution.next(rand);
                sample.key = value;
                sample.value = value;
            }

            return keys;
        }

        fn printBenchmarkHeader(is_multi: bool) !void {
            const stdout = std.io.getStdOut().writer();

            // Print required configuration
            try stdout.print("\r{s}: ", .{if (is_multi) "Multi Threaded" else "Single Threaded"});
            switch (config.stop_condition) {
                .duration => |ms| try stdout.print("duration={d:.2}s ", .{@as(f64, @floatFromInt(ms)) / 1000}),
                .operations => |ops| try stdout.print("operations={d} ", .{ops}),
            }
            try stdout.print("keys={d} cache-size={d} pool-size={d} zipf={d:.2}", .{ config.num_keys, config.cache_size, config.pool_size orelse config.cache_size, config.zipf });

            // Print additional configuration for multi-threaded benchmarks
            if (is_multi) {
                try stdout.print(" shards={d} threads={d}", .{ config.shard_count, config.num_threads });
            }

            try stdout.print("{s}\n", .{" " ** 10}); // Padding to ensure clean overwrite
        }
    };
}
