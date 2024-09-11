//! ZipfianDistribution generates random numbers following Zipf's law.
//! It uses the rejection-inversion method for efficient sampling.

const std = @import("std");

// Number of elements in the distribution (range: [1, n])
n: u64,
// Exponent parameter (s in the Zipf's law formula)
s: f64,
// Pre-computed values for optimization
h_x1: f64,
h_n: f64,
threshold: f64,

const Self = @This();

/// Initialize a new ZipfianDistribution
/// n: number of elements (must be > 0)
/// s: exponent parameter (must be > 0)
pub fn init(n: u64, s: f64) !Self {
    if (n == 0) return error.ZeroElements;
    if (s <= 0) return error.NonPositiveExponent;

    const n_float: f64 = @floatFromInt(n);
    return .{
        .n = n,
        .s = s,
        // Pre-compute these values for efficiency in the `next` method
        .h_x1 = harmonic(1.5, s) - 1,
        .h_n = harmonic(n_float + 0.5, s),
        .threshold = 2 - harmonicInv(harmonic(2.5, s) - zipf(2, s), s),
    };
}

/// Generate the next Zipfian-distributed random number
pub fn next(self: *Self, rng: std.rand.Random) u64 {
    while (true) {
        // Generate a uniform random number and map it to the Zipfian distribution
        const u = self.h_n + rng.float(f64) * (self.h_x1 - self.h_n);
        const x = harmonicInv(u, self.s);

        // Ensure the resulting integer `k` is within the valid range [1, n]
        const k = @min(@max(@as(u64, @intFromFloat(x + 0.5)), 1), self.n);

        // Rejection check: accept or reject the generated number based on probability criteria
        if (@abs(@as(f64, @floatFromInt(k)) - x) <= self.threshold or
            u >= harmonic(@as(f64, @floatFromInt(k)) + 0.5, self.s) - zipf(@as(f64, @floatFromInt(k)), self.s))
        {
            return k; // Accept and return the value if it passes the checks
        }
        // If rejected, continue the loop to generate a new number
    }
}

/// Compute the harmonic function H(x)
fn harmonic(x: f64, s: f64) f64 {
    if (s == 1) return @log(x);
    return (std.math.pow(f64, x, 1 - s) - 1) / (1 - s);
}

/// Compute the inverse of the harmonic function
fn harmonicInv(x: f64, s: f64) f64 {
    if (s == 1) return @exp(x);
    return std.math.pow(f64, 1 + x * (1 - s), 1 / (1 - s));
}

/// Compute the Zipf function (probability mass function)
fn zipf(x: f64, s: f64) f64 {
    return 1 / std.math.pow(f64, x, s);
}

const testing = std.testing;

test "ZipfianDistribution - initialization" {
    // Test valid initialization
    const valid_dist = try Self.init(100, 1.5);
    try testing.expect(valid_dist.n == 100);
    try testing.expect(valid_dist.s == 1.5);

    // Test initialization with invalid parameters
    try testing.expectError(error.ZeroElements, Self.init(0, 1.5));
    try testing.expectError(error.NonPositiveExponent, Self.init(100, 0));
    try testing.expectError(error.NonPositiveExponent, Self.init(100, -1));
}

test "ZipfianDistribution - next" {
    var prng = std.rand.DefaultPrng.init(42);
    const rng = prng.random();

    var dist = try Self.init(100, 1.5);

    // Generate a large number of samples
    var samples: [10000]u64 = undefined;
    for (&samples) |*sample| {
        sample.* = dist.next(rng);
    }

    // Check that all generated numbers are within the correct range
    for (samples) |sample| {
        try testing.expect(sample >= 1 and sample <= 100);
    }

    // Check that the distribution is roughly as expected
    // (more low numbers than high numbers)
    var counts = [_]usize{0} ** 100;
    for (samples) |sample| {
        counts[sample - 1] += 1;
    }

    // The first few elements should have significantly more occurrences
    try testing.expect(counts[0] > counts[49]);
    try testing.expect(counts[1] > counts[48]);
    try testing.expect(counts[2] > counts[47]);
}

test "ZipfianDistribution - deterministic behavior" {
    var prng1 = std.rand.DefaultPrng.init(42);
    var prng2 = std.rand.DefaultPrng.init(42);

    var dist1 = try Self.init(100, 1.5);
    var dist2 = try Self.init(100, 1.5);

    // Generate samples from both distributions
    for (0..1000) |_| {
        const sample1 = dist1.next(prng1.random());
        const sample2 = dist2.next(prng2.random());
        // Ensure that given the same seed, the distributions produce identical results
        try testing.expectEqual(sample1, sample2);
    }
}
