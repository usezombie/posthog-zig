//! PostHog event types, configuration, and shared serialization helpers.

const std = @import("std");

pub const version = "0.1.0";
pub const lib_name = "posthog-zig";

// ── Public types ─────────────────────────────────────────────────────────────

pub const PropertyValue = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
};

pub const Property = struct {
    key: []const u8,
    value: PropertyValue,
};

pub const ExceptionLevel = enum {
    err,
    warn,
    info,
    fatal,

    pub fn string(self: ExceptionLevel) []const u8 {
        return switch (self) {
            .err => "error",
            .warn => "warning",
            .info => "info",
            .fatal => "fatal",
        };
    }
};

pub const DeliveryStatus = enum { delivered, failed, dropped };

pub const Config = struct {
    api_key: []const u8,
    host: []const u8 = "https://us.i.posthog.com",
    enable_logging: bool = true,
    flush_interval_ms: u64 = 10_000,
    flush_at: usize = 20,
    max_queue_size: usize = 1000,
    max_retries: u32 = 3,
    shutdown_flush_timeout_ms: u64 = 5_000,
    feature_flag_ttl_ms: u64 = 60_000,
    on_deliver: ?*const fn (status: DeliveryStatus, event_count: usize) void = null,
};

pub const CaptureOptions = struct {
    distinct_id: []const u8,
    event: []const u8,
    properties: ?[]const Property = null,
    timestamp: ?i64 = null,
};

pub const IdentifyOptions = struct {
    distinct_id: []const u8,
    properties: ?[]const Property = null,
    timestamp: ?i64 = null,
};

pub const GroupOptions = struct {
    distinct_id: []const u8,
    group_type: []const u8,
    group_key: []const u8,
    properties: ?[]const Property = null,
    timestamp: ?i64 = null,
};

pub const ExceptionOptions = struct {
    distinct_id: []const u8,
    exception_type: []const u8,
    exception_message: []const u8,
    handled: bool = true,
    level: ExceptionLevel = .err,
    stack_trace: ?[]const u8 = null,
    properties: ?[]const Property = null,
    timestamp: ?i64 = null,
};

// ── Serialization helpers ─────────────────────────────────────────────────────

/// Write a JSON-encoded string (with surrounding quotes and proper escaping).
/// Works with any writer type (anytype).
pub fn writeJsonStr(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            // Remaining control chars (0x00-0x08, 0x0b, 0x0c, 0x0e-0x1f)
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => |ctrl| try writer.print("\\u{x:04}", .{@as(u16, ctrl)}),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

/// Write a PropertyValue as its JSON representation.
pub fn writePropertyValue(writer: anytype, value: PropertyValue) !void {
    switch (value) {
        .string => |s| try writeJsonStr(writer, s),
        .integer => |i| try writer.print("{d}", .{i}),
        .float => |f| try writer.print("{d}", .{f}),
        .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
    }
}

/// Format epoch milliseconds as ISO 8601 UTC string.
/// Uses Howard Hinnant's civil date algorithm — no stdlib calendar dependency.
pub fn formatIso8601(writer: anytype, epoch_ms: i64) !void {
    const epoch_sec = @divFloor(epoch_ms, 1000);
    const ms_part: u64 = @intCast(@mod(epoch_ms, 1000));

    const days = @divFloor(epoch_sec, 86400);
    const time_of_day = @mod(epoch_sec, 86400);
    const h: u64 = @intCast(@divFloor(time_of_day, 3600));
    const mn: u64 = @intCast(@divFloor(@mod(time_of_day, 3600), 60));
    const s: u64 = @intCast(@mod(time_of_day, 60));

    // Civil date algorithm (Howard Hinnant)
    const z: i64 = days + 719468;
    const era: i64 = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: i64 = z - era * 146097;
    const yoe: i64 = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp: i64 = @divFloor(5 * doy + 2, 153);
    const d: i64 = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m: i64 = if (mp < 10) mp + 3 else mp - 9;
    const year: i64 = if (m <= 2) y + 1 else y;

    // Cast to u64 — Zig 0.15 prints explicit '+' sign for i64 with zero-pad format.
    // All values are guaranteed non-negative for post-epoch timestamps.
    try writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        @as(u64, @intCast(year)), @as(u64, @intCast(m)), @as(u64, @intCast(d)),
        h,                        mn,                    s,
        ms_part,
    });
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "formatIso8601: epoch zero" {
    var aw = std.io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try formatIso8601(&aw.writer, 0);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00.000Z", aw.written());
}

test "formatIso8601: one day" {
    var aw = std.io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try formatIso8601(&aw.writer, 86_400_000);
    try std.testing.expectEqualStrings("1970-01-02T00:00:00.000Z", aw.written());
}

test "formatIso8601: milliseconds preserved" {
    var aw = std.io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try formatIso8601(&aw.writer, 1_500);
    try std.testing.expectEqualStrings("1970-01-01T00:00:01.500Z", aw.written());
}

test "ExceptionLevel.string" {
    try std.testing.expectEqualStrings("error", ExceptionLevel.err.string());
    try std.testing.expectEqualStrings("warning", ExceptionLevel.warn.string());
    try std.testing.expectEqualStrings("info", ExceptionLevel.info.string());
    try std.testing.expectEqualStrings("fatal", ExceptionLevel.fatal.string());
}

test "writeJsonStr: plain string" {
    var aw = std.io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try writeJsonStr(&aw.writer, "hello");
    try std.testing.expectEqualStrings("\"hello\"", aw.written());
}

test "writeJsonStr: special chars escaped" {
    var aw = std.io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try writeJsonStr(&aw.writer, "say \"hi\"");
    try std.testing.expectEqualStrings("\"say \\\"hi\\\"\"", aw.written());
}

test "writePropertyValue: integer negative" {
    var aw = std.io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try writePropertyValue(&aw.writer, .{ .integer = -42 });
    try std.testing.expectEqualStrings("-42", aw.written());
}

test "writeJsonStr: control chars encoded as \\uXXXX" {
    var aw = std.io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try writeJsonStr(&aw.writer, "\x00");
    try std.testing.expectEqualStrings("\"\\u0000\"", aw.written());
    aw.clearRetainingCapacity();
    try writeJsonStr(&aw.writer, "\x1f");
    try std.testing.expectEqualStrings("\"\\u001f\"", aw.written());
    aw.clearRetainingCapacity();
    try writeJsonStr(&aw.writer, "\x08");
    try std.testing.expectEqualStrings("\"\\u0008\"", aw.written());
}

test "writePropertyValue: boolean" {
    var aw = std.io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try writePropertyValue(&aw.writer, .{ .boolean = true });
    try std.testing.expectEqualStrings("true", aw.written());
    aw.clearRetainingCapacity();
    try writePropertyValue(&aw.writer, .{ .boolean = false });
    try std.testing.expectEqualStrings("false", aw.written());
}
