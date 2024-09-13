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

pub fn Benchmark(comptime config: Config) type {
    return struct {
        allocator: Allocator,

        const Self = @This();

        pub fn init(allocator: Allocator) !Self {
            return .{ .allocator = allocator };
        }

        pub fn run(self: *Self) !void {
            // Generate keys for the benchmark
            const keys = try self.generateKeys(config.num_keys, config.zipf);
            defer self.allocator.free(keys);

            // Run benchmarks based on the execution mode
            switch (config.execution_mode) {
                .single => {
                    try printBenchmarkHeader("Single Threaded");
                    try self.runBenchmarks(single_threaded.SingleThreaded, keys);
                },
                .multi => {
                    try printBenchmarkHeader("Multi Threaded");
                    try self.runBenchmarks(multi_threaded.MultiThreaded, keys);
                },
                .both => {
                    try printBenchmarkHeader("Single Threaded");
                    try self.runBenchmarks(single_threaded.SingleThreaded, keys);

                    try printBenchmarkHeader("Multi Threaded");
                    try self.runBenchmarks(multi_threaded.MultiThreaded, keys);
                },
            }
        }

        fn runBenchmarks(
            self: *Self,
            comptime BenchType: fn (comptime Config, comptime EvictionPolicy) type,
            keys: []const utils.Sample,
        ) !void {
            // Get all eviction policies
            const policies = comptime std.meta.tags(EvictionPolicy);
            var results = try self.allocator.alloc(BenchmarkResult, policies.len);
            defer self.allocator.free(results);

            // Run benchmark for each eviction policy
            inline for (policies, 0..) |policy, i| {
                const Bench = BenchType(config, policy);
                results[i] = try Bench.bench(self.allocator, keys);
            }

            // Print results
            try std.io.getStdOut().writer().print("\r", .{});
            try utils.printResults(self.allocator, results);
        }

        fn generateKeys(self: *Self, num_keys: u32, s: f64) ![]utils.Sample {
            var zipf_distribution = try Zipfian.init(num_keys, s);
            var prng = std.rand.DefaultPrng.init(blk: {
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

        fn printBenchmarkHeader(mode: []const u8) !void {
            const stdout = std.io.getStdOut().writer();
            try stdout.print("{s}: ", .{mode});

            switch (config.stop_condition) {
                .duration => |ms| try stdout.print("duration={d:.2}s ", .{@as(f64, @floatFromInt(ms)) / 1000}),
                .operations => |ops| try stdout.print("operations={d} ", .{ops}),
            }
            try stdout.print("keys={d} cache-size={d}", .{ config.num_keys, config.cache_size });
            if (config.execution_mode == .multi) {
                try stdout.print(" shards={d} threads={d}", .{ config.shard_count, config.num_threads });
            }

            try stdout.print("\n", .{});
        }
    };
}
