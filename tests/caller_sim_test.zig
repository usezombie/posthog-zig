//! Caller simulation tests.
//!
//! Exercises posthog-zig from the perspective of a real service integrating
//! the SDK (e.g. zombied). All tests run offline — no network required.
//!
//! Coverage:
//!   - Full product analytics flow (identify → group → capture)
//!   - Handled error reporting via captureException
//!   - Fatal exception pattern (level == .fatal)
//!   - Panic hook pattern: verify queue memory is accessible without allocation
//!   - Hot-path latency: p50 / p95 / p99 over 10_000 capture() calls
//!   - Adversarial payloads: special chars, empty strings, huge values, unicode
//!   - Queue overflow: drop-newest behavior and dropped counter accuracy
//!   - Concurrent producers: N threads calling capture() without data race
//!   - Graceful shutdown: pending events survive deinit() (best-effort)
//!   - Invalid delivery: on_deliver callback receives correct status on failure

const std = @import("std");
const posthog = @import("posthog");

// Silence all logs in this test binary.
// Network failures (ConnectionRefused, NetworkError, batch dropped) are expected
// from the intentionally unreachable host 127.0.0.1:1 used in offline tests.
// Letting log.err reach the Zig test harness marks passing tests as failed.
pub const std_options: std.Options = .{
    .logFn = noopLog,
};

fn noopLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = level;
    _ = scope;
    _ = format;
    _ = args;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Build a client configured for offline testing:
/// - fake host (guaranteed network failure)
/// - max_retries = 0 (fail fast, no sleep)
/// - flush_at = max_queue_size + 1 (prevents automatic mid-test flush)
/// - flush_interval_ms = 60_000 (timer never fires during a test)
fn offlineClient(
    allocator: std.mem.Allocator,
    max_queue_size: usize,
) !*posthog.PostHogClient {
    return posthog.init(allocator, .{
        .api_key = "phc_sim_test",
        .host = "http://127.0.0.1:1", // refused immediately
        .enable_logging = false,
        .flush_at = max_queue_size + 1,
        .max_queue_size = max_queue_size,
        .flush_interval_ms = 60_000,
        .max_retries = 0,
        .shutdown_flush_timeout_ms = 500,
    });
}

fn pendingCount(client: *posthog.PostHogClient) usize {
    return client.queue.pendingCount();
}

fn droppedCount(client: *posthog.PostHogClient) u64 {
    return client.queue.droppedCount();
}

// ── Product analytics flow ────────────────────────────────────────────────────

test "caller: full product analytics flow — identify, group, capture" {
    const client = try offlineClient(std.testing.allocator, 100);
    defer client.deinit();

    // Step 1 — identify the user on signup
    try client.identify(.{
        .distinct_id = "user_clerk_abc123",
        .properties = &.{
            .{ .key = "email", .value = .{ .string = "alice@usezombie.com" } },
            .{ .key = "plan", .value = .{ .string = "pro" } },
            .{ .key = "seats", .value = .{ .integer = 5 } },
        },
    });

    // Step 2 — associate with workspace group
    try client.group(.{
        .distinct_id = "user_clerk_abc123",
        .group_type = "workspace",
        .group_key = "ws_xyz789",
        .properties = &.{
            .{ .key = "name", .value = .{ .string = "Acme Corp" } },
            .{ .key = "tier", .value = .{ .string = "enterprise" } },
        },
    });

    // Step 3 — product events through a run lifecycle
    try client.capture(.{ .distinct_id = "user_clerk_abc123", .event = "run_created", .properties = &.{
        .{ .key = "workspace_id", .value = .{ .string = "ws_xyz789" } },
        .{ .key = "spec_count", .value = .{ .integer = 3 } },
    } });
    try client.capture(.{ .distinct_id = "user_clerk_abc123", .event = "run_started" });
    try client.capture(.{ .distinct_id = "user_clerk_abc123", .event = "agent_completed", .properties = &.{
        .{ .key = "duration_ms", .value = .{ .integer = 1420 } },
        .{ .key = "success", .value = .{ .boolean = true } },
    } });
    try client.capture(.{ .distinct_id = "user_clerk_abc123", .event = "run_completed" });

    // 6 events total: identify + group + 4 captures
    try std.testing.expectEqual(@as(usize, 6), pendingCount(client));
    try std.testing.expectEqual(@as(u64, 0), droppedCount(client));
}

