const std = @import("std");

const EPSILON = 1e-8; // Small value to check floating-point precision
const MAX_ITERATIONS = 1000; // Max loop iterations to prevent infinite loops in sampling

n: u64, // Total number of elements
s: f64, // Exponent determining the skewness of the distribution
h_x1: f64, // Precomputed harmonic approximation for x = 1.5
h_n: f64, // Precomputed harmonic approximation for n elements
threshold: f64, // Acceptance threshold for rejection sampling
harmonic_cache: []f64, // Precomputed harmonic values cache

const Self = @This();

/// Zipfian distribution generator that models phenomena where certain events are much more likely
/// than others, such as word frequencies or file sizes.
///
/// Initialize a Zipfian distribution with `n` elements and exponent `s`.
/// - `n`: The number of distinct elements (must be > 0).
/// - `s`: The exponent controlling the distribution's skew (must be > 0).
pub fn init(allocator: std.mem.Allocator, n: u64, s: f64) !Self {
    if (n == 0) return error.ZeroElements; // Edge case: cannot have zero elements
    if (s <= 0) return error.NonPositiveExponent; // Invalid exponent for Zipfian distribution

    // Allocate memory for harmonic values (cached to improve sampling efficiency)
    var harmonic_cache = try allocator.alloc(f64, n + 1);
    errdefer allocator.free(harmonic_cache);

    // Populate the harmonic cache using the formula: sum += 1 / i^s
    harmonic_cache[0] = 0;
    var sum: f64 = 0;
    for (1..n + 1) |i| {
        sum += 1 / std.math.pow(f64, @as(f64, @floatFromInt(i)), s);
        harmonic_cache[i] = sum;
    }

    // Precompute necessary harmonic approximations for fast sampling
    const h_x1 = harmonicApprox(1.5, s) - 1;
    const h_n = harmonicApprox(@as(f64, @floatFromInt(n)) + 0.5, s);
    const threshold = 2 - harmonicInv(harmonicApprox(2.5, s) - zipf(2, s), s);

    return .{
        .n = n,
        .s = s,
        .h_x1 = h_x1,
        .h_n = h_n,
        .threshold = threshold,
        .harmonic_cache = harmonic_cache,
    };
}

/// Free the memory allocated for the harmonic cache.
pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.harmonic_cache);
}

/// Generate the next Zipfian-distributed number using rejection sampling.
/// The method will try to generate numbers according to the Zipfian distribution.
/// If the maximum number of iterations (`MAX_ITERATIONS`) is reached, it will
/// return a uniformly random number instead, to avoid an infinite loop.
pub fn next(self: *Self, rng: std.rand.Random) u64 {
    // Special case: If s is very close to 1, use a different method (simplified handling)
    if (@abs(self.s - 1) < EPSILON) {
        return self.nextForSNearOne(rng);
    }

    // Rejection sampling loop: try to generate a valid Zipfian-distributed number
    var iterations: usize = 0;
    while (iterations < MAX_ITERATIONS) : (iterations += 1) {
        // Generate a uniform random number mapped to the harmonic range [h_n, h_x1]
        const u = self.h_n + normalizeFloat(rng.float(f64)) * (self.h_x1 - self.h_n);
        const x = harmonicInv(u, self.s);
        // Round to the nearest integer, ensuring it's within the valid range
        const k = @min(@max(@as(u64, @intFromFloat(x + 0.5)), 1), self.n);

        // Check if the generated number satisfies the acceptance criteria
        if (@abs(@as(f64, @floatFromInt(k)) - x) <= self.threshold or
            u >= self.harmonic(@as(f64, @floatFromInt(k)) + 0.5) - zipf(@as(f64, @floatFromInt(k)), self.s))
        {
            return k;
        }
    }

    // Fallback if too many iterations: return a uniformly distributed number from [1, n]
    return rng.intRangeAtMost(u64, 1, self.n);
}

/// Special method for generating a Zipfian-distributed number when s ≈ 1.
/// This case is treated separately because the harmonic series behaves
/// differently when s is close to 1, making it more efficient to handle it
/// with binary search over the precomputed harmonic values.
fn nextForSNearOne(self: *Self, rng: std.rand.Random) u64 {
    const u = normalizeFloat(rng.float(f64)) * self.harmonic_cache[self.n];

    // Binary search through the harmonic cache to find the corresponding rank
    var left: usize = 1;
    var right: usize = self.n;
    while (left <= right) {
        const mid = left + (right - left) / 2;
        if (self.harmonic_cache[mid] < u) {
            left = mid + 1;
        } else if (mid > 1 and self.harmonic_cache[mid - 1] >= u) {
            right = mid - 1;
        } else {
            return @intCast(mid);
        }
    }
    return self.n; // Fallback to the maximum value if not found
}

/// Compute the harmonic number using linear interpolation for better accuracy.
/// If the value is within the range of precomputed harmonic values, interpolation
/// is used to compute the value more accurately. Otherwise, harmonic approximation is used.
fn harmonic(self: *const Self, x: f64) f64 {
    const index = @as(usize, @intFromFloat(x));
    if (index < self.harmonic_cache.len - 1) {
        // Linear interpolation between cached harmonic values for better precision
        return self.harmonic_cache[index] + (x - @as(f64, @floatFromInt(index))) *
            (self.harmonic_cache[index + 1] - self.harmonic_cache[index]);
    }
    // For values beyond the cache range, approximate the harmonic value
    return harmonicApprox(x, self.s);
}

/// Approximate the nth harmonic number using the formula for s ≠ 1. For large
/// values of n, this provides an efficient approximation of the harmonic
/// series. When s ≈ 1, a logarithmic approximation is used instead.
fn harmonicApprox(x: f64, s: f64) f64 {
    if (@abs(s - 1) < EPSILON) {
        // For s ≈ 1, use the logarithmic approximation
        return @log(x);
    }
    // General harmonic approximation formula: (x^(1-s) - 1) / (1 - s)
    return (std.math.pow(f64, x, 1 - s) - 1) / (1 - s);
}

/// Inverse of the harmonic approximation function to map random numbers
/// back to the Zipfian distribution rank. This is part of the rejection
/// sampling process.
fn harmonicInv(x: f64, s: f64) f64 {
    if (@abs(s - 1) < EPSILON) {
        // For s ≈ 1, use exponential function
        return @exp(x);
    }
    // General case: (1 + x(1-s))^(1/(1-s))
    return std.math.pow(f64, 1 + x * (1 - s), 1 / (1 - s));
}

/// Zipf function: Compute 1 / x^s.
/// This function computes the probability of rank `x` in the Zipfian distribution.
fn zipf(x: f64, s: f64) f64 {
    return 1 / std.math.pow(f64, x, s);
}

/// Normalize a float to the [0, 1 - ε] range to avoid numerical instability
/// and ensure the random number remains in a valid range for sampling.
fn normalizeFloat(x: f64) f64 {
    return @max(0, @min(x, 1 - std.math.floatEps(f64)));
}
