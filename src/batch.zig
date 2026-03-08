//! Double-buffer arena event queue.
//!
//! Two arena allocators alternate between write and flush roles.
//!
//! capture() serializes events into the write-side arena — non-blocking, < 1μs.
//! The flush thread swaps sides (O(1) under mutex), then owns the flush-side
//! arena exclusively with no lock contention during HTTP delivery.
//! After delivery, arena.reset() reclaims all flush-side memory in one shot.
//!
//! Memory layout:
//!
//!   Arena A (write side)          Arena B (flush side)
//!   [ev1_json][ev2_json]...       [being POSTed]
//!   one contiguous backing alloc  one contiguous backing alloc
//!
//! Overflow: when the write-side arena is at capacity, new events are dropped
//! (drop-newest). The arena cannot free individual entries; all memory for a
//! side is reclaimed together on reset after successful delivery.
//!
//! See docs/ARCHITECTURE.md for design rationale and v0.2 plans.

const std = @import("std");

const log = std.log.scoped(.posthog);

// ── Side ──────────────────────────────────────────────────────────────────────

/// One side of the double-buffer.
const Side = struct {
    arena: std.heap.ArenaAllocator,
    /// Pointers into arena memory. Slice pre-allocated from gpa at init.
    events: [][]const u8,
    count: usize,

    fn init(gpa: std.mem.Allocator, max_size: usize) !Side {
        return .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .events = try gpa.alloc([]const u8, max_size),
            .count = 0,
        };
    }

    fn deinit(self: *Side, gpa: std.mem.Allocator) void {
        self.arena.deinit();
        gpa.free(self.events);
    }

    fn written(self: *const Side) []const []const u8 {
        return self.events[0..self.count];
    }

    /// Reset for reuse. All event strings are freed in one arena reset.
    fn reset(self: *Side) void {
        _ = self.arena.reset(.retain_capacity);
        self.count = 0;
    }
};

// ── Queue ─────────────────────────────────────────────────────────────────────

/// Result of drain(). Events are valid until resetSide() is called.
pub const DrainResult = struct {
    events: []const []const u8,
    side_idx: u1,
};

