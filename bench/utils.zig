const std = @import("std");
const zigache = @import("zigache");

const Zipfian = @import("Zipfian.zig");
const EvictionPolicy = zigache.Config.EvictionPolicy;

pub const Mode = enum {
    single,
    multi,
    both,
};

pub const RunConfig = struct {
    mode: Mode = .single,
    cache_size: u32 = 10_000,
    base_size: ?u32 = null,
    shard_count: u16 = 1,
    num_keys: u32 = 1_000_000,
    num_threads: u8 = 1,
    zipf: f64 = 0.7,
    duration_ms: u64 = 60_000,
};

pub const Sample = struct {
    key: []const u8,
    value: u64,
};

pub const BenchmarkResult = struct {
    policy: EvictionPolicy,
    total_ops: u32,
    ns_per_op: f64,
    ops_per_second: f64,
    hit_rate: f64,
    hits: u32,
    misses: u32,
    memory_mb: f64,

    pub fn format(self: BenchmarkResult, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}|{d}|{d:.2}|{d:.2}|{d:.2}|{d}|{d}|{d:.2}", .{
            @tagName(self.policy),
            self.total_ops,
            self.ns_per_op,
            self.ops_per_second,
            self.hit_rate * 100, // Convert to percentage
            self.hits,
            self.misses,
            self.memory_mb,
        });
    }
};

pub fn generateKeys(allocator: std.mem.Allocator, num_keys: u32, s: f64) ![]Sample {
    var prng = std.rand.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const rand = prng.random();

    var zipf_distribution = try Zipfian.init(allocator, num_keys, s);
    defer zipf_distribution.deinit(allocator);

    const keys = try allocator.alloc(Sample, num_keys);
    errdefer allocator.free(keys);

    for (keys) |*sample| {
        const value = zipf_distribution.next(rand);
        sample.key = try std.fmt.allocPrint(allocator, "{d}", .{value});
        sample.value = value;
    }

    return keys;
}

pub fn parseResults(
    policy: EvictionPolicy,
    run_time: u64,
    bytes: usize,
    hits: u32,
    misses: u32,
) BenchmarkResult {
    const total_ops = hits + misses;
    const hit_rate = @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(total_ops));
    const ns_per_op = @as(f64, @floatFromInt(run_time)) / @as(f64, @floatFromInt(total_ops));
    const ops_per_second = @as(f64, @floatFromInt(total_ops)) / (@as(f64, @floatFromInt(run_time)) / @as(f64, @floatFromInt(std.time.ns_per_s)));

    return .{
        .policy = policy,
        .total_ops = total_ops,
        .ns_per_op = ns_per_op,
        .ops_per_second = ops_per_second,
        .hit_rate = hit_rate,
        .hits = hits,
        .misses = misses,
        .memory_mb = @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(1024 * 1024)),
    };
}

pub fn printResults(allocator: std.mem.Allocator, results: []const BenchmarkResult) !void {
    const headers = [_][]const u8{ "Name", "Total Ops", "ns/op", "ops/s", "Hit Rate (%)", "Hits", "Misses", "Memory (MB)" };

    var col_widths: [headers.len]usize = undefined;
    for (headers, 0..) |header, i| {
        col_widths[i] = header.len;
        for (results) |result| {
            const formatted = try result.format(allocator);
            defer allocator.free(formatted);

            var iter = std.mem.split(u8, formatted, "|");
            var j: usize = 0;
            while (iter.next()) |field| : (j += 1) {
                if (j == i and field.len > col_widths[i]) {
                    col_widths[i] = field.len;
                }
            }
        }
    }

    const stdout = std.io.getStdOut().writer();

    try printSeparator(stdout, &col_widths);
    try printRow(stdout, &headers, &col_widths);
    try printSeparator(stdout, &col_widths);

    for (results) |result| {
        const formatted = try result.format(allocator);
        defer allocator.free(formatted);

        var fields: [headers.len][]const u8 = undefined;
        var iter = std.mem.split(u8, formatted, "|");
        var i: usize = 0;
        while (iter.next()) |field| : (i += 1) {
            if (i >= headers.len) break; // Ensure we don't exceed the number of headers
            fields[i] = field;
        }
        try printRow(stdout, &fields, &col_widths);
    }

    try printSeparator(stdout, &col_widths);
}

fn printSeparator(writer: anytype, widths: []const usize) !void {
    for (widths, 0..) |width, i| {
        if (i == 0) {
            try writer.writeByteNTimes('-', width + 1);
        } else {
            try writer.writeAll("+");
            try writer.writeByteNTimes('-', width + 2);
        }
    }
    try writer.writeAll("\n");
}

fn printRow(writer: anytype, fields: []const []const u8, widths: []const usize) !void {
    for (fields, 0..) |field, i| {
        if (i > 0) try writer.writeAll("| ");
        try writer.print("{s}", .{field});
        try writer.writeByteNTimes(' ', widths[i] - field.len + 1);
    }
    try writer.writeAll("\n");
}
