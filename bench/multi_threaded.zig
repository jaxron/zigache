const std = @import("std");
const zigache = @import("zigache");
const utils = @import("utils.zig");

const PolicyConfig = zigache.Config.PolicyConfig;
const BenchmarkResult = utils.BenchmarkResult;
const Config = utils.Config;

pub fn MultiThreaded(comptime opts: Config, comptime policy: PolicyConfig) type {
    return struct {
        const Cache = zigache.Cache(u64, u64, .{
            .cache_size = opts.cache_size,
            .pool_size = opts.pool_size,
            .shard_count = opts.shard_count,
            .policy = policy,
            .thread_safety = true,
        });

        const ThreadContext = struct {
            cache: *Cache,
            keys: []const utils.Sample,
            run_time: u64 = 0,
            hits: u64 = 0,
            misses: u64 = 0,
            progress: usize = 0,
        };

        pub fn bench(allocator: std.mem.Allocator, keys: []const utils.Sample) !BenchmarkResult {
            var gpa: std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = true }) = .init;
            defer _ = gpa.deinit();
            const local_allocator = gpa.allocator();

            const stdout = std.io.getStdOut().writer();

            // Initialize the cache
            var cache: Cache = try .init(local_allocator);
            defer cache.deinit();

            // Initialize thread contexts
            var contexts = try initThreadContexts(allocator, keys, &cache);
            defer allocator.free(contexts);

            // Create threads
            const threads = try allocator.alloc(std.Thread, opts.num_threads);
            defer allocator.free(threads);

            // Spawn threads and start benchmarking
            for (threads, 0..) |*thread, i| {
                thread.* = try std.Thread.spawn(.{}, runThreadBenchmark(), .{&contexts[i]});
            }
            try monitorProgress(stdout, &contexts);

            for (threads) |thread| {
                thread.join();
            }

            // Aggregate and return results
            return aggregateResults(contexts, &gpa.total_requested_bytes);
        }

        fn initThreadContexts(allocator: std.mem.Allocator, keys: []const utils.Sample, cache: *Cache) ![]ThreadContext {
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

        fn runThreadBenchmark() fn (*ThreadContext) void {
            return struct {
                fn run(ctx: *ThreadContext) void {
                    var timer = std.time.Timer.start() catch {
                        std.debug.print("Failed to start timer\n", .{});
                        return;
                    };

                    var i: usize = 0;
                    while (true) : (i += 1) {
                        switch (opts.stop_condition) {
                            .duration => |ms| if (ctx.run_time >= ms * std.time.ns_per_ms) break,
                            .operations => |max_ops| if (ctx.hits + ctx.misses >= max_ops / opts.num_threads) break,
                        }

                        const data = ctx.keys[i % ctx.keys.len];
                        const op_start_time = timer.read();

                        if (ctx.cache.get(data.key)) |_| {
                            ctx.hits += 1;
                        } else {
                            ctx.cache.set(data.key, data.value) catch return;
                            ctx.misses += 1;
                        }

                        const op_time = timer.read() - op_start_time;
                        ctx.run_time += op_time;
                    }
                }
            }.run;
        }

        fn monitorProgress(stdout: std.fs.File.Writer, contexts: *[]ThreadContext) !void {
            while (true) {
                var total_ops: u64 = 0;
                var total_run_time: u64 = 0;
                var total_hits: u64 = 0;
                var total_misses: u64 = 0;

                for (contexts.*) |ctx| {
                    total_ops += ctx.hits + ctx.misses;
                    total_run_time += ctx.run_time;
                    total_hits += ctx.hits;
                    total_misses += ctx.misses;
                }

                switch (opts.stop_condition) {
                    .duration => |ms| if (total_run_time >= ms * opts.num_threads * std.time.ns_per_ms) break,
                    .operations => |max_ops| if (total_ops >= max_ops) break,
                }

                const hit_rate = @as(f64, @floatFromInt(total_hits)) / @as(f64, @floatFromInt(total_ops)) * 100.0;
                const ops_per_second = @as(f64, @floatFromInt(total_ops)) * std.time.ns_per_s / @as(f64, @floatFromInt(total_run_time));
                const ns_per_op = @as(f64, @floatFromInt(total_run_time)) / @as(f64, @floatFromInt(total_ops));

                const progress = switch (opts.stop_condition) {
                    .duration => |ms| @as(f64, @floatFromInt(total_run_time)) / @as(f64, @floatFromInt(ms * opts.num_threads * std.time.ns_per_ms)) * 100.0,
                    .operations => |max_ops| @as(f64, @floatFromInt(total_ops)) / @as(f64, @floatFromInt(max_ops)) * 100.0,
                };

                try stdout.print("\r{s} | {d:>6.2}% | Hit Rate: {d:>5.2}% | Ops/s: {d:>9.2} | ns/op: {d:>7.2}{s}", .{
                    @tagName(policy),
                    progress,
                    hit_rate,
                    ops_per_second,
                    ns_per_op,
                    " " ** 20, // Padding to ensure clean overwrite
                });

                std.time.sleep(10 * std.time.ns_per_ms);
            }
        }

        fn aggregateResults(contexts: []const ThreadContext, bytes: *usize) !BenchmarkResult {
            var total_run_time: u64 = 0;
            var total_hits: u64 = 0;
            var total_misses: u64 = 0;
            for (contexts) |ctx| {
                total_run_time += ctx.run_time;
                total_hits += ctx.hits;
                total_misses += ctx.misses;
            }

            return utils.parseResults(policy, total_run_time, bytes.*, total_hits, total_misses);
        }
    };
}
