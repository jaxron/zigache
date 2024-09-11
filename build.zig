const std = @import("std");
const builtin = @import("builtin");

comptime {
    const min_zig = std.SemanticVersion.parse("0.13.0") catch unreachable;
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
    const exe = b.addExecutable(.{
        .name = "zigache-benchmark",
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    exe.root_module.addImport("zigache", zigache_mod);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the benchmark");
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
