const std = @import("std");
const zigache = @import("zigache");

const PolicyConfig = zigache.RuntimeConfig.PolicyConfig;

pub const ExecutionMode = enum {
    single,
    multi,

    pub fn format(self: ExecutionMode) []const u8 {
        return switch (self) {
            .single => "Single Threaded",
            .multi => "Multi Threaded",
        };
    }
};

pub const StopCondition = union(enum) {
    duration: u64,
    operations: u64,
};

pub const Config = struct {
    execution_mode: ExecutionMode,
    stop_condition: StopCondition,
    policy: ?[]const u8,
    cache_size: u32,
    pool_size: ?u32,
    shard_count: u16,
    num_threads: u8,
    zipf: f64,
};

pub const Sample = struct {
    key: u64,
    value: u64,
};

pub const BenchmarkResult = struct {
    policy: PolicyConfig,
    total_ops: u64,
    ns_per_op: f64,
    ops_per_second: f64,
    hit_rate: f64,
    hits: u64,
    misses: u64,
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

pub const ReplayBenchmarkResult = struct {
    cache_size: u32,
    fifo: BenchmarkResult,
    lru: BenchmarkResult,
    tinylfu: BenchmarkResult,
    sieve: BenchmarkResult,
    s3fifo: BenchmarkResult,
};

pub const BenchmarkMetric = enum {
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

pub fn generateCSVs(comptime execution_type: []const u8, results: []const ReplayBenchmarkResult) !void {
    try generateCSV("benchmark_nsop_" ++ execution_type ++ ".csv", .ns_per_op, results);
    try generateCSV("benchmark_hitrate_" ++ execution_type ++ ".csv", .hit_rate, results);
    try generateCSV("benchmark_opspersecond_" ++ execution_type ++ ".csv", .ops_per_second, results);
}

pub fn generateCSV(filename: []const u8, metric: BenchmarkMetric, results: []const ReplayBenchmarkResult) !void {
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

pub fn generateCacheSizes() [40]u32 {
    var sizes: [40]u32 = undefined;
    for (0..40) |i| {
        sizes[i] = (i + 1) * 5000;
    }
    return sizes;
}

pub fn parseResults(policy: PolicyConfig, run_time: u64, bytes: usize, hits: u64, misses: u64) BenchmarkResult {
    const total_ops = hits + misses;
    const hit_rate = @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(total_ops));
    const ns_per_op = @as(f64, @floatFromInt(run_time)) / @as(f64, @floatFromInt(total_ops));
    const ops_per_second = @as(f64, @floatFromInt(total_ops)) * std.time.ns_per_s / @as(f64, @floatFromInt(run_time));

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

    var col_widths = [_]usize{0} ** headers.len;
    for (headers, 0..) |header, i| {
        col_widths[i] = header.len;
        for (results) |result| {
            const formatted = try result.format(allocator);
            defer allocator.free(formatted);

            var iter = std.mem.splitSequence(u8, formatted, "|");
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
        var iter = std.mem.splitSequence(u8, formatted, "|");
        for (&fields) |*field| {
            field.* = iter.next() orelse break;
        }
        try printRow(stdout, &fields, &col_widths);
    }

    try printSeparator(stdout, &col_widths);
}

fn printSeparator(writer: anytype, widths: []const usize) !void {
    for (widths) |width| {
        try writer.writeAll("+");
        try writer.writeByteNTimes('-', width + 2);
    }
    try writer.writeAll("+\n");
}

fn printRow(writer: anytype, fields: []const []const u8, widths: []const usize) !void {
    for (fields, widths) |field, width| {
        if (@intFromPtr(field.ptr) != @intFromPtr(fields.ptr)) try writer.writeAll("| ");
        try writer.print("{s}", .{field});
        try writer.writeByteNTimes(' ', width - field.len + 1);
    }
    try writer.writeAll("|\n");
}

pub fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch {
        return false;
    };
    return true;
}
