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

pub const FlushConfig = struct {
    host: []const u8,
    api_key: []const u8,
    enable_logging: bool,
    flush_interval_ms: u64,
    max_retries: u32,
    on_deliver: ?*const fn (status: types.DeliveryStatus, event_count: usize) void,
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
    /// timeout_ms is advisory — join is unbounded in v0.1.
    pub fn stop(self: *FlushThread, timeout_ms: u64) void {
        _ = timeout_ms;
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
            const delay = retry.backoffNs(attempt - 1, 1000, 30_000);
            if (ctx.config.enable_logging) log.debug("[posthog] retry {d}/{d} in {d}ms", .{ attempt, ctx.config.max_retries, delay / std.time.ns_per_ms });
            std.Thread.sleep(delay);
        }

        const status = transport.postBatch(ctx.allocator, ctx.config.host, ctx.config.api_key, events) catch |err| {
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
