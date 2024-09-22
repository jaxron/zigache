const std = @import("std");
const zigache = @import("zigache");
const utils = @import("utils.zig");

const PolicyConfig = zigache.RuntimeConfig.PolicyConfig;
const BenchmarkResult = utils.BenchmarkResult;
const IntermediateResults = utils.IntermediateResults;
const Config = utils.Config;

pub fn Benchmark(comptime opts: Config, comptime policy: PolicyConfig) type {
    return struct {
        const Cache = zigache.Cache(u64, u64, .{
            .thread_safety = opts.execution_mode == .multi,
            .ttl_enabled = false,
        });

        const ThreadContext = struct {
            cache: *Cache,
            keys: []utils.Sample,
            get_time: u64 = 0,
            set_time: u64 = 0,
            hits: u64 = 0,
            misses: u64 = 0,
        };

        pub fn bench(allocator: std.mem.Allocator, keys: []utils.Sample) !BenchmarkResult {
            var gpa: std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = true }) = .init;
            defer _ = gpa.deinit();
            const local_allocator = gpa.allocator();

            // Initialize the cache
            var cache: Cache = try .init(local_allocator, .{
                .cache_size = opts.cache_size,
                .pool_size = opts.pool_size,
                .shard_count = if (opts.execution_mode == .multi) opts.shard_count else 1,
                .policy = policy,
            });
            defer cache.deinit();

            // Initialize thread contexts
            var contexts = try initThreadContexts(allocator, keys, &cache);
            defer allocator.free(contexts);

            // Create threads
            const threads = try allocator.alloc(std.Thread, opts.num_threads);
            defer allocator.free(threads);

            // Spawn threads and start benchmarking
            for (threads, 0..) |*thread, i| {
                thread.* = try std.Thread.spawn(.{}, runThreadBenchmark, .{&contexts[i]});
            }

            // Stop and monitor progress of threads
            try monitorProgress(std.io.getStdOut().writer(), &contexts);
            for (threads) |thread| {
                thread.join();
            }

            // Aggregate and return results
            const results = aggregateResults(contexts);
            return utils.parseResults(policy, results, gpa.total_requested_bytes);
        }

        fn initThreadContexts(allocator: std.mem.Allocator, keys: []utils.Sample, cache: *Cache) ![]ThreadContext {
            const contexts = try allocator.alloc(ThreadContext, opts.num_threads);
            errdefer allocator.free(contexts);

            const keys_per_thread = keys.len / opts.num_threads;
            for (contexts, 0..) |*ctx, i| {
                const start = i * keys_per_thread;
                const end = if (i == opts.num_threads - 1) keys.len else (i + 1) * keys_per_thread;
                ctx.* = .{
                    .cache = cache,
                    .keys = keys[start..end],
                };
            }

            return contexts;
        }

        fn runThreadBenchmark(ctx: *ThreadContext) void {
            var timer = std.time.Timer.start() catch @panic("Failed to start timer");

            var i: usize = 0;
            while (true) : (i += 1) {
                // Stop benchmarking if the stop condition is met
                if (switch (opts.stop_condition) {
                    .duration => |ms| (ctx.get_time + ctx.set_time) >= ms * std.time.ns_per_ms,
                    .operations => |max_ops| ctx.hits + ctx.misses >= max_ops / opts.num_threads,
                }) break;

                // Perform cache operation
                const data = ctx.keys[i % ctx.keys.len];
                const key = data.key;
                const value = data.value;

                timer.reset();
                if (ctx.cache.get(key)) |_| {
                    ctx.get_time += timer.lap();
                    ctx.hits += 1;
                } else {
                    ctx.get_time += timer.lap();
                    ctx.cache.put(key, value) catch @panic("Failed to set key");
                    ctx.set_time += timer.lap();
                    ctx.misses += 1;
                }
            }
        }

        fn monitorProgress(stdout: std.fs.File.Writer, contexts: *[]ThreadContext) !void {
            while (true) {
                const results = aggregateResults(contexts.*);
                if (results.progress >= 1.0) break;

                try printProgress(stdout, results);
                std.time.sleep(10 * std.time.ns_per_ms);
            }
        }

        fn aggregateResults(contexts: []ThreadContext) IntermediateResults {
            var results = IntermediateResults{};
            for (contexts) |ctx| {
                results.total_ops += ctx.hits + ctx.misses;
                results.total_get_time += ctx.get_time;
                results.total_set_time += ctx.set_time;
                results.total_hits += ctx.hits;
                results.total_misses += ctx.misses;
            }

            const total_time = results.total_get_time + results.total_set_time;
            results.hit_rate = @as(f64, @floatFromInt(results.total_hits)) / @as(f64, @floatFromInt(results.total_ops)) * 100.0;
            results.ops_per_second = @as(f64, @floatFromInt(results.total_ops)) * std.time.ns_per_s / @as(f64, @floatFromInt(total_time));
            results.ns_per_op = @as(f64, @floatFromInt(total_time)) / @as(f64, @floatFromInt(results.total_ops));
            results.avg_get_time = @as(f64, @floatFromInt(results.total_get_time)) / @as(f64, @floatFromInt(results.total_ops));
            results.avg_put_time = @as(f64, @floatFromInt(results.total_set_time)) / @as(f64, @floatFromInt(results.total_misses));
            results.progress = switch (opts.stop_condition) {
                .duration => |ms| @as(f64, @floatFromInt(total_time)) / @as(f64, @floatFromInt(ms * opts.num_threads * std.time.ns_per_ms)),
                .operations => |max_ops| @as(f64, @floatFromInt(results.total_ops)) / @as(f64, @floatFromInt(max_ops)),
            };

            return results;
        }

        fn printProgress(stdout: std.fs.File.Writer, results: IntermediateResults) !void {
            const bar_width = 30;
            const filled_width = @as(usize, @intFromFloat(results.progress * @as(f64, bar_width)));
            const empty_width = bar_width - filled_width;

            try stdout.print("\r{s}\r", .{" " ** 150});
            try stdout.print("\r\x1b[2K\x1b[1m{s:<6}\x1b[0m [", .{@tagName(policy)}); // Bold policy name, left-aligned, 6-char field
            try stdout.print("\x1b[42m", .{}); // Set background color to green
            try stdout.writeByteNTimes(' ', filled_width);
            try stdout.print("\x1b[0m", .{}); // Reset color
            try stdout.writeByteNTimes(' ', empty_width);
            try stdout.print("] \x1b[1m{d:>5.1}%\x1b[0m | ", .{results.progress * 100}); // Bold percentage, right-aligned, 5-char field, 1 decimal place
            try stdout.print("Hit Rate: {d:>5.2}% | ops/s: {d:>9.2} | ns/op: {d:>7.2} | ", .{
                results.hit_rate,
                results.ops_per_second,
                results.ns_per_op,
            }); // Right-aligned with 2 decimal places
            try stdout.print("Avg Get: {d:>7.2}ns | Avg Put: {d:>7.2}ns", .{
                results.avg_get_time,
                results.avg_put_time,
            }); // Added average get and set times
        }
    };
}
