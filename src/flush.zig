//! Background flush thread: drains the event queue and delivers to PostHog.
//!
//! Wakes on:
//!   1. Timer tick (flush_interval_ms)
//!   2. Queue reaching flush_at threshold (signaled by enqueue)
//!   3. Shutdown signal from deinit()
//!
//! All network I/O happens in this thread. The capture() hot path never blocks on I/O.

const std = @import("std");
const batch = @import("batch.zig");
const transport = @import("transport.zig");
const retry = @import("retry.zig");
const types = @import("types.zig");

const log = std.log.scoped(.posthog);

const PostBatchFn = *const fn (
    allocator: std.mem.Allocator,
    host: []const u8,
    api_key: []const u8,
    events: []const []const u8,
) transport.TransportError!u16;

const BackoffFn = *const fn (attempt: u32, base_ms: u64, max_ms: u64) u64;
const SleepFn = *const fn (ns: u64) void;

pub const FlushConfig = struct {
    host: []const u8,
    api_key: []const u8,
    enable_logging: bool,
    flush_interval_ms: u64,
    max_retries: u32,
    on_deliver: ?*const fn (status: types.DeliveryStatus, event_count: usize) void,
    post_batch_fn: ?PostBatchFn = null,
    backoff_fn: ?BackoffFn = null,
    sleep_fn: ?SleepFn = null,
};

/// Heap-allocated state shared between FlushThread and the background thread.
/// Lives for the full duration of the thread — outlives the spawn() stack frame.
const ThreadCtx = struct {
    shutdown: std.atomic.Value(bool),
    queue: *batch.Queue,
    allocator: std.mem.Allocator,
    config: FlushConfig,
};

pub const FlushThread = struct {
    thread: std.Thread,
    ctx: *ThreadCtx,

    pub fn spawn(
        allocator: std.mem.Allocator,
        queue: *batch.Queue,
        config: FlushConfig,
    ) !FlushThread {
        const ctx = try allocator.create(ThreadCtx);
        errdefer allocator.destroy(ctx);
        ctx.* = .{
            .shutdown = std.atomic.Value(bool).init(false),
            .queue = queue,
            .allocator = allocator,
            .config = config,
        };

        const thread = try std.Thread.spawn(.{}, flushLoop, .{ctx});
        return .{ .thread = thread, .ctx = ctx };
    }

    /// Signal shutdown, drain remaining events, and join the thread.
    /// In v0.1, join is unbounded — the thread always runs to completion.
    /// timeout_ms is accepted for API stability but not enforced until v0.2.
    pub fn stop(self: *FlushThread, timeout_ms: u64) void {
        _ = timeout_ms; // v0.2: implement timed join using timeout_ms
        self.ctx.shutdown.store(true, .release);
        self.ctx.queue.signal();
        self.thread.join();
        self.ctx.allocator.destroy(self.ctx);
    }
};

fn flushLoop(ctx: *ThreadCtx) void {
    const interval_ns = ctx.config.flush_interval_ms * std.time.ns_per_ms;

    while (!ctx.shutdown.load(.acquire)) {
        ctx.queue.waitForEventsOrTimeout(interval_ns);
        doFlush(ctx);
    }

    // Final drain on shutdown
    doFlush(ctx);
    if (ctx.config.enable_logging) log.info("[posthog] flush thread stopped", .{});
}

