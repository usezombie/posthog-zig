//! PostHogClient — the public-facing analytics client.
//!
//! capture(), identify(), group(), captureException() are all non-blocking.
//! They serialize the event and enqueue it to the ring buffer. A background
//! flush thread handles all I/O.

const std = @import("std");
const types = @import("types.zig");
const batch = @import("batch.zig");
const flusher = @import("flush.zig");
const feature_flags = @import("feature_flags.zig");
const transport = @import("transport.zig");

const log = std.log.scoped(.posthog);

pub const PostHogClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: types.Config,
    queue: batch.Queue,
    flush_thread: flusher.FlushThread,
    flag_cache: feature_flags.FlagCache,

    /// Initialize the client and spawn the background flush thread.
    /// Returns a heap-allocated client so &self.queue is a stable address
    /// for the flush thread — no stale pointer on return.
    /// Call `client.deinit()` to flush remaining events and free all resources.
    ///
    /// `io` is threaded through concurrency primitives (Io.Mutex, Io.Event) and
    /// the HTTP client. Pass `posthog.defaultIo()` for the default process-wide
    /// Io, or construct and pass your own `std.Io.Threaded` for a custom backend.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: types.Config) !*PostHogClient {
        const self = try allocator.create(PostHogClient);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.io = io;
        self.config = config;

        self.queue = try batch.Queue.init(allocator, io, config.max_queue_size, config.flush_at, config.enable_logging);
        errdefer self.queue.deinit();

        self.flag_cache = feature_flags.FlagCache.init(allocator, io, config.feature_flag_ttl_ms, 1000);

        self.flush_thread = try flusher.FlushThread.spawn(allocator, io, &self.queue, .{
            .host = config.host,
            .api_key = config.api_key,
            .enable_logging = config.enable_logging,
            .flush_interval_ms = config.flush_interval_ms,
            .max_retries = config.max_retries,
            .on_deliver = config.on_deliver,
        });

        return self;
    }

    pub fn deinit(self: *PostHogClient) void {
        self.flush_thread.stop(self.config.shutdown_flush_timeout_ms);
        self.queue.deinit();
        self.flag_cache.deinit();
        self.allocator.destroy(self);
    }

    // ── Non-blocking capture methods ─────────────────────────────────────────

    pub fn capture(self: *PostHogClient, opts: types.CaptureOptions) !void {
        const ts = opts.timestamp orelse types.nowMs(self.io);
        const json = try serializeEvent(self.allocator, opts.event, opts.distinct_id, opts.properties, ts);
        defer self.allocator.free(json);
        self.queue.enqueue(json);
    }

    pub fn identify(self: *PostHogClient, opts: types.IdentifyOptions) !void {
        const ts = opts.timestamp orelse types.nowMs(self.io);
        const json = try serializeIdentify(self.allocator, opts.distinct_id, opts.properties, ts);
        defer self.allocator.free(json);
        self.queue.enqueue(json);
    }

    pub fn group(self: *PostHogClient, opts: types.GroupOptions) !void {
        const ts = opts.timestamp orelse types.nowMs(self.io);
        const json = try serializeGroup(self.allocator, opts, ts);
        defer self.allocator.free(json);
        self.queue.enqueue(json);
    }

    pub fn captureException(self: *PostHogClient, opts: types.ExceptionOptions) !void {
        const ts = opts.timestamp orelse types.nowMs(self.io);
        const json = try serializeException(self.allocator, opts, ts);
        defer self.allocator.free(json);
        self.queue.enqueue(json);
    }

    // ── Feature flags ─────────────────────────────────────────────────────────

    pub fn isFeatureEnabled(self: *PostHogClient, flag_key: []const u8, distinct_id: []const u8) !bool {
        if (self.flag_cache.isEnabled(distinct_id, flag_key)) |enabled| return enabled;
        try feature_flags.fetchAndCache(&self.flag_cache, self.allocator, self.io, self.config.host, self.config.api_key, distinct_id);
        return self.flag_cache.isEnabled(distinct_id, flag_key) orelse false;
    }

    pub fn getFeatureFlagPayload(self: *PostHogClient, flag_key: []const u8, distinct_id: []const u8) !?[]u8 {
        if (try self.flag_cache.getPayload(self.allocator, distinct_id, flag_key)) |p| return p;
        try feature_flags.fetchAndCache(&self.flag_cache, self.allocator, self.io, self.config.host, self.config.api_key, distinct_id);
        return try self.flag_cache.getPayload(self.allocator, distinct_id, flag_key);
    }

    /// Flush pending events synchronously.
    pub fn flush(self: *PostHogClient) !void {
        const result = self.queue.drain();
        defer self.queue.resetSide(result.side_idx);
        if (result.events.len == 0) return;
        _ = try transport.postBatch(self.allocator, self.io, self.config.host, self.config.api_key, result.events);
    }
};

