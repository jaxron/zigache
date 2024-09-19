const std = @import("std");
const builtin = @import("builtin");

comptime {
    const min_zig = std.SemanticVersion.parse("0.13.0-dev.351+64ef45eb0") catch unreachable;
    if (builtin.zig_version.order(min_zig) == .lt) {
        const error_message =
            \\Oops! It looks like your version of Zig is unsupported.
            \\zigache requires at least version {} of Zig.
            \\Please download the appropriate build from https://ziglang.org/download/
        ;
        @compileError(std.fmt.comptimePrint(error_message, .{min_zig}));
    }
}

const Example = struct {
    name: []const u8,
    source_file: std.Build.LazyPath,
    description: []const u8,
};

pub fn build(b: *std.Build) void {
    // Options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Module
    const zigache_mod = b.addModule("zigache", .{
        .root_source_file = b.path("src/zigache.zig"),
    });

    // Run Benchmark
    const options = b.addOptions();
    options.addOption(?bool, "custom", b.option(bool, "custom", "Run benchmark with custom options (default: false)"));
    options.addOption(?bool, "replay", b.option(bool, "replay", "Save/load keys for consistent benchmarks (default: false)"));
    options.addOption(?[]const u8, "mode", b.option([]const u8, "mode", "Benchmark mode: 'single' or 'multi' (default: single)"));
    options.addOption(?[]const u8, "policy", b.option([]const u8, "policy", "Cache policy: FIFO, LRU, TinyLFU, SIEVE, S3FIFO (default: all)"));
    options.addOption(?u32, "cache_size", b.option(u32, "cache-size", "Max items in cache (default: 10000)"));
    options.addOption(?u32, "pool_size", b.option(u32, "pool-size", "Pre-allocated nodes (default: same as cache-size)"));
    options.addOption(?u16, "shard_count", b.option(u16, "shards", "Number of cache shards (default: 64 multi, 1 single)"));
    options.addOption(?u32, "num_keys", b.option(u32, "keys", "Total key samples for benchmark (default: 1000000)"));
    options.addOption(?u8, "num_threads", b.option(u8, "threads", "Concurrent threads for multi-mode (default: 4)"));
    options.addOption(?f64, "zipf", b.option(f64, "zipf", "Zipfian distribution parameter (default: 1.0)"));
    options.addOption(?u64, "duration_ms", b.option(u64, "duration", "Benchmark duration in ms (default: 10000)"));
    options.addOption(?u64, "max_ops", b.option(u64, "ops", "Max operations to perform (default: not set)"));

    const exe = b.addExecutable(.{
        .name = "zigache-benchmark",
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zigache", zigache_mod);
    exe.root_module.addOptions("config", options);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("bench", "Run the benchmark");
    run_step.dependOn(&run_cmd.step);

    // Examples
    const examples = [_]Example{
        .{
            .name = "key_types",
            .source_file = b.path("examples/01_key_types.zig"),
            .description = "Usage of different key types in the library",
        },
        .{
            .name = "ttl_entries",
            .source_file = b.path("examples/02_ttl_entries.zig"),
            .description = "Usage of TTL functionality in the library",
        },
    };

    inline for (examples, 1..) |example, i| {
        const example_exe = b.addExecutable(.{
            .name = example.name,
            .root_source_file = example.source_file,
            .optimize = optimize,
            .target = target,
        });
        example_exe.root_module.addImport("zigache", zigache_mod);

        const install_step = b.addInstallArtifact(example_exe, .{});

        const example_cmd = b.addRunArtifact(example_exe);
        if (b.args) |args| {
            example_cmd.addArgs(args);
        }
        example_cmd.step.dependOn(&install_step.step);

        const example_step = b.step(std.fmt.comptimePrint("{:0>2}", .{i}), example.description);
        example_step.dependOn(&example_cmd.step);
    }

    // Tests
    const lib_test = b.addTest(.{
        .root_source_file = b.path("src/zigache.zig"),
        .test_runner = b.path("test_runner.zig"),
        .optimize = optimize,
        .target = target,
    });
    const run_test = b.addRunArtifact(lib_test);

    const bench_test = b.addTest(.{
        .root_source_file = b.path("bench/main.zig"),
        .test_runner = b.path("test_runner.zig"),
        .optimize = optimize,
        .target = target,
    });
    bench_test.root_module.addImport("zigache", zigache_mod);
    const run_bench_test = b.addRunArtifact(bench_test);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_test.step);
    test_step.dependOn(&run_bench_test.step);

    // Docs
    const docs = b.addExecutable(.{
        .name = "zigache",
        .root_source_file = b.path("src/zigache.zig"),
        .optimize = optimize,
        .target = target,
    });
    b.installArtifact(docs);

    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Emit library documentation");
    docs_step.dependOn(&install_docs.step);
}