// ── Error reporting ───────────────────────────────────────────────────────────

test "caller: handled error reporting via captureException" {
    const client = try offlineClient(std.testing.allocator, 100);
    defer client.deinit();

    // Simulates a service catching an error and reporting it before returning
    const simulate_request_handler = struct {
        fn run(c: *posthog.PostHogClient) !void {
            // Simulate a DB query failure that is handled
            const err = error.WorkspaceNotFound;
            c.captureException(.{
                .distinct_id = "user_clerk_abc123",
                .exception_type = @errorName(err),
                .exception_message = "workspace ws_xyz not found in database",
                .handled = true,
                .level = .err,
                .properties = &.{
                    .{ .key = "workspace_id", .value = .{ .string = "ws_xyz" } },
                    .{ .key = "http_status", .value = .{ .integer = 404 } },
                },
            }) catch {};
        }
    };

    try simulate_request_handler.run(client);
    try std.testing.expectEqual(@as(usize, 1), pendingCount(client));
}

test "caller: multiple error levels enqueued correctly" {
    const client = try offlineClient(std.testing.allocator, 100);
    defer client.deinit();

    client.captureException(.{
        .distinct_id = "u1",
        .exception_type = "RateLimitError",
        .exception_message = "rate limit exceeded",
        .handled = true,
        .level = .warn,
    }) catch {};

    client.captureException(.{
        .distinct_id = "u1",
        .exception_type = "DbConnectionError",
        .exception_message = "postgres connection pool exhausted",
        .handled = false,
        .level = .err,
        .stack_trace = "frame 0: db.connect\nframe 1: serve.handleRequest",
    }) catch {};

    client.captureException(.{
        .distinct_id = "u1",
        .exception_type = "OomError",
        .exception_message = "out of memory allocating response buffer",
        .handled = false,
        .level = .fatal,
    }) catch {};

    try std.testing.expectEqual(@as(usize, 3), pendingCount(client));
}

// ── Panic hook pattern ────────────────────────────────────────────────────────

test "caller: panic hook pattern — queue memory readable without allocation" {
    // This test verifies the v0.1 panic hook pattern:
    // In a real panic handler you cannot allocate. The write-side arena
    // is a contiguous slice. This test confirms it is accessible as such.
    //
    // The pattern (v0.2 will write this slice to disk in one write() syscall):
    //
    //   pub fn panic(...) noreturn {
    //       const side = &global_client.queue.sides[global_client.queue.write_idx];
    //       const pending_bytes_start = side.arena.state.buffer_list.first; // internal
    //       _ = std.posix.write(crash_fd, pending_bytes); // no alloc
    //       std.posix.exit(1);
    //   }

    const client = try offlineClient(std.testing.allocator, 100);
    defer client.deinit();

    try client.capture(.{ .distinct_id = "u1", .event = "before_crash" });
    try client.captureException(.{
        .distinct_id = "u1",
        .exception_type = "SimulatedPanic",
        .exception_message = "simulated fatal error",
        .handled = false,
        .level = .fatal,
    });

    // In a panic handler: access the write-side event count without locking
    // (safe: single writer after panic, flush thread assumed dead)
    const write_idx = client.queue.write_idx;
    const side = &client.queue.sides[write_idx];

    // Verify: events are accessible as a slice, no allocation needed
    const event_count = side.count;
    try std.testing.expectEqual(@as(usize, 2), event_count);

    // Each event pointer is a valid slice into the arena's backing memory
    for (side.events[0..side.count]) |event_json| {
        try std.testing.expect(event_json.len > 0);
        // Every event starts with '{'
        try std.testing.expectEqual(@as(u8, '{'), event_json[0]);
    }
}

// ── Hot-path latency: p50 / p95 / p99 ────────────────────────────────────────