// ── Serialization helpers ─────────────────────────────────────────────────────

fn serializeEvent(
    allocator: std.mem.Allocator,
    event_name: []const u8,
    distinct_id: []const u8,
    properties: ?[]const types.Property,
    timestamp_ms: i64,
) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\"event\":");
    try types.writeJsonStr(w, event_name);
    try w.writeAll(",\"properties\":{\"distinct_id\":");
    try types.writeJsonStr(w, distinct_id);
    try w.writeAll(",\"$lib\":\"" ++ types.lib_name ++ "\",\"$lib_version\":\"" ++ types.version ++ "\"");

    if (properties) |props| {
        for (props) |prop| {
            try w.writeByte(',');
            try types.writeJsonStr(w, prop.key);
            try w.writeByte(':');
            try types.writePropertyValue(w, prop.value);
        }
    }

    try w.writeAll("},\"timestamp\":\"");
    try types.formatIso8601(w, timestamp_ms);
    try w.writeAll("\"}");

    return aw.toOwnedSlice();
}

fn serializeIdentify(
    allocator: std.mem.Allocator,
    distinct_id: []const u8,
    properties: ?[]const types.Property,
    timestamp_ms: i64,
) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\"event\":\"$identify\",\"properties\":{\"distinct_id\":");
    try types.writeJsonStr(w, distinct_id);
    try w.writeAll(",\"$lib\":\"" ++ types.lib_name ++ "\",\"$lib_version\":\"" ++ types.version ++ "\"");
    try w.writeAll(",\"$set\":{");

    if (properties) |props| {
        for (props, 0..) |prop, i| {
            if (i > 0) try w.writeByte(',');
            try types.writeJsonStr(w, prop.key);
            try w.writeByte(':');
            try types.writePropertyValue(w, prop.value);
        }
    }

    try w.writeAll("}},\"timestamp\":\"");
    try types.formatIso8601(w, timestamp_ms);
    try w.writeAll("\"}");

    return aw.toOwnedSlice();
}

fn serializeGroup(
    allocator: std.mem.Allocator,
    opts: types.GroupOptions,
    timestamp_ms: i64,
) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\"event\":\"$groupidentify\",\"properties\":{\"distinct_id\":");
    try types.writeJsonStr(w, opts.distinct_id);
    try w.writeAll(",\"$lib\":\"" ++ types.lib_name ++ "\",\"$lib_version\":\"" ++ types.version ++ "\"");
    try w.writeAll(",\"$group_type\":");
    try types.writeJsonStr(w, opts.group_type);
    try w.writeAll(",\"$group_key\":");
    try types.writeJsonStr(w, opts.group_key);
    try w.writeAll(",\"$group_set\":{");

    if (opts.properties) |props| {
        for (props, 0..) |prop, i| {
            if (i > 0) try w.writeByte(',');
            try types.writeJsonStr(w, prop.key);
            try w.writeByte(':');
            try types.writePropertyValue(w, prop.value);
        }
    }

    try w.writeAll("}},\"timestamp\":\"");
    try types.formatIso8601(w, timestamp_ms);
    try w.writeAll("\"}");

    return aw.toOwnedSlice();
}

