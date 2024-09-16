<h1 align="center">
    <picture>
      <img height="120" alt="Zigache" src="./assets/images/zigache_logo.png">
    </picture>
  <br>
  <a href="https://github.com/jaxron/zigache/blob/main/LICENSE.md">
    <img src="https://img.shields.io/github/license/jaxron/zigache?style=flat-square&color=F27523">
  </a>
  <a href="https://github.com/jaxron/zigache/actions/workflows/ci.yml">
    <img src="https://img.shields.io/github/actions/workflow/status/jaxron/zigache/ci.yml?style=flat-square&color=F27523">
  </a>
  <a href="https://jaxron.me/zigache/">
    <img src="https://img.shields.io/badge/zigache-docs-00ACD7.svg?style=flat-square&color=F27523">
  </a>
  <a href="https://github.com/jaxron/zigache/issues">
    <img src="https://img.shields.io/github/issues/jaxron/zigache?style=flat-square&color=F27523">
  </a>
</h1>

<p align="center">
  <em><b>Zigache</b> is an efficient caching library built in <a href="https://ziglang.org/">Zig</a>, offering customizable cache eviction policies for various application needs.</em>
</p>

---

> [!IMPORTANT]
> Zigache is currently in **early development** and follows Zig's latest nightly build. Last tested with `0.14.0-dev.1573+4d81e8ee9`.

# 📚 Table of Contents