fn doFlush(ctx: *ThreadCtx) void {
    // Swap write↔flush sides atomically. Flush thread owns the returned side
    // exclusively — no lock contention during HTTP delivery.
    const result = ctx.queue.drain();
    defer ctx.queue.resetSide(result.side_idx); // one arena reset after delivery

    const events = result.events;
    if (events.len == 0) return;

    if (ctx.config.enable_logging) log.debug("[posthog] flushing {d} events", .{events.len});

    var attempt: u32 = 0;
    while (attempt <= ctx.config.max_retries) : (attempt += 1) {
        if (attempt > 0) {
            const delay = backoffDelayNs(ctx, attempt - 1, 1000, 30_000);
            if (ctx.config.enable_logging) log.debug("[posthog] retry {d}/{d} in {d}ms", .{ attempt, ctx.config.max_retries, delay / std.time.ns_per_ms });
            sleepForNs(ctx, delay);
        }

        const status = postBatch(ctx, events) catch |err| {
            if (ctx.config.enable_logging) log.warn("[posthog] batch POST error: {}", .{err});
            continue;
        };

        if (status >= 200 and status < 300) {
            if (ctx.config.enable_logging) log.debug("[posthog] batch of {d} delivered ({})", .{ events.len, status });
            if (ctx.config.on_deliver) |cb| cb(.delivered, events.len);
            return;
        }

        if (retry.shouldRetry(status)) {
            if (ctx.config.enable_logging) log.warn("[posthog] batch got {d}, will retry", .{status});
            continue;
        }

        // 4xx (not 429): bad data, don't retry
        if (ctx.config.enable_logging) log.warn("[posthog] batch rejected ({d}): dropping {d} events", .{ status, events.len });
        if (ctx.config.on_deliver) |cb| cb(.failed, events.len);
        return;
    }

    if (ctx.config.enable_logging) log.err("[posthog] batch failed after {d} retries: dropping {d} events", .{ ctx.config.max_retries, events.len });
    if (ctx.config.on_deliver) |cb| cb(.dropped, events.len);
}

fn postBatch(ctx: *ThreadCtx, events: []const []const u8) transport.TransportError!u16 {
    if (ctx.config.post_batch_fn) |f| return f(ctx.allocator, ctx.config.host, ctx.config.api_key, events);
    return transport.postBatch(ctx.allocator, ctx.config.host, ctx.config.api_key, events);
}

fn backoffDelayNs(ctx: *ThreadCtx, attempt: u32, base_ms: u64, max_ms: u64) u64 {
    if (ctx.config.backoff_fn) |f| return f(attempt, base_ms, max_ms);
    return retry.backoffNs(attempt, base_ms, max_ms);
}