fn serializeException(
    allocator: std.mem.Allocator,
    opts: types.ExceptionOptions,
    timestamp_ms: i64,
) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\"event\":\"$exception\",\"properties\":{\"distinct_id\":");
    try types.writeJsonStr(w, opts.distinct_id);
    try w.writeAll(",\"$lib\":\"" ++ types.lib_name ++ "\",\"$lib_version\":\"" ++ types.version ++ "\"");
    try w.writeAll(",\"$exception_type\":");
    try types.writeJsonStr(w, opts.exception_type);
    try w.writeAll(",\"$exception_message\":");
    try types.writeJsonStr(w, opts.exception_message);
    try w.print(",\"$exception_handled\":{},\"$exception_level\":", .{opts.handled});
    try types.writeJsonStr(w, opts.level.string());

    if (opts.stack_trace) |st| {
        try w.writeAll(",\"$exception_stack_trace_raw\":");
        try types.writeJsonStr(w, st);
    }

    if (opts.properties) |props| {
        for (props) |prop| {
            try w.writeByte(',');
            try types.writeJsonStr(w, prop.key);
            try w.writeByte(':');
            try types.writePropertyValue(w, prop.value);
        }
    }

    try w.writeAll("},\"timestamp\":\"");
    try types.formatIso8601(w, timestamp_ms);
    try w.writeAll("\"}");

    return aw.toOwnedSlice();
}

// ── Tests ─────────────────────────────────────────────────────────────────────

fn testIo() std.Io {
    return std.Options.debug_threaded_io.?.io();
}

test "serializeEvent: produces valid JSON with required fields" {
    const allocator = std.testing.allocator;
    const json = try serializeEvent(allocator, "run_started", "user_123", &.{
        .{ .key = "workspace_id", .value = .{ .string = "ws_abc" } },
    }, 0);
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("run_started", obj.get("event").?.string);
    const props = obj.get("properties").?.object;
    try std.testing.expectEqualStrings("user_123", props.get("distinct_id").?.string);
    try std.testing.expectEqualStrings("posthog-zig", props.get("$lib").?.string);
    try std.testing.expectEqualStrings("ws_abc", props.get("workspace_id").?.string);
}

test "serializeEvent: null properties has only built-in keys" {
    const allocator = std.testing.allocator;
    const json = try serializeEvent(allocator, "ping", "u1", null, 0);
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const props = parsed.value.object.get("properties").?.object;
    try std.testing.expectEqual(@as(usize, 3), props.count());
}

test "serializeIdentify: produces $identify event with $set" {
    const allocator = std.testing.allocator;
    const json = try serializeIdentify(allocator, "u1", &.{
        .{ .key = "email", .value = .{ .string = "alice@example.com" } },
    }, 0);
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("$identify", parsed.value.object.get("event").?.string);
    const set = parsed.value.object.get("properties").?.object.get("$set").?.object;
    try std.testing.expectEqualStrings("alice@example.com", set.get("email").?.string);
}

test "serializeGroup: produces $groupidentify event" {
    const allocator = std.testing.allocator;
    const json = try serializeGroup(allocator, .{
        .distinct_id = "u1",
        .group_type = "workspace",
        .group_key = "ws_abc",
        .properties = &.{.{ .key = "name", .value = .{ .string = "Acme" } }},
    }, 0);
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("$groupidentify", parsed.value.object.get("event").?.string);
    const props = parsed.value.object.get("properties").?.object;
    try std.testing.expectEqualStrings("workspace", props.get("$group_type").?.string);
    try std.testing.expectEqualStrings("ws_abc", props.get("$group_key").?.string);
}

