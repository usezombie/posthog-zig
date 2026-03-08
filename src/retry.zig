//! Exponential backoff with jitter for HTTP retry logic.

const std = @import("std");

/// Returns backoff delay in nanoseconds for the given attempt (0-indexed).
/// Formula: min(base_ms * 2^attempt, max_ms) + random jitter [0, 500ms).
pub fn backoffNs(attempt: u32, base_ms: u64, max_ms: u64) u64 {
    const exp: u64 = if (attempt < 63) @as(u64, 1) << @intCast(attempt) else std.math.maxInt(u64);
    const delay_ms = @min(base_ms *| exp, max_ms); // saturating mul
    const jitter_ms = std.crypto.random.intRangeLessThan(u64, 0, 500);
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
    // Max delay = max_ms + 499ms jitter
    const ns = backoffNs(30, 1000, 30_000);
    const max_possible_ns = (30_000 + 500) * std.time.ns_per_ms;
    try std.testing.expect(ns <= max_possible_ns);
}

test "backoffNs: does not overflow with large attempt" {
    // Should not panic
    const ns = backoffNs(100, 1000, 30_000);
    const max_possible_ns = (30_000 + 500) * std.time.ns_per_ms;
    try std.testing.expect(ns <= max_possible_ns);
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
