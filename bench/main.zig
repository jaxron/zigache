const std = @import("std");
const utils = @import("utils.zig");
const benchmark = @import("benchmark.zig");

const Config = utils.RunConfig;
const Mode = utils.Mode;

const Option = struct {
    name: []const u8,
    kind: enum {
        mode,
        cache_size,
        base_size,
        shards,
        keys,
        threads,
        zipf,
        duration,
        help,
    },
};

const options = [_]Option{
    .{ .name = "mode", .kind = .mode },
    .{ .name = "cache-size", .kind = .cache_size },
    .{ .name = "base-size", .kind = .base_size },
    .{ .name = "shards", .kind = .shards },
    .{ .name = "keys", .kind = .keys },
    .{ .name = "threads", .kind = .threads },
    .{ .name = "zipf", .kind = .zipf },
    .{ .name = "duration", .kind = .duration },
    .{ .name = "help", .kind = .help },
};

const ParseResult = enum {
    success,
    help,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config = Config{};
    const result = try parseArgs(args[1..], &config);
    switch (result) {
        .success => try benchmark.run(allocator, config),
        .help => try printHelp(),
    }
}

fn parseArgs(args: []const []const u8, config: *Config) !ParseResult {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!std.mem.startsWith(u8, arg, "--")) {
            std.debug.print("Unknown argument: {s}\n", .{arg});
            return error.UnknownArgument;
        }

        const option_name = arg[2..];
        const option = findOption(option_name) orelse {
            std.debug.print("Unknown option: {s}\n", .{arg});
            return error.UnknownOption;
        };

        i += 1;
        if (i >= args.len) return error.MissingArgumentValue;

        switch (option.kind) {
            .mode => {
                config.mode = std.meta.stringToEnum(Mode, args[i]) orelse return error.InvalidMode;
            },
            .cache_size => config.cache_size = try parseUnsignedArg(u32, args, i),
            .base_size => config.base_size = try parseUnsignedArg(u32, args, i),
            .shards => config.shard_count = try parseUnsignedArg(u16, args, i),
            .keys => config.num_keys = try parseUnsignedArg(u32, args, i),
            .threads => config.num_threads = try parseUnsignedArg(u8, args, i),
            .zipf => config.zipf = try parseFloatArg(args, i),
            .duration => config.duration_ms = try parseUnsignedArg(u64, args, i),
            .help => return .help,
        }
    }
    return .success;
}

fn findOption(name: []const u8) ?Option {
    for (options) |option| {
        if (std.mem.eql(u8, option.name, name)) {
            return option;
        }
    }
    return null;
}

fn parseUnsignedArg(comptime T: type, args: []const []const u8, index: usize) !T {
    return std.fmt.parseUnsigned(T, args[index], 10) catch |err| {
        std.debug.print("Invalid unsigned integer value for {s}: {s}\n", .{ args[index - 1], args[index] });
        return err;
    };
}

fn parseFloatArg(args: []const []const u8, index: usize) !f64 {
    return std.fmt.parseFloat(f64, args[index]) catch |err| {
        std.debug.print("Invalid float value for {s}: {s}\n", .{ args[index - 1], args[index] });
        return err;
    };
}

fn printHelp() !void {
    const help_text =
        \\Usage: benchmark [OPTIONS]
        \\
        \\Options:
        \\  --help                 Print this help message
        \\  --mode VALUE           Set benchmark mode (single, multi, both)
        \\  --cache-size VALUE     Set cache size (default: 10000)
        \\  --base-size VALUE      Set base size (default: same as cache size)
        \\  --shards VALUE         Set shard count (default: 1)
        \\  --keys VALUE           Set number of keys (default: 1000000)
        \\  --threads VALUE        Set number of threads for multi-threaded mode (default: 1)
        \\  --duration VALUE       Set duration in milliseconds (default: 60000)
        \\  --zipf VALUE           Set Zipfian distribution parameter (default: 0.7)
        \\
        \\Examples:
        \\  zigache-benchmark --mode multi --cache-size 20000 --shards 16 --threads 8
        \\  zigache-benchmark --mode both --cache-size 50000 --base-size 40000 --zipf 0.9
        \\
    ;
    try std.io.getStdOut().writer().print("{s}\n", .{help_text});
}

comptime {
    _ = @import("zipfian.zig");
}