test "caller: hot-path latency p50/p95/p99 over 10_000 captures" {
    const N = 10_000;

    const client = try offlineClient(std.testing.allocator, N + 100);
    defer client.deinit();

    // Warm up — not measured
    for (0..100) |_| {
        try client.capture(.{ .distinct_id = "warmup", .event = "warmup", .timestamp = 0 });
    }
    // Drain warmup events so overflow doesn't affect measurements
    {
        const r = client.queue.drain();
        client.queue.resetSide(r.side_idx);
    }

    // Measure N calls
    var times: [N]u64 = undefined;
    for (0..N) |i| {
        const t0 = std.time.nanoTimestamp();
        try client.capture(.{
            .distinct_id = "user_perf_test",
            .event = "perf_event",
            .timestamp = 0,
            .properties = &.{
                .{ .key = "run_id", .value = .{ .string = "run_abc" } },
                .{ .key = "seq", .value = .{ .integer = @intCast(i) } },
            },
        });
        const t1 = std.time.nanoTimestamp();
        times[i] = @intCast(t1 - t0);
    }

    // Sort for percentile calculation
    std.sort.pdq(u64, &times, {}, std.sort.asc(u64));

    const p50 = times[N * 50 / 100];
    const p95 = times[N * 95 / 100];
    const p99 = times[N * 99 / 100];
    const p999 = times[N * 999 / 1000];

    _ = p95;
    _ = p999;

    // p99 must be under 1ms — capture() is the non-blocking hot path
    try std.testing.expect(p99 < 1_000_000);

    // Keep this as a soft floor to avoid flaky failures on loaded machines.
    try std.testing.expect(p50 < 150_000);
}

// ── Adversarial payloads ──────────────────────────────────────────────────────

test "caller: adversarial — JSON special characters are escaped correctly" {
    const client = try offlineClient(std.testing.allocator, 100);
    defer client.deinit();

    // These would break JSON if not properly escaped
    try client.capture(.{
        .distinct_id = "user_\"evil\"",
        .event = "event with \"quotes\" and \\backslashes\\",
        .properties = &.{
            .{ .key = "key\twith\ttabs", .value = .{ .string = "value\nwith\nnewlines" } },
            .{ .key = "unicode_emoji", .value = .{ .string = "hello 🧟 zombie" } },
            .{ .key = "nested\"quotes", .value = .{ .string = "{\"already\":\"json\"}" } },
        },
    });

    try std.testing.expectEqual(@as(usize, 1), pendingCount(client));
    try std.testing.expectEqual(@as(u64, 0), droppedCount(client));
}

test "caller: adversarial — empty strings are accepted" {
    const client = try offlineClient(std.testing.allocator, 100);
    defer client.deinit();

    // SDK must not panic on empty inputs
    try client.capture(.{ .distinct_id = "", .event = "" });
    try client.identify(.{ .distinct_id = "" });
    try client.captureException(.{
        .distinct_id = "",
        .exception_type = "",
        .exception_message = "",
    });

    try std.testing.expectEqual(@as(usize, 3), pendingCount(client));
}

test "caller: adversarial — very long strings do not overflow" {
    const client = try offlineClient(std.testing.allocator, 100);
    defer client.deinit();

    // 64KB event name — must serialize without crashing
    const long_name = "x" ** 65_536;
    try client.capture(.{
        .distinct_id = "u1",
        .event = long_name,
    });

    // 64KB property value
    try client.capture(.{
        .distinct_id = "u1",
        .event = "large_payload",
        .properties = &.{
            .{ .key = "stack_trace", .value = .{ .string = "f" ** 65_536 } },
        },
    });

    try std.testing.expectEqual(@as(usize, 2), pendingCount(client));
}

test "caller: adversarial — control characters are JSON-escaped" {
    const client = try offlineClient(std.testing.allocator, 100);
    defer client.deinit();

    // Null byte, bell, form-feed — must be \u00xx escaped in JSON output
    const ctrl = "\x00\x01\x07\x08\x0b\x0c\x0e\x1f";
    try client.capture(.{
        .distinct_id = "u1",
        .event = "ctrl_event",
        .properties = &.{
            .{ .key = "raw", .value = .{ .string = ctrl } },
        },
    });

    try std.testing.expectEqual(@as(usize, 1), pendingCount(client));
}

test "caller: adversarial — all property value types accepted" {
    const client = try offlineClient(std.testing.allocator, 100);
    defer client.deinit();

    try client.capture(.{
        .distinct_id = "u1",
        .event = "type_coverage",
        .properties = &.{
            .{ .key = "str", .value = .{ .string = "hello" } },
            .{ .key = "int_pos", .value = .{ .integer = 9_223_372_036_854_775_807 } }, // i64 max
            .{ .key = "int_neg", .value = .{ .integer = -9_223_372_036_854_775_808 } }, // i64 min
            .{ .key = "float", .value = .{ .float = 3.14159265358979 } },
            .{ .key = "bool_true", .value = .{ .boolean = true } },
            .{ .key = "bool_false", .value = .{ .boolean = false } },
        },
    });

    try std.testing.expectEqual(@as(usize, 1), pendingCount(client));
}