test "serializeException: produces $exception with PostHog Error Tracking fields" {
    const allocator = std.testing.allocator;
    const json = try serializeException(allocator, .{
        .distinct_id = "u1",
        .exception_type = "WorkspaceError",
        .exception_message = "not found: ws_abc",
        .handled = false,
        .level = .err,
    }, 0);
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("$exception", parsed.value.object.get("event").?.string);
    const props = parsed.value.object.get("properties").?.object;
    try std.testing.expectEqualStrings("WorkspaceError", props.get("$exception_type").?.string);
    try std.testing.expectEqualStrings("not found: ws_abc", props.get("$exception_message").?.string);
    try std.testing.expect(!props.get("$exception_handled").?.bool);
    try std.testing.expectEqualStrings("error", props.get("$exception_level").?.string);
}

test "serializeException: stack_trace included when set" {
    const allocator = std.testing.allocator;
    const json = try serializeException(allocator, .{
        .distinct_id = "u1",
        .exception_type = "OomError",
        .exception_message = "out of memory",
        .stack_trace = "frame 0: alloc\nframe 1: main",
    }, 0);
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const props = parsed.value.object.get("properties").?.object;
    try std.testing.expect(props.get("$exception_stack_trace_raw") != null);
}

test "flush: empty queue is a no-op (no network call)" {
    const c = try PostHogClient.init(std.testing.allocator, testIo(), .{
        .api_key = "phc_test",
        .enable_logging = false,
        .flush_interval_ms = 60_000,
        .flush_at = 1000,
        .max_retries = 0,
    });
    defer c.deinit();
    try c.flush();
    try std.testing.expectEqual(@as(usize, 0), c.queue.pendingCount());
}

test "flush: drains pending events (queue empties regardless of network outcome)" {
    const c = try PostHogClient.init(std.testing.allocator, testIo(), .{
        .api_key = "phc_test",
        .enable_logging = false,
        .flush_interval_ms = 60_000,
        .flush_at = 1000,
        .max_retries = 0,
    });
    defer c.deinit();

    try c.capture(.{ .distinct_id = "u1", .event = "x", .timestamp = 0 });
    try std.testing.expectEqual(@as(usize, 1), c.queue.pendingCount());

    c.flush() catch {};
    try std.testing.expectEqual(@as(usize, 0), c.queue.pendingCount());
}

test "integration: PostHogClient init and deinit without network" {
    const client = try PostHogClient.init(std.testing.allocator, testIo(), .{
        .api_key = "phc_test",
        .enable_logging = false,
        .flush_interval_ms = 60_000,
        .max_retries = 0,
        .flush_at = 1000,
    });
    defer client.deinit();

    try client.capture(.{ .distinct_id = "u1", .event = "test_event", .timestamp = 0 });
    try std.testing.expectEqual(@as(usize, 1), client.queue.pendingCount());
}

test "integration: capture is non-blocking (avg < 1ms per call for 1000 events)" {
    const client = try PostHogClient.init(std.testing.allocator, testIo(), .{
        .api_key = "phc_test",
        .enable_logging = false,
        .flush_interval_ms = 60_000,
        .max_retries = 0,
        .flush_at = 10_000,
        .max_queue_size = 10_000,
    });
    defer client.deinit();

    const start = types.monotonicNs(client.io);
    for (0..1000) |_| {
        try client.capture(.{ .distinct_id = "u1", .event = "bench", .timestamp = 0 });
    }
    const elapsed_ns = types.monotonicNs(client.io) - start;
    const avg_ns = @divFloor(elapsed_ns, 1000);

    // Valgrind instrumentation in memleak mode adds heavy runtime overhead.
    const env = std.Options.debug_threaded_io.?.environ.process_environ;
    const in_memleak_mode = env.getPosix("POSTHOG_MEMLEAK_MODE") != null;
    const max_avg_ns: i128 = if (in_memleak_mode) 50_000_000 else 1_000_000;
    try std.testing.expect(avg_ns < max_avg_ns);
}