fn sleepForNs(ctx: *ThreadCtx, ns: u64) void {
    if (ctx.config.sleep_fn) |f| {
        f(ns);
        return;
    }
    std.Thread.sleep(ns);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "integration: flush thread starts, processes queue, and stops cleanly" {
    var q = try batch.Queue.init(std.testing.allocator, 100, 50, false);
    defer q.deinit();

    const cfg = FlushConfig{
        .host = "https://us.i.posthog.com",
        .api_key = "phc_test_noop",
        .enable_logging = false,
        .flush_interval_ms = 100,
        .max_retries = 0,
        .on_deliver = null,
    };

    // Enqueue a few events — they will fail delivery (no real key) but thread must not crash
    q.enqueue("{\"event\":\"test\",\"properties\":{\"distinct_id\":\"u1\"},\"timestamp\":\"1970-01-01T00:00:00.000Z\"}");

    var ft = try FlushThread.spawn(std.testing.allocator, &q, cfg);
    std.Thread.sleep(50 * std.time.ns_per_ms);
    ft.stop(1000);

    // Thread must have fully joined — no dangling state
}

test "integration: flush thread drains queue on shutdown" {
    var q = try batch.Queue.init(std.testing.allocator, 100, 200, false); // flush_at=200 so timer won't auto-flush
    defer q.deinit();

    for (0..5) |_| {
        q.enqueue("{\"event\":\"x\",\"properties\":{\"distinct_id\":\"u\"},\"timestamp\":\"1970-01-01T00:00:00.000Z\"}");
    }

    const cfg = FlushConfig{
        .host = "https://us.i.posthog.com",
        .api_key = "phc_test_noop",
        .enable_logging = false,
        .flush_interval_ms = 60_000, // very long so only shutdown triggers flush
        .max_retries = 0,
        .on_deliver = null,
    };

    var ft = try FlushThread.spawn(std.testing.allocator, &q, cfg);
    ft.stop(2000);

    // After stop(), queue should be drained (events were attempted, either delivered or dropped)
    try std.testing.expectEqual(@as(usize, 0), q.pendingCount());
}

const FlushMock = struct {
    var statuses: [8]u16 = undefined;
    var status_len: usize = 0;
    var next_idx: std.atomic.Value(usize) = .init(0);

    var post_calls: std.atomic.Value(usize) = .init(0);
    var backoff_calls: std.atomic.Value(usize) = .init(0);
    var sleep_calls: std.atomic.Value(usize) = .init(0);

    var delivered: std.atomic.Value(usize) = .init(0);
    var failed: std.atomic.Value(usize) = .init(0);
    var dropped: std.atomic.Value(usize) = .init(0);

    fn reset(seq: []const u16) void {
        @memcpy(statuses[0..seq.len], seq);
        status_len = seq.len;
        next_idx.store(0, .release);
        post_calls.store(0, .release);
        backoff_calls.store(0, .release);
        sleep_calls.store(0, .release);
        delivered.store(0, .release);
        failed.store(0, .release);
        dropped.store(0, .release);
    }

    fn postBatch(
        allocator: std.mem.Allocator,
        host: []const u8,
        api_key: []const u8,
        events: []const []const u8,
    ) transport.TransportError!u16 {
        _ = allocator;
        _ = host;
        _ = api_key;
        _ = events;
        _ = post_calls.fetchAdd(1, .acq_rel);

        const i = next_idx.fetchAdd(1, .acq_rel);
        const idx = if (i < status_len) i else status_len - 1;
        const code = statuses[idx];
        if (code == 0) return transport.TransportError.NetworkError;
        return code;
    }

    fn backoff(attempt: u32, base_ms: u64, max_ms: u64) u64 {
        _ = base_ms;
        _ = max_ms;
        _ = backoff_calls.fetchAdd(1, .acq_rel);
        return (@as(u64, attempt) + 1) * std.time.ns_per_ms;
    }

    fn sleep(ns: u64) void {
        _ = ns;
        _ = sleep_calls.fetchAdd(1, .acq_rel);
    }

    fn onDeliver(status: types.DeliveryStatus, count: usize) void {
        switch (status) {
            .delivered => _ = delivered.fetchAdd(count, .acq_rel),
            .failed => _ = failed.fetchAdd(count, .acq_rel),
            .dropped => _ = dropped.fetchAdd(count, .acq_rel),
        }
    }
};

fn runSingleFlushWithMock(max_retries: u32, seq: []const u16) !void {
    var q = try batch.Queue.init(std.testing.allocator, 8, 8, false);
    defer q.deinit();

    FlushMock.reset(seq);
    q.enqueue("{\"event\":\"x\",\"properties\":{\"distinct_id\":\"u\"},\"timestamp\":\"1970-01-01T00:00:00.000Z\"}");

    var ctx = ThreadCtx{
        .shutdown = std.atomic.Value(bool).init(false),
        .queue = &q,
        .allocator = std.testing.allocator,
        .config = .{
            .host = "http://unused",
            .api_key = "phc_test",
            .enable_logging = false,
            .flush_interval_ms = 60_000,
            .max_retries = max_retries,
            .on_deliver = FlushMock.onDeliver,
            .post_batch_fn = FlushMock.postBatch,
            .backoff_fn = FlushMock.backoff,
            .sleep_fn = FlushMock.sleep,
        },
    };

    doFlush(&ctx);
    try std.testing.expectEqual(@as(usize, 0), q.pendingCount());
}

test "flush: retries on 429 then delivers" {
    try runSingleFlushWithMock(3, &.{ 429, 200 });

    try std.testing.expectEqual(@as(usize, 2), FlushMock.post_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), FlushMock.backoff_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), FlushMock.sleep_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), FlushMock.delivered.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), FlushMock.failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), FlushMock.dropped.load(.acquire));
}

test "flush: non-retry 400 marks failed without retries" {
    try runSingleFlushWithMock(3, &.{400});

    try std.testing.expectEqual(@as(usize, 1), FlushMock.post_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), FlushMock.backoff_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), FlushMock.sleep_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), FlushMock.delivered.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), FlushMock.failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), FlushMock.dropped.load(.acquire));
}

test "flush: max retries exhausted marks dropped" {
    try runSingleFlushWithMock(2, &.{ 503, 503, 503 });

    try std.testing.expectEqual(@as(usize, 3), FlushMock.post_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), FlushMock.backoff_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), FlushMock.sleep_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), FlushMock.delivered.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), FlushMock.failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), FlushMock.dropped.load(.acquire));
}

test "flush: network errors honor max_retries and drop" {
    try runSingleFlushWithMock(1, &.{ 0, 0 });

    try std.testing.expectEqual(@as(usize, 2), FlushMock.post_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), FlushMock.backoff_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), FlushMock.sleep_calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), FlushMock.delivered.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), FlushMock.failed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), FlushMock.dropped.load(.acquire));
}
