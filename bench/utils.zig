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
    results: IntermediateResults,
    memory_mb: f64,

    pub fn format(self: BenchmarkResult, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}|{d}|{d:.2}|{d:.2}|{d:.2}|{d:.2}|{d:.2}|{d}|{d}|{d:.2}", .{
            @tagName(self.policy),
            self.results.total_ops,
            self.results.ops_per_second,
            self.results.ns_per_op,
            self.results.avg_get_time,
            self.results.avg_put_time,
            self.results.hit_rate,
            self.results.total_hits,
            self.results.total_misses,
            self.memory_mb,
        });
    }
};

pub const IntermediateResults = struct {
    total_ops: u64 = 0,
    total_get_time: u64 = 0,
    total_set_time: u64 = 0,
    total_hits: u64 = 0,
    total_misses: u64 = 0,
    hit_rate: f64 = 0,
    ops_per_second: f64 = 0,
    ns_per_op: f64 = 0,
    avg_get_time: f64 = 0,
    avg_put_time: f64 = 0,
    progress: f64 = 0,
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
    const fields = std.meta.fields(ReplayBenchmarkResult);
    for (results) |result| {
        try writer.print("{}", .{result.cache_size});
        inline for (1..fields.len) |i| {
            const bench_results = @field(result, fields[i].name).results;
            const value = switch (metric) {
                .ns_per_op => bench_results.ns_per_op,
                .hit_rate => bench_results.hit_rate,
                .ops_per_second => bench_results.ops_per_second,
            };
            try writer.print(",{d:.2}", .{value});
        }
        try writer.writeByte('\n');
    }
}

pub fn parseResults(policy: PolicyConfig, results: IntermediateResults, bytes: usize) BenchmarkResult {
    return .{
        .policy = policy,
        .results = results,
        .memory_mb = @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(1024 * 1024)),
    };
}

pub fn printResults(allocator: std.mem.Allocator, results: []const BenchmarkResult) !void {
    const headers = [_][]const u8{ "Name", "Total Ops", "ops/s", "ns/op", "Avg Get (ns)", "Avg Set (ns)", "Hit Rate (%)", "Hits", "Misses", "Memory (MB)" };

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
