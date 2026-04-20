//! posthog-zig — server-side PostHog analytics SDK for Zig.
//!
//! Usage:
//!   const posthog = @import("posthog");
//!   var client = try posthog.init(allocator, posthog.defaultIo(), .{ .api_key = "phc_..." });
//!   defer client.deinit();
//!   try client.capture(.{ .distinct_id = "user_123", .event = "run_started" });

const std = @import("std");
const builtin = @import("builtin");

pub const std_options: std.Options = if (builtin.is_test) .{
    .logFn = silentLog,
} else .{};

fn silentLog(
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

pub const types = @import("types.zig");
pub const batch = @import("batch.zig");
pub const retry = @import("retry.zig");
pub const transport = @import("transport.zig");
pub const flush = @import("flush.zig");
pub const feature_flags = @import("feature_flags.zig");
pub const client = @import("client.zig");

// ── Public surface ────────────────────────────────────────────────────────────

pub const PostHogClient = client.PostHogClient;

// Types
pub const Config = types.Config;
pub const Property = types.Property;
pub const PropertyValue = types.PropertyValue;
pub const ExceptionLevel = types.ExceptionLevel;
pub const DeliveryStatus = types.DeliveryStatus;
pub const CaptureOptions = types.CaptureOptions;
pub const IdentifyOptions = types.IdentifyOptions;
pub const GroupOptions = types.GroupOptions;
pub const ExceptionOptions = types.ExceptionOptions;

pub const version = types.version;

/// Initialize a PostHog client. Spawns the background flush thread.
/// Returns a heap-allocated client. Call `defer client.deinit()` to flush
/// remaining events, stop the thread, and free all resources.
pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) !*PostHogClient {
    return PostHogClient.init(allocator, io, config);
}

/// Convenience accessor for the process-wide default `Io`, populated by
/// `start.zig` with the real environment and a thread-capable backend. This
/// is the value to pass as `io` when the caller has no stronger opinion.
pub fn defaultIo() std.Io {
    return std.Options.debug_threaded_io.?.io();
}

// ── Pull in all test blocks ───────────────────────────────────────────────────

test {
    _ = @import("types.zig");
    _ = @import("batch.zig");
    _ = @import("retry.zig");
    _ = @import("transport.zig");
    _ = @import("flush.zig");
    _ = @import("feature_flags.zig");
    _ = @import("client.zig");
}