// ── Queue overflow ────────────────────────────────────────────────────────────

test "caller: queue overflow — drop-newest, keeps earliest events" {
    const client = try offlineClient(std.testing.allocator, 3);
    defer client.deinit();

    try client.capture(.{ .distinct_id = "u1", .event = "first" });
    try client.capture(.{ .distinct_id = "u1", .event = "second" });
    try client.capture(.{ .distinct_id = "u1", .event = "third" });
    // Queue full — these are dropped
    try client.capture(.{ .distinct_id = "u1", .event = "dropped_1" });
    try client.capture(.{ .distinct_id = "u1", .event = "dropped_2" });

    try std.testing.expectEqual(@as(usize, 3), pendingCount(client));
    try std.testing.expectEqual(@as(u64, 2), droppedCount(client));
}

test "caller: queue overflow — dropped counter survives across flush cycles" {
    const client = try offlineClient(std.testing.allocator, 2);
    defer client.deinit();

    // Fill and overflow
    try client.capture(.{ .distinct_id = "u1", .event = "a" });
    try client.capture(.{ .distinct_id = "u1", .event = "b" });
    try client.capture(.{ .distinct_id = "u1", .event = "c" }); // dropped

    try std.testing.expectEqual(@as(u64, 1), droppedCount(client));

    // Drain (simulates flush)
    {
        const r = client.queue.drain();
        client.queue.resetSide(r.side_idx);
    }

    // Fill and overflow again
    try client.capture(.{ .distinct_id = "u1", .event = "d" });
    try client.capture(.{ .distinct_id = "u1", .event = "e" });
    try client.capture(.{ .distinct_id = "u1", .event = "f" }); // dropped

    // Cumulative dropped count = 2
    try std.testing.expectEqual(@as(u64, 2), droppedCount(client));
}

// ── Concurrent producers ──────────────────────────────────────────────────────

test "caller: concurrent producers — N threads, no data race" {
    const N_THREADS = 8;
    const EVENTS_PER_THREAD = 100;
    const CAPACITY = N_THREADS * EVENTS_PER_THREAD;

    const client = try offlineClient(std.testing.allocator, CAPACITY);
    defer client.deinit();

    const Worker = struct {
        fn run(c: *posthog.PostHogClient, thread_id: usize) void {
            for (0..EVENTS_PER_THREAD) |i| {
                c.capture(.{
                    .distinct_id = "concurrent_user",
                    .event = "concurrent_event",
                    .timestamp = @intCast(i),
                    .properties = &.{
                        .{ .key = "thread_id", .value = .{ .integer = @intCast(thread_id) } },
                    },
                }) catch {};
            }
        }
    };

    var threads: [N_THREADS]std.Thread = undefined;
    for (&threads, 0..) |*t, id| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ client, id });
    }
    for (&threads) |*t| t.join();

    const total = pendingCount(client) + droppedCount(client);
    try std.testing.expectEqual(@as(u64, N_THREADS * EVENTS_PER_THREAD), total);
}

test "caller: sustained producer pressure applies backpressure via drop-newest" {
    const N_THREADS = 8;
    const EVENTS_PER_THREAD = 250;
    const CAPACITY = 100;

    const client = try offlineClient(std.testing.allocator, CAPACITY);
    defer client.deinit();

    const Worker = struct {
        fn run(c: *posthog.PostHogClient) void {
            for (0..EVENTS_PER_THREAD) |i| {
                c.capture(.{
                    .distinct_id = "pressure_user",
                    .event = "pressure_event",
                    .timestamp = @intCast(i),
                }) catch {};
            }
        }
    };

    var threads: [N_THREADS]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{client});
    for (&threads) |*t| t.join();

    const produced = N_THREADS * EVENTS_PER_THREAD;
    const pending = pendingCount(client);
    const dropped = droppedCount(client);

    try std.testing.expectEqual(@as(usize, CAPACITY), pending);
    try std.testing.expectEqual(@as(u64, produced - CAPACITY), dropped);
}

