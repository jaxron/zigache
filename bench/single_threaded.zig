const std = @import("std");
const zigache = @import("zigache");
const utils = @import("utils.zig");
const EvictionPolicy = zigache.Config.EvictionPolicy;
const BenchmarkResult = utils.BenchmarkResult;
const Config = utils.Config;

pub fn SingleThreaded(comptime opts: Config, comptime policy: EvictionPolicy) type {
    return struct {
        pub fn bench(_: std.mem.Allocator, keys: []const utils.Sample) !BenchmarkResult {
            var gpa = std.heap.GeneralPurposeAllocator(.{
                .enable_memory_limit = true,
            }){};
            defer _ = gpa.deinit();
            const local_allocator = gpa.allocator();
            const stdout = std.io.getStdOut().writer();

            // Initialize the cache with the specified configuration
            var cache = try zigache.Cache(u64, u64, .{
                .total_size = opts.cache_size,
                .base_size = opts.base_size,
                .policy = policy,
                .thread_safe = false,
            }).init(local_allocator);
            defer cache.deinit();

            // Main benchmark loop
            var run_time: u64 = 0;
            var hits: u64 = 0;
            var misses: u64 = 0;

            var timer = try std.time.Timer.start();
            while (true) {
                switch (opts.stop_condition) {
                    .duration => |ms| if (run_time >= ms * std.time.ns_per_ms) break,
                    .operations => |max_ops| if (hits + misses >= max_ops) break,
                }

                const data = keys[(hits + misses) % keys.len];
                const op_start_time = timer.read();

                // Perform cache operation
                if (cache.get(data.key)) |_| {
                    hits += 1;
                } else {
                    try cache.set(data.key, data.value);
                    misses += 1;
                }

                // Update timing and collect sample
                const op_time = timer.read() - op_start_time;
                run_time += op_time;

                // Print progress at regular intervals
                if ((hits + misses) % 1000 == 0) {
                    const progress = switch (opts.stop_condition) {
                        .duration => |ms| blk: {
                            const elapsed_ns = @as(f64, @floatFromInt(run_time));
                            const duration_ns = @as(f64, @floatFromInt(ms)) * std.time.ns_per_ms;
                            break :blk (elapsed_ns / duration_ns) * 100.0;
                        },
                        .operations => |max_ops| @as(f64, @floatFromInt(hits + misses)) / @as(f64, @floatFromInt(max_ops)) * 100.0,
                    };

                    try stdout.print("\r{s} - {d:.2}% complete | Hits: {d} | Misses: {d} | Total Ops: {d}", .{
                        @tagName(policy),
                        progress,
                        hits,
                        misses,
                        hits + misses,
                    });
                }
            }

            // Parse and return benchmark results
            const result = utils.parseResults(policy, run_time, gpa.total_requested_bytes, hits, misses);
            return result;
        }
    };
}
