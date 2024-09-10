const std = @import("std");
const zigache = @import("zigache");
const utils = @import("utils.zig");

const EvictionPolicy = zigache.Config.EvictionPolicy;
const BenchmarkResult = utils.BenchmarkResult;
const RunConfig = utils.RunConfig;

pub fn benchSingle(_: std.mem.Allocator, opts: RunConfig, keys: []const utils.Sample, policy: EvictionPolicy) !BenchmarkResult {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .enable_memory_limit = true,
    }){};
    defer _ = gpa.deinit();
    const local_allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    var cache = try zigache.Cache([]const u8, u64).init(local_allocator, .{
        .total_size = opts.cache_size,
        .base_size = opts.base_size,
        .shard_count = opts.shard_count,
        .policy = policy,
    });
    defer cache.deinit();

    var run_time: u64 = 0;
    var hits: u32 = 0;
    var misses: u32 = 0;
    var operations: usize = 0;

    const progress_interval = 1000; // Update progress every 1000 operations
    try stdout.print("\r{s} Progress: 0.00% complete | Hits: 0 | Misses: 0", .{@tagName(policy)});

    var timer = try std.time.Timer.start();
    const start_time = timer.read();

    while (timer.read() - start_time < opts.duration_ms * std.time.ns_per_ms) {
        const data = keys[operations % keys.len];
        const op_timer_start = timer.read();

        if (cache.get(data.key)) |_| {
            hits += 1;
        } else {
            try cache.set(data.key, data.value);
            misses += 1;
        }

        const op_time = timer.read() - op_timer_start;
        run_time += op_time;
        operations += 1;

        if (operations % progress_interval == 0) {
            const elapsed_ms = (timer.read() - start_time) / std.time.ns_per_ms;
            const progress_percent = @as(f64, @floatFromInt(elapsed_ms)) / @as(f64, @floatFromInt(opts.duration_ms)) * 100;
            try stdout.print("\r{s} - {d:.2}% complete | Hits: {d} | Misses: {d}", .{
                @tagName(policy),
                progress_percent,
                hits,
                misses,
            });
        }
    }

    const result = utils.parseResults(policy, run_time, gpa.total_requested_bytes, hits, misses);
    return result;
}
