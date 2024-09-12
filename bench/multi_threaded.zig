const std = @import("std");
const zigache = @import("zigache");
const utils = @import("utils.zig");

const EvictionPolicy = zigache.Config.EvictionPolicy;
const BenchmarkResult = utils.BenchmarkResult;
const Config = utils.Config;

pub fn MultiThreaded(comptime opts: Config, comptime policy: EvictionPolicy) type {
    return struct {
        const Cache = zigache.Cache([]const u8, u64, .{
            .total_size = opts.cache_size,
            .base_size = opts.base_size,
            .shard_count = opts.shard_count,
            .policy = policy,
            .thread_safe = true,
        });

        const ThreadContext = struct {
            cache: *Cache,
            keys: []const utils.Sample,
            run_time: u64 = 0,
            hits: u32 = 0,
            misses: u32 = 0,
            samples: []u64,
            progress: usize = 0,
            should_stop: *bool,
        };

        pub fn bench(allocator: std.mem.Allocator, keys: []const utils.Sample) !BenchmarkResult {
            var gpa = std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = true }){};
            defer _ = gpa.deinit();
            const local_allocator = gpa.allocator();

            const stdout = std.io.getStdOut().writer();

            // Initialize the cache
            var cache = try Cache.init(local_allocator);
            defer cache.deinit();

            // Initialize thread contexts
            var contexts = try initThreadContexts(allocator, keys, &cache);
            defer {
                for (contexts) |ctx| {
                    allocator.free(ctx.samples);
                }
                allocator.free(contexts);
            }

            // Create threads
            const threads = try allocator.alloc(std.Thread, opts.num_threads);
            defer allocator.free(threads);

            var should_stop = false;
            var timer = try std.time.Timer.start();
            const start_time = timer.read();

            // Set up stop condition for all threads
            for (contexts) |*ctx| {
                ctx.should_stop = &should_stop;
            }

            // Spawn threads and start benchmarking
            for (threads, 0..) |*thread, i| {
                thread.* = try std.Thread.spawn(.{}, runThreadBenchmark(), .{&contexts[i]});
            }
            try monitorProgress(stdout, &contexts, start_time, &should_stop, &timer);

            for (threads) |thread| {
                thread.join();
            }

            // Aggregate and return results
            return aggregateResults(stdout, contexts, &gpa.total_requested_bytes);
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
                    .samples = try allocator.alloc(u64, end - start),
                    .progress = 0,
                    .should_stop = undefined,
                };
            }

            return contexts;
        }

        fn runThreadBenchmark() fn (*ThreadContext) void {
            return struct {
                fn run(ctx: *ThreadContext) void {
                    var timer = std.time.Timer.start() catch return;
                    var i: usize = 0;

                    while (!ctx.should_stop.*) {
                        const data = ctx.keys[i % ctx.keys.len];
                        timer.reset();

                        if (ctx.cache.get(data.key)) |_| {
                            ctx.hits += 1;
                        } else {
                            ctx.cache.set(data.key, data.value) catch return;
                            ctx.misses += 1;
                        }

                        ctx.samples[i % ctx.samples.len] = timer.read();
                        ctx.run_time += ctx.samples[i % ctx.samples.len];
                        ctx.progress += 1;
                        i += 1;
                    }
                }
            }.run;
        }

        fn monitorProgress(
            stdout: std.fs.File.Writer,
            contexts: *[]ThreadContext,
            start_time: u64,
            should_stop: *bool,
            timer: *std.time.Timer,
        ) !void {
            const progress_interval = 1000;
            var last_progress_update: usize = 0;

            while (timer.read() - start_time < opts.duration_ms * std.time.ns_per_ms) {
                var total_progress: usize = 0;
                for (contexts.*) |ctx| {
                    total_progress += ctx.progress;
                }

                if (total_progress >= last_progress_update + progress_interval) {
                    try printProgress(stdout, contexts, start_time, timer);
                    last_progress_update = total_progress;
                }

                std.time.sleep(10 * std.time.ns_per_ms);
            }

            should_stop.* = true;
        }

        fn printProgress(
            stdout: std.fs.File.Writer,
            contexts: *[]ThreadContext,
            start_time: u64,
            timer: *std.time.Timer,
        ) !void {
            var total_hits: u32 = 0;
            var total_misses: u32 = 0;
            for (contexts.*) |ctx| {
                total_hits += ctx.hits;
                total_misses += ctx.misses;
            }

            const elapsed_ms = (timer.read() - start_time) / std.time.ns_per_ms;
            const progress_percent = @as(f64, @floatFromInt(elapsed_ms)) / @as(f64, @floatFromInt(opts.duration_ms)) * 100;
            try stdout.print("\r{s} - {d:.2}% complete | Hits: {d} | Misses: {d}", .{
                @tagName(policy),
                progress_percent,
                total_hits,
                total_misses,
            });
        }

        fn aggregateResults(
            stdout: std.fs.File.Writer,
            contexts: []const ThreadContext,
            bytes: *usize,
        ) !BenchmarkResult {
            var total_run_time: u64 = 0;
            var total_hits: u32 = 0;
            var total_misses: u32 = 0;

            for (contexts) |ctx| {
                total_run_time += ctx.run_time;
                total_hits += ctx.hits;
                total_misses += ctx.misses;
            }

            try stdout.print("\r{s} completed", .{@tagName(policy)});

            return utils.parseResults(policy, total_run_time, bytes.*, total_hits, total_misses);
        }
    };
}
