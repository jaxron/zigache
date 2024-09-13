<h1 align="center">
    <picture>
      <img height="120" alt="Zigache" src="./assets/images/zigache_logo.png">
    </picture>
  <br>
</h1>

<p align="center">
  <em><b>Zigache</b> is an efficient caching library implemented in <a href="https://ziglang.org/">Zig</a>, offering various cache eviction policies and support for sharding to enhance concurrency.</em>
</p>

---

> [!NOTE]
> This project follows Mach Engine's nominated zig version - `2024.5.0-mach` / `0.13.0-dev.351+64ef45eb0`. For more information, see [this](https://machengine.org/docs/nominated-zig/).

# 📚 Table of Contents

- [🚀 Features](#-features)
- [⚡️ Quickstart](#%EF%B8%8F-quickstart)
- [👀 Examples](#-examples)
- [⚙️ Configuration](#%EF%B8%8F-configuration)
- [📊 Performance](#-performance)
- [🤝 Contributing](#-contributing)
- [📄 License](#-license)

# 🚀 Features

Zigache offers a rich set of features to address a wide range of caching needs:

- **Multiple cache eviction policies:**
  - W-TinyLFU | [TinyLFU: A Highly Efficient Cache Admission Policy](https://arxiv.org/abs/1512.00727)
  - S3-FIFO | [FIFO queues are all you need for cache eviction](https://dl.acm.org/doi/10.1145/3600006.3613147)
  - SIEVE | [SIEVE is Simpler than LRU: an Efficient Turn-Key Eviction Algorithm for Web Caches](https://www.usenix.org/conference/nsdi24/presentation/zhang-yazhuo)
  - LRU | Least Recently Used
  - FIFO | First-In-First-Out
- **Sharding support** for improved concurrency
- **Configurable cache size** with pre-allocation options
- **Time-To-Live (TTL)** support for cache entries
- **Thread-safe** for multi-threaded environments
- Supports **multiple key and value types**

# ⚡️ Quickstart

To use Zigache in your project, follow these steps:

1. Add Zigache as a dependency in your `build.zig.zon`:

    ```zig
    .{
        .name = "your-project",
        .version = "1.0.0",
        .paths = .{
            "src",
            "build.zig",
            "build.zig.zon",
        },
        .dependencies = .{
            .zigache = .{
                .url = "https://github.com/jaxron/zigache/archive/26395537581db98f79c8ed5eb8f3a34f98a2ca3e.tar.gz",
                .hash = "1220ef544032c604dfd881baa2c001f41d10fcc1f50b3965b44eb892b9b91a94ed8e",
            },
        },
    }
    ```

2. In your `build.zig`, add:

    ```diff
    pub fn build(b: *std.Build) void {
        // Options
        const target = b.standardTargetOptions(.{});
        const optimize = b.standardOptimizeOption(.{});

        // Build
    +   const zigache = b.dependency("zigache", .{
    +       .target = target,
    +       .optimize = optimize,
    +   }).module("zigache");
    
        const exe = b.addExecutable(.{
            .name = "your-project",
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });
    +   exe.root_module.addImport("zigache", zigache);
 
        b.installArtifact(exe);
    
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
    
        const run_step = b.step("run", "Run the program");
        run_step.dependOn(&run_cmd.step);
    }
    ```

3. Now you can import and use Zigache in your code:

    ```zig
    const std = @import("std");
    const Cache = @import("zigache").Cache;
    
    pub fn main() !void {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();
    
        // Create a cache with string keys and values
        var cache = try Cache([]const u8, []const u8, .{
            .total_size = 1,
            .policy = .SIEVE,
        }).init(allocator);
        defer cache.deinit();
    
        // your code...
    }
    ```

# 👀 Examples

Explore the usage scenarios in our examples directory:

- [Basic Usage](examples/01_basic.zig)

To run an example:

```sh
zig build [example-name]
zig build basic
```

# ⚙️ Configuration

Zigache offers flexible configuration options to adjust the cache to your needs:

```zig
var cache = try Cache([]const u8, []const u8, .{
    .total_size = 10000,   // Total number of items the cache can hold
    .base_size = 1000,     // Total number of nodes to pre-allocate for better performance
    .shard_count = 16,     // Number of shards for concurrent access
    .thread_safe = true,   // Whether to enable safety features for concurrent access
    .policy = .SIEVE,      // Eviction policy
}).init(allocator);
```

# 📊 Performance

Benchmark parameters:

```sh
zig build bench -Doptimize=ReleaseFast -Dmode=both -Dduration=60000 -Dshards=64 -Dthreads=4
```

For more details on the available flags, run `zig build -h`.

## Single-Threaded Performance

```
Single Threaded: duration=60.00s keys=1000000 cache-size=10000 zipf=0.70
--------+-----------+--------+-------------+--------------+-----------+-----------+-------------
Name    | Total Ops | ns/op  | ops/s       | Hit Rate (%) | Hits      | Misses    | Memory (MB)
--------+-----------+--------+-------------+--------------+-----------+-----------+-------------
FIFO    | 770637120 | 77.86  | 12843952.00 | 10.66        | 82151521  | 688485599 | 0.82
LRU     | 704728198 | 85.14  | 11745469.97 | 12.09        | 85203420  | 619524778 | 0.82
TinyLFU | 534006855 | 112.36 | 8900114.25  | 22.10        | 118009443 | 415997412 | 0.93
SIEVE   | 728619842 | 82.35  | 12143664.03 | 21.10        | 153732369 | 574887473 | 0.89
S3FIFO  | 725894226 | 82.66  | 12098237.10 | 18.37        | 133332817 | 592561409 | 0.89
--------+-----------+--------+-------------+--------------+-----------+-----------+-------------
```

## Multi-Threaded Performance

```
Multi Threaded: duration=60.00s keys=1000000 cache-size=10000 zipf=0.70
--------+-----------+--------+------------+--------------+-----------+-----------+-------------
Name    | Total Ops | ns/op  | ops/s      | Hit Rate (%) | Hits      | Misses    | Memory (MB)
--------+-----------+--------+------------+--------------+-----------+-----------+-------------
FIFO    | 687328718 | 349.18 | 2863869.65 | 10.68        | 73374073  | 613954645 | 0.84
LRU     | 648651614 | 370.00 | 2702715.06 | 12.08        | 78382239  | 570269375 | 0.84
TinyLFU | 610648356 | 393.02 | 2544368.14 | 21.84        | 133361276 | 477287080 | 0.96
SIEVE   | 733687934 | 327.11 | 3057033.05 | 22.53        | 165316944 | 568370990 | 0.92
S3FIFO  | 634874645 | 378.03 | 2645311.00 | 19.66        | 124786665 | 510087980 | 0.92
--------+-----------+--------+------------+--------------+-----------+-----------+-------------
```

### Key Observations

- FIFO and SIEVE policies generally offer the highest throughput.
- TinyLFU and SIEVE provide the best hit rates, which can be crucial for certain applications.

# 🤝 Contributing

We welcome contributions to Zigache! Please make sure to update tests as appropriate and adhere to the [Zig Style Guide](https://ziglang.org/documentation/master/#Style-Guide).

# 📄 License

This project is licensed under the MIT License. See the [LICENSE.md](LICENSE.md) file for details.
