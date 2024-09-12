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

Zigache currently prioritizes feature richness, flexibility, and stability over performance. Nonetheless, it still performs generally well. The following benchmarks were conducted on a system running Windows 11 with AMD Ryzen 7 5825U.

Benchmark parameters:

```sh
zig build run -Doptimize=ReleaseFast -Dmode=both -Dduration=300000 -Dshards=64 -Dthreads=4
```

For more details on the available flags, run `zig build -h`.

## Single-Threaded Performance

```
Single Threaded: zipf=0.70 duration=300s keys=1000000 cache-size=10000
--------+------------+--------+-------------+--------------+-----------+------------+-------------
Name    | Total Ops  | ns/op  | ops/s       | Hit Rate (%) | Hits      | Misses     | Memory (MB)
--------+------------+--------+-------------+--------------+-----------+------------+-------------
FIFO    | 1237461249 | 99.71  | 10029250.15 | 10.66        | 131895732 | 1105565517 | 1.01
LRU     | 1158557000 | 113.34 | 8823215.54  | 12.06        | 139707482 | 1018849518 | 1.01
TinyLFU | 1053744113 | 140.72 | 7106401.58  | 22.19        | 233809144 | 819934969  | 1.13
SIEVE   | 1179537148 | 110.25 | 9070171.88  | 21.10        | 248834794 | 930702354  | 1.09
S3FIFO  | 1161060000 | 114.44 | 8737929.74  | 18.34        | 212995034 | 948064966  | 1.09
```

## Multi-Threaded Performance

```
Multi Threaded: zipf=0.70 duration=300s keys=1000000 cache-size=10000 shards=64 threads=4
--------+------------+--------+------------+--------------+-----------+------------+-------------
Name    | Total Ops  | ns/op  | ops/s      | Hit Rate (%) | Hits      | Misses     | Memory (MB)
--------+------------+--------+------------+--------------+-----------+------------+-------------
FIFO    | 2541521446 | 432.72 | 2310964.42 | 10.65        | 270631623 | 2270889823 | 1.04
LRU     | 2446472366 | 450.41 | 2220190.91 | 12.05        | 294732462 | 2151739904 | 1.04
TinyLFU | 2309891106 | 481.84 | 2075391.96 | 21.82        | 504025540 | 1805865566 | 1.16
SIEVE   | 2640881101 | 417.22 | 2396792.41 | 22.52        | 594846917 | 2046034184 | 1.11
S3FIFO  | 2306950801 | 472.17 | 2117887.27 | 19.62        | 452645830 | 1854304971 | 1.11
```

### Key Observations

- FIFO and SIEVE policies generally offer the highest throughput.
- TinyLFU and SIEVE provide the best hit rates, which can be crucial for certain applications.

# 🤝 Contributing

We welcome contributions to Zigache! Please make sure to update tests as appropriate and adhere to the [Zig Style Guide](https://ziglang.org/documentation/master/#Style-Guide).

# 📄 License

This project is licensed under the MIT License. See the [LICENSE.md](LICENSE.md) file for details.