- [🚀 Features](#-features)
- [⚡️ Quickstart](#%EF%B8%8F-quickstart)
- [👀 Examples](#-examples)
- [⚙️ Configuration](#%EF%B8%8F-configuration)
- [📊 Performance](#-performance)
- [🗺️ Roadmap](#%EF%B8%8F-roadmap)
- [🤝 Contributing](#-contributing)
- [📄 License](#-license)

# 🚀 Features

Zigache offers a rich set of features to designed to meet various caching needs:

- **Multiple Eviction Algorithms:**
  - W-TinyLFU | [TinyLFU: A Highly Efficient Cache Admission Policy](https://arxiv.org/abs/1512.00727)
  - S3-FIFO | [FIFO queues are all you need for cache eviction](https://dl.acm.org/doi/10.1145/3600006.3613147)
  - SIEVE | [SIEVE is Simpler than LRU: an Efficient Turn-Key Eviction Algorithm for Web Caches](https://www.usenix.org/conference/nsdi24/presentation/zhang-yazhuo)
  - LRU | Least Recently Used
  - FIFO | First-In-First-Out
- **Configurable Cache Size** with pre-allocation options
- **Time-To-Live (TTL)** support for cache entries
- **Thread-Safe Operations** for stability in concurrent environments
- **Sharding Support** for improved performance in concurrent environments
- **Heavy Testing and Benchmarking** for stability and performance

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
                .url = "https://github.com/jaxron/zigache/archive/6f4995142fed9c83598fc2d9cbc38fbe75899095.tar.gz",
                .hash = "12208aad920f6b0227835013637cff0ba8fdf8a9abfe17ac3b9e3dd350bd5d5c1f36",
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
        var cache: Cache([]const u8, []const u8, .{
            .cache_size = 1,
            .policy = .SIEVE,
        }) = try .init(allocator);
        defer cache.deinit();
    
        // your code...
    }
    ```

# 👀 Examples

Explore the usage scenarios in our examples directory:

- [01 | Key Types](examples/01_key_types.zig)
- [02 | TTL Entries](examples/02_ttl_entries.zig)

To run an example:

```sh
zig build [example-id]
zig build 01
```

# ⚙️ Configuration

Zigache offers flexible configuration options to adjust the cache to your needs:

```zig
var cache: Cache([]const u8, []const u8, .{
    .cache_size = 10000,   // Total number of items the cache can hold
    .pool_size = 1000,     // Total number of nodes to pre-allocate for better performance
    .shard_count = 16,     // Number of shards for concurrent access
    .thread_safety = true, // Whether to enable safety features for concurrent access
    .ttl_enabled = false,  // Whether to enable the Time-To-Live (TTL) functionality
    .policy = .SIEVE,      // Eviction policy
}) = try .init(allocator);
```

> For more detailed information, refer to the [full documentation](https://jaxron.me/zigache/).

# 📊 Performance

This benchmark utilizes a [Zipfian distribution](https://en.wikipedia.org/wiki/Zipf%27s_law) with a parameter of 1.0, run on an Intel® Core™ i7-8700 CPU in Ubuntu 22.04.

> [!NOTE]
> Keep in mind that these results are not conclusive. Performance varies with workload and environment. Some eviction policies may perform better for specific use cases, so it's best to experiment with different parameters.

Benchmark parameters used:

```sh
zig build bench -Doptimize=ReleaseFast -Dmode=both -Dduration=60000 -Dzipf="1.0" -Dshards=64 -Dthreads=4
```

For more details on the available flags, run `zig build -h`.

## Single-Threaded

```markdown
Single Threaded: duration=60.00s keys=320000 cache-size=10000 pool-size=10000 zipf=1.00
--------+------------+--------+-------------+--------------+-----------+-----------+-------------
Name    | Total Ops  | ns/op  | ops/s       | Hit Rate (%) | Hits      | Misses    | Memory (MB) 
--------+------------+--------+-------------+--------------+-----------+-----------+-------------
FIFO    | 1011924108 | 59.29  | 16865401.79 | 61.47        | 622013224 | 389910884 | 0.82        
LRU     | 974760215  | 61.55  | 16246003.58 | 65.14        | 634923543 | 339836672 | 0.82        
TinyLFU | 319355703  | 187.88 | 5322595.05  | 70.81        | 226131076 | 93224627  | 0.93        
SIEVE   | 1066801149 | 56.24  | 17780019.14 | 72.03        | 768447908 | 298353241 | 0.89        
S3FIFO  | 938150865  | 63.96  | 15635847.75 | 68.91        | 646522113 | 291628752 | 0.89        
--------+------------+--------+-------------+--------------+-----------+-----------+-------------
```

## Multi-Threaded

```markdown
Multi Threaded: duration=60.00s keys=320000 cache-size=10000 pool-size=10000 zipf=1.00 shards=64 threads=4
--------+------------+--------+------------+--------------+-----------+-----------+-------------
Name    | Total Ops  | ns/op  | ops/s      | Hit Rate (%) | Hits      | Misses    | Memory (MB) 
--------+------------+--------+------------+--------------+-----------+-----------+-------------
FIFO    | 969530870  | 247.54 | 4039711.93 | 61.40        | 595302615 | 374228255 | 0.84        
LRU     | 815681027  | 294.23 | 3398670.94 | 65.02        | 530381235 | 285299792 | 0.84        
TinyLFU | 718285582  | 334.13 | 2992856.58 | 73.26        | 526248962 | 192036620 | 0.96        
SIEVE   | 1000027550 | 239.99 | 4166781.42 | 74.02        | 740237765 | 259789785 | 0.92        
S3FIFO  | 1004268540 | 238.98 | 4184452.23 | 69.79        | 700884097 | 303384443 | 0.91        
--------+------------+--------+------------+--------------+-----------+-----------+-------------
```

### Key Observations

- **FIFO** offers high throughput, especially in single-threaded scenarios, but has a lower hit rate than others.
- **LRU** performs well but falls behind **SIEVE** and **TinyLFU** in both throughput and hit rate.
- **TinyLFU** achieves the best hit rate, particularly in multi-threaded scenarios, making it ideal for workloads prioritizing cache efficiency.
- **SIEVE** strikes the best balance of throughput and hit rate in both single and multi-threaded environments.
- **S3FIFO** delivers strong multi-threaded throughput while maintaining a solid hit rate.

# 🗺️ Roadmap

Zigache is in its early stages. Our current focus is on implementing features, with performance optimizations planned for the future. Here are some things we have planned for the future:

- [ ] ⚙️ Runtime-configurable API
- [ ] 📦 Batch operations support
- [ ] 📊 Metrics and monitoring
- [ ] 🧪 Improved benchmarking suite
- [ ] 🔄 Adaptive system to adjust eviction policies
- [ ] 🔓 Lock-free data structures

> 💡 **We value your input!** Have suggestions for our roadmap? Feel free to open an issue or start a discussion.

# 🤝 Contributing

We welcome contributions to Zigache! Please make sure to update tests as appropriate and adhere to the [Zig Style Guide](https://ziglang.org/documentation/master/#Style-Guide).

# 📄 License

This project is licensed under the MIT License. See the [LICENSE.md](LICENSE.md) file for details.