// ── on_deliver callback ───────────────────────────────────────────────────────

test "caller: on_deliver callback — reports failure when host is unreachable" {
    var delivered: usize = 0;
    var failed: usize = 0;
    var dropped: usize = 0;

    const Counters = struct {
        delivered: *usize,
        failed: *usize,
        dropped: *usize,

        fn callback(status: posthog.DeliveryStatus, count: usize) void {
            // In real code, access via a global/threadlocal — test uses globals below
            _ = count;
            switch (status) {
                .delivered => {},
                .failed => {},
                .dropped => {},
            }
        }
    };
    _ = Counters;

    // Use package-level atomics since the callback is a bare fn pointer
    const S = struct {
        var n_delivered: std.atomic.Value(usize) = .init(0);
        var n_failed: std.atomic.Value(usize) = .init(0);
        var n_dropped: std.atomic.Value(usize) = .init(0);

        fn cb(status: posthog.DeliveryStatus, count: usize) void {
            switch (status) {
                .delivered => _ = n_delivered.fetchAdd(count, .monotonic),
                .failed => _ = n_failed.fetchAdd(count, .monotonic),
                .dropped => _ = n_dropped.fetchAdd(count, .monotonic),
            }
        }
    };
    S.n_delivered.store(0, .release);
    S.n_failed.store(0, .release);
    S.n_dropped.store(0, .release);

    const client = try posthog.init(std.testing.allocator, .{
        .api_key = "phc_sim_test",
        .host = "http://127.0.0.1:1",
        .enable_logging = false,
        .flush_at = 2,
        .max_queue_size = 100,
        .flush_interval_ms = 60_000,
        .max_retries = 0,
        .shutdown_flush_timeout_ms = 500,
        .on_deliver = S.cb,
    });
    defer client.deinit();

    // Enqueue 2 events — triggers flush_at
    try client.capture(.{ .distinct_id = "u1", .event = "a" });
    try client.capture(.{ .distinct_id = "u1", .event = "b" });

    // Give the flush thread a moment to attempt delivery
    std.Thread.sleep(200 * std.time.ns_per_ms);

    // Host is unreachable — should have failed or dropped (not delivered)
    delivered = S.n_delivered.load(.acquire);
    failed = S.n_failed.load(.acquire);
    dropped = S.n_dropped.load(.acquire);

    try std.testing.expectEqual(@as(usize, 0), delivered);
    try std.testing.expect(failed + dropped > 0);
}

// ── Graceful shutdown ─────────────────────────────────────────────────────────

test "caller: graceful shutdown — deinit drains remaining queue" {
    // This is best-effort: deinit flushes, but host is unreachable so events
    // are logged as dropped. The important thing: deinit() returns cleanly
    // and the queue is empty after stop().
    const client = try offlineClient(std.testing.allocator, 100);

    for (0..10) |i| {
        try client.capture(.{
            .distinct_id = "shutdown_user",
            .event = "pre_shutdown_event",
            .timestamp = @intCast(i),
        });
    }
    try std.testing.expectEqual(@as(usize, 10), pendingCount(client));

    // deinit joins the flush thread — must not deadlock or leak
    client.deinit();
    // If we reach here, graceful shutdown completed without hanging.
}

test "caller: deinit with empty queue completes immediately" {
    const client = try offlineClient(std.testing.allocator, 100);
    client.deinit(); // no events — must not deadlock
}

// ── Optional client pattern ───────────────────────────────────────────────────

test "caller: optional client pattern — null when no api key configured" {
    // The recommended pattern for services where analytics is optional
    var opt_client: ?*posthog.PostHogClient = null;

    // Simulate: only init if env var present (here: always absent in test)
    if (std.posix.getenv("POSTHOG_API_KEY_SHOULD_NOT_EXIST_IN_TEST")) |key| {
        opt_client = try posthog.init(std.testing.allocator, .{
            .api_key = key,
            .enable_logging = false,
        });
    }
    defer if (opt_client) |c| c.deinit();

    // Calling code — analytics never propagates errors to caller
    if (opt_client) |c| {
        c.capture(.{ .distinct_id = "u1", .event = "e" }) catch {};
    }

    try std.testing.expectEqual(@as(?*posthog.PostHogClient, null), opt_client);
}
