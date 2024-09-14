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
    options.addOption(?[]const u8, "mode", b.option([]const u8, "mode", "Set the benchmark mode | Default: single"));
    options.addOption(?u32, "cache_size", b.option(u32, "cache-size", "Set the total cache size | Default: 10_000"));
    options.addOption(?u32, "pool_size", b.option(u32, "pool-size", "Set the number of nodes to pre-allocate | Default: same as cache size"));
    options.addOption(?u16, "shard_count", b.option(u16, "shards", "Set the shard count | Default: 1"));
    options.addOption(?u32, "num_keys", b.option(u32, "keys", "Set the number of sample keys | Default: 32 * cache size"));
    options.addOption(?u8, "num_threads", b.option(u8, "threads", "Set the number of threads | Default: 4"));
    options.addOption(?f64, "zipf", b.option(f64, "zipf", "Set the zipfian distribution | Default: 0.7"));
    options.addOption(?u64, "duration_ms", b.option(u64, "duration", "Set the duration in milliseconds | Default: 60_000"));
    options.addOption(?u64, "max_ops", b.option(u64, "ops", "Set the maximum number of operations | Default: not set"));

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
            .name = "basic",
            .source_file = b.path("examples/01_basic.zig"),
            .description = "Basic usage of the library",
        },
    };

    inline for (examples) |example| {
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

        const example_step = b.step(example.name, example.description);
        example_step.dependOn(&example_cmd.step);
    }

    // Library Tests
    const lib_test = b.addTest(.{
        .root_source_file = b.path("src/zigache.zig"),
        .test_runner = b.path("test_runner.zig"),
        .optimize = optimize,
        .target = target,
    });
    lib_test.root_module.addImport("zigache", zigache_mod);

    const run_test = b.addRunArtifact(lib_test);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_test.step);

    // Benchmark Tests
    const bench_test = b.addTest(.{
        .root_source_file = b.path("bench/main.zig"),
        .test_runner = b.path("test_runner.zig"),
        .optimize = optimize,
        .target = target,
    });
    bench_test.root_module.addImport("zigache", zigache_mod);

    const run_bench_test = b.addRunArtifact(bench_test);
    const bench_test_step = b.step("bench-test", "Run benchmark tests");
    bench_test_step.dependOn(&run_bench_test.step);

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
