//! Exponential backoff with jitter for HTTP retry logic.

const std = @import("std");

/// Thread-local PRNG lazily seeded from values that do not require an `Io`.
/// Zig 0.16 removed `std.crypto.random`; retry jitter is non-cryptographic,
/// so a seeded `DefaultPrng` is sufficient. Seed entropy comes from the
/// address of the thread-local slot (unique per thread) mixed with a
/// process-wide atomic counter (unique per init) — no dependency on
/// `std.Options.debug_threaded_io`, so this works under alternative Io
/// backends or when no ambient Io is configured at all.
threadlocal var rng_state: ?std.Random.DefaultPrng = null;

var seed_counter: std.atomic.Value(u64) = .init(0);

fn threadRandom() std.Random {
    if (rng_state == null) {
        const addr_entropy: u64 = @intCast(@intFromPtr(&rng_state));
        const counter_entropy = seed_counter.fetchAdd(1, .monotonic);
        // Mix with the 64-bit golden-ratio constant so adjacent counter
        // values produce well-separated seeds.
        const seed = addr_entropy ^ (counter_entropy *% 0x9E3779B97F4A7C15);
        rng_state = std.Random.DefaultPrng.init(seed);
    }
    return rng_state.?.random();
}

/// Returns backoff delay in nanoseconds for the given attempt (0-indexed).
/// Formula: min(base_ms * 2^attempt, max_ms) + random jitter [0, 500ms).
pub fn backoffNs(attempt: u32, base_ms: u64, max_ms: u64) u64 {
    const exp: u64 = if (attempt < 63) @as(u64, 1) << @intCast(attempt) else std.math.maxInt(u64);
    const delay_ms = @min(base_ms *| exp, max_ms); // saturating mul
    const jitter_ms = threadRandom().intRangeLessThan(u64, 0, 500);
    return (delay_ms + jitter_ms) * std.time.ns_per_ms;
}

/// Whether an HTTP status code should trigger a retry.
pub fn shouldRetry(status: u16) bool {
    return status == 429 or status >= 500;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "backoffNs: first attempt is at least base_ms" {
    const ns = backoffNs(0, 1000, 30_000);
    try std.testing.expect(ns >= 1000 * std.time.ns_per_ms);
}

test "backoffNs: capped at max_ms + jitter ceiling" {
    const ns = backoffNs(30, 1000, 30_000);
    const max_possible_ns = (30_000 + 500) * std.time.ns_per_ms;
    try std.testing.expect(ns <= max_possible_ns);
}

test "backoffNs: does not overflow with large attempt" {
    const ns = backoffNs(100, 1000, 30_000);
    const max_possible_ns = (30_000 + 500) * std.time.ns_per_ms;
    try std.testing.expect(ns <= max_possible_ns);
}

test "backoffNs: jitter varies across calls" {
    // 10 calls, at least 2 distinct values (monotonically jittered).
    var seen: [10]u64 = undefined;
    for (&seen) |*s| s.* = backoffNs(0, 1000, 30_000);
    var distinct: usize = 0;
    for (seen, 0..) |v, i| {
        var dup = false;
        for (seen[0..i]) |w| if (w == v) { dup = true; break; };
        if (!dup) distinct += 1;
    }
    try std.testing.expect(distinct >= 2);
}

test "backoffNs: threadlocal PRNGs across threads do not return identical sequences" {
    // Regression: the thread-local PRNG is seeded from
    // `@intFromPtr(&rng_state) ^ counter*golden`. Two threads with different
    // stack positions and different counter values must produce different
    // first-10 jitter patterns.
    const N = 4;
    const PER_THREAD = 10;
    const Worker = struct {
        fn run(out: *[PER_THREAD]u64) void {
            for (out, 0..) |*slot, i| {
                _ = i;
                slot.* = backoffNs(0, 1000, 30_000);
            }
        }
    };
    var results: [N][PER_THREAD]u64 = undefined;
    var threads: [N]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{&results[i]});
    }
    for (&threads) |*t| t.join();

    // At least two thread sequences must differ somewhere. Equal sequences
    // across threads would mean all threads shared the same seed — the bug
    // this PRNG design exists to prevent.
    var any_diff = false;
    for (1..N) |i| {
        if (!std.mem.eql(u64, &results[0], &results[i])) {
            any_diff = true;
            break;
        }
    }
    try std.testing.expect(any_diff);
}

test "shouldRetry: retries on 5xx" {
    try std.testing.expect(shouldRetry(500));
    try std.testing.expect(shouldRetry(503));
    try std.testing.expect(shouldRetry(502));
}

test "shouldRetry: retries on 429" {
    try std.testing.expect(shouldRetry(429));
}

test "shouldRetry: does not retry on 4xx (except 429)" {
    try std.testing.expect(!shouldRetry(400));
    try std.testing.expect(!shouldRetry(401));
    try std.testing.expect(!shouldRetry(403));
    try std.testing.expect(!shouldRetry(404));
}

test "shouldRetry: does not retry on 200" {
    try std.testing.expect(!shouldRetry(200));
}
