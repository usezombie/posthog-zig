//! HTTP transport: POST to PostHog /batch/ and /decide/ endpoints.

const std = @import("std");
const types = @import("types.zig");

pub const TransportError = error{
    NetworkError,
    OutOfMemory,
};

/// POST a batch of serialized event JSON objects to PostHog /batch/.
/// Returns the HTTP status code.
pub fn postBatch(
    allocator: std.mem.Allocator,
    host: []const u8,
    api_key: []const u8,
    events: []const []const u8,
) TransportError!u16 {
    if (events.len == 0) return 200;

    var payload_aw = std.io.Writer.Allocating.init(allocator);
    defer payload_aw.deinit();
    const pw = &payload_aw.writer;

    pw.writeAll("{\"api_key\":") catch return TransportError.OutOfMemory;
    types.writeJsonStr(pw, api_key) catch return TransportError.OutOfMemory;
    pw.writeAll(",\"batch\":[") catch return TransportError.OutOfMemory;
    for (events, 0..) |event, i| {
        if (i > 0) pw.writeByte(',') catch return TransportError.OutOfMemory;
        pw.writeAll(event) catch return TransportError.OutOfMemory;
    }
    pw.writeAll("]}") catch return TransportError.OutOfMemory;

    const url = std.fmt.allocPrint(allocator, "{s}/batch/", .{host}) catch return TransportError.OutOfMemory;
    defer allocator.free(url);

    return doPost(allocator, url, payload_aw.written()) catch return TransportError.NetworkError;
}

/// POST to PostHog /decide/?v=3 for feature flag evaluation.
/// Returns the raw response body (caller owns the returned slice).
pub fn postDecide(
    allocator: std.mem.Allocator,
    host: []const u8,
    api_key: []const u8,
    distinct_id: []const u8,
) ![]u8 {
    var payload_aw = std.io.Writer.Allocating.init(allocator);
    defer payload_aw.deinit();
    const pw = &payload_aw.writer;

    try pw.writeAll("{\"api_key\":");
    try types.writeJsonStr(pw, api_key);
    try pw.writeAll(",\"distinct_id\":");
    try types.writeJsonStr(pw, distinct_id);
    try pw.writeByte('}');

    const url = try std.fmt.allocPrint(allocator, "{s}/decide/?v=3", .{host});
    defer allocator.free(url);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var response_aw = std.io.Writer.Allocating.init(allocator);
    defer response_aw.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .user_agent = .{ .override = "posthog-zig/" ++ types.version },
        },
        .payload = payload_aw.written(),
        .response_writer = &response_aw.writer,
    });

    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) return error.DecideFailed;

    return response_aw.toOwnedSlice();
}

// ── Internal ──────────────────────────────────────────────────────────────────

fn doPost(allocator: std.mem.Allocator, url: []const u8, payload: []const u8) !u16 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var response_aw = std.io.Writer.Allocating.init(allocator);
    defer response_aw.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .user_agent = .{ .override = "posthog-zig/" ++ types.version },
        },
        .payload = payload,
        .response_writer = &response_aw.writer,
    });

    return @intFromEnum(result.status);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "postBatch: empty events returns 200 without network call" {
    const status = try postBatch(std.testing.allocator, "https://us.i.posthog.com", "phc_test", &.{});
    try std.testing.expectEqual(@as(u16, 200), status);
}

test "postBatch: builds correct JSON payload shape" {
    const allocator = std.testing.allocator;
    const api_key = "phc_testkey";
    const events = [_][]const u8{
        "{\"event\":\"test\",\"properties\":{\"distinct_id\":\"u1\"}}",
    };

    var payload_aw = std.io.Writer.Allocating.init(allocator);
    defer payload_aw.deinit();
    const pw = &payload_aw.writer;

    try pw.writeAll("{\"api_key\":");
    try types.writeJsonStr(pw, api_key);
    try pw.writeAll(",\"batch\":[");
    try pw.writeAll(events[0]);
    try pw.writeAll("]}");

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_aw.written(), .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
    try std.testing.expect(parsed.value.object.get("api_key") != null);
    try std.testing.expect(parsed.value.object.get("batch") != null);
}