pub const Queue = struct {
    gpa: std.mem.Allocator,
    sides: [2]Side,
    write_idx: u1,
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    max_size: usize,
    flush_at: usize,
    log_enabled: bool,
    dropped: u64,

    pub fn init(gpa: std.mem.Allocator, max_size: usize, flush_at: usize, log_enabled: bool) !Queue {
        var side_a = try Side.init(gpa, max_size);
        errdefer side_a.deinit(gpa);
        const side_b = try Side.init(gpa, max_size);
        return .{
            .gpa = gpa,
            .sides = .{ side_a, side_b },
            .write_idx = 0,
            .mutex = .{},
            .cond = .{},
            .max_size = max_size,
            .flush_at = flush_at,
            .log_enabled = log_enabled,
            .dropped = 0,
        };
    }

    pub fn deinit(self: *Queue) void {
        self.sides[0].deinit(self.gpa);
        self.sides[1].deinit(self.gpa);
    }

    /// Enqueue a serialized event JSON string. Non-blocking.
    /// Copies json into the write-side arena. Drops the event if at capacity.
    pub fn enqueue(self: *Queue, json: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const side = &self.sides[self.write_idx];

        if (side.count >= self.max_size) {
            self.dropped += 1;
            if (self.log_enabled) log.warn("[posthog] queue full: event dropped (total dropped: {d})", .{self.dropped});
            return;
        }

        const owned = side.arena.allocator().dupe(u8, json) catch {
            if (self.log_enabled) log.warn("[posthog] enqueue: arena alloc failed, event dropped", .{});
            return;
        };

        side.events[side.count] = owned;
        side.count += 1;

        if (side.count >= self.flush_at) {
            self.cond.signal();
        }
    }

    /// Swap write and flush sides atomically (O(1) under mutex).
    /// Returns the flush-side events and their side index.
    /// Events are valid until resetSide() is called with the returned index.
    /// The flush thread owns the returned side exclusively — no lock needed
    /// between drain() and resetSide().
    pub fn drain(self: *Queue) DrainResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        const flush_idx = self.write_idx;
        self.write_idx ^= 1;

        return .{
            .events = self.sides[flush_idx].written(),
            .side_idx = flush_idx,
        };
    }

    /// Reset the flush side after delivery. No lock needed — the flush thread
    /// owns this side exclusively between drain() and resetSide().
    /// Reclaims all flush-side arena memory in one shot.
    pub fn resetSide(self: *Queue, idx: u1) void {
        self.sides[idx].reset();
    }

    pub fn pendingCount(self: *Queue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sides[0].count + self.sides[1].count;
    }

    pub fn droppedCount(self: *Queue) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.dropped;
    }

    /// Block until events are available or timeout expires.
    pub fn waitForEventsOrTimeout(self: *Queue, timeout_ns: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.sides[self.write_idx].count == 0) {
            self.cond.timedWait(&self.mutex, timeout_ns) catch {};
        }
    }

    /// Wake the flush thread immediately (e.g. on shutdown).
    pub fn signal(self: *Queue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.cond.broadcast();
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "queue: enqueue and drain single event" {
    var q = try Queue.init(std.testing.allocator, 10, 5, false);
    defer q.deinit();

    q.enqueue("{\"event\":\"test\"}");
    try std.testing.expectEqual(@as(usize, 1), q.pendingCount());

    const r = q.drain();

    try std.testing.expectEqual(@as(usize, 1), r.events.len);
    try std.testing.expectEqualStrings("{\"event\":\"test\"}", r.events[0]);
    // pendingCount includes in-flight (drained but not yet reset) events
    try std.testing.expectEqual(@as(usize, 1), q.pendingCount());
    q.resetSide(r.side_idx);
    try std.testing.expectEqual(@as(usize, 0), q.pendingCount());
}

test "queue: drain from empty returns empty" {
    var q = try Queue.init(std.testing.allocator, 10, 5, false);
    defer q.deinit();

    const r = q.drain();
    defer q.resetSide(r.side_idx);

    try std.testing.expectEqual(@as(usize, 0), r.events.len);
}

test "queue: overflow drops newest event" {
    var q = try Queue.init(std.testing.allocator, 2, 100, false);
    defer q.deinit();

    q.enqueue("first");
    q.enqueue("second");
    q.enqueue("third"); // dropped — queue full

    try std.testing.expectEqual(@as(usize, 2), q.pendingCount());
    try std.testing.expectEqual(@as(u64, 1), q.droppedCount());

    const r = q.drain();
    defer q.resetSide(r.side_idx);

    try std.testing.expectEqualStrings("first", r.events[0]);
    try std.testing.expectEqualStrings("second", r.events[1]);
}

test "queue: arena resets cleanly across two flush cycles" {
    var q = try Queue.init(std.testing.allocator, 10, 100, false);
    defer q.deinit();

    // Cycle 1
    q.enqueue("{\"event\":\"a\"}");
    q.enqueue("{\"event\":\"b\"}");
    {
        const r = q.drain();
        defer q.resetSide(r.side_idx);
        try std.testing.expectEqual(@as(usize, 2), r.events.len);
    }

    // Cycle 2 — write side flipped then available again after reset
    q.enqueue("{\"event\":\"c\"}");
    {
        const r = q.drain();
        defer q.resetSide(r.side_idx);
        try std.testing.expectEqual(@as(usize, 1), r.events.len);
        try std.testing.expectEqualStrings("{\"event\":\"c\"}", r.events[0]);
    }
}

test "queue: multiple drain cycles accumulate no memory" {
    var q = try Queue.init(std.testing.allocator, 100, 200, false);
    defer q.deinit();

    // 10 flush cycles with 5 events each — all arena memory reclaimed per cycle
    for (0..10) |_| {
        for (0..5) |_| q.enqueue("{\"event\":\"x\"}");
        const r = q.drain();
        q.resetSide(r.side_idx);
    }

    try std.testing.expectEqual(@as(usize, 0), q.pendingCount());
    try std.testing.expectEqual(@as(u64, 0), q.droppedCount());
}

test "integration: concurrent producers enqueue without data race" {
    var q = try Queue.init(std.testing.allocator, 1000, 500, false);
    defer q.deinit();

    const N = 4;
    const PER_THREAD = 50;

    const Producer = struct {
        fn run(queue: *Queue) void {
            for (0..PER_THREAD) |_| {
                queue.enqueue("{\"event\":\"concurrent\"}");
            }
        }
    };

    var threads: [N]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Producer.run, .{&q});
    }
    for (&threads) |*t| t.join();

    const r = q.drain();
    defer q.resetSide(r.side_idx);

    const total = r.events.len + q.droppedCount();
    try std.testing.expectEqual(@as(u64, N * PER_THREAD), total);
}
