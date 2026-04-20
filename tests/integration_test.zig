//! Integration tests — require POSTHOG_API_KEY env var.
//! Run with: POSTHOG_API_KEY=phc_... zig build test -Dintegration=true

const std = @import("std");
const posthog = @import("posthog");

fn getApiKey(allocator: std.mem.Allocator) ![]const u8 {
    // Zig 0.16 removed `std.process.getEnvVarOwned`.
    const env = std.Options.debug_threaded_io.?.environ.process_environ;
    const val = env.getPosix("POSTHOG_API_KEY") orelse {
        std.debug.print("SKIP: POSTHOG_API_KEY not set\n", .{});
        return error.SkipZigTest;
    };
    return try allocator.dupe(u8, val);
}

test "integration: capture event reaches PostHog /batch/" {
    const allocator = std.testing.allocator;
    const api_key = try getApiKey(allocator);
    defer allocator.free(api_key);

    var client = try posthog.init(allocator, posthog.defaultIo(), .{
        .api_key = api_key,
        .flush_interval_ms = 60_000,
        .max_retries = 1,
        .flush_at = 1000,
    });
    defer client.deinit();

    try client.capture(.{
        .distinct_id = "posthog-zig-integration-test",
        .event = "sdk_integration_test",
        .properties = &.{
            .{ .key = "sdk_version", .value = .{ .string = posthog.version } },
            .{ .key = "test", .value = .{ .boolean = true } },
        },
    });

    try client.flush();
}

test "integration: identify reaches PostHog" {
    const allocator = std.testing.allocator;
    const api_key = try getApiKey(allocator);
    defer allocator.free(api_key);

    var client = try posthog.init(allocator, posthog.defaultIo(), .{
        .api_key = api_key,
        .flush_interval_ms = 60_000,
        .max_retries = 1,
    });
    defer client.deinit();

    try client.identify(.{
        .distinct_id = "posthog-zig-integration-test",
        .properties = &.{
            .{ .key = "sdk", .value = .{ .string = "posthog-zig" } },
            .{ .key = "version", .value = .{ .string = posthog.version } },
        },
    });

    try client.flush();
}

test "integration: captureException reaches PostHog Error Tracking" {
    const allocator = std.testing.allocator;
    const api_key = try getApiKey(allocator);
    defer allocator.free(api_key);

    var client = try posthog.init(allocator, posthog.defaultIo(), .{
        .api_key = api_key,
        .flush_interval_ms = 60_000,
        .max_retries = 1,
    });
    defer client.deinit();

    try client.captureException(.{
        .distinct_id = "posthog-zig-integration-test",
        .exception_type = "IntegrationTestError",
        .exception_message = "this is a test exception from posthog-zig CI",
        .handled = true,
        .level = .err,
        .stack_trace = "frame 0: tests/integration_test.zig:70\nframe 1: root.zig:main",
        .properties = &.{
            .{ .key = "sdk_version", .value = .{ .string = posthog.version } },
        },
    });

    try client.flush();
}

test "integration: group reaches PostHog" {
    const allocator = std.testing.allocator;
    const api_key = try getApiKey(allocator);
    defer allocator.free(api_key);

    var client = try posthog.init(allocator, posthog.defaultIo(), .{
        .api_key = api_key,
        .flush_interval_ms = 60_000,
        .max_retries = 1,
    });
    defer client.deinit();

    try client.group(.{
        .distinct_id = "posthog-zig-integration-test",
        .group_type = "company",
        .group_key = "posthog-zig-ci",
        .properties = &.{
            .{ .key = "sdk_version", .value = .{ .string = posthog.version } },
            .{ .key = "test", .value = .{ .boolean = true } },
        },
    });

    try client.flush();
}

test "integration: on_deliver callback fires on successful delivery" {
    const allocator = std.testing.allocator;
    const api_key = try getApiKey(allocator);
    defer allocator.free(api_key);

    // `on_deliver` fires from the background flush thread, not from the
    // synchronous `client.flush()` path. Use flush_at=1 so enqueue triggers
    // an immediate background flush, then wait for the callback.
    var client = try posthog.init(allocator, posthog.defaultIo(), .{
        .api_key = api_key,
        .flush_interval_ms = 60_000,
        .flush_at = 1,
        .max_retries = 1,
        .on_deliver = struct {
            fn cb(status: posthog.DeliveryStatus, count: usize) void {
                _ = count;
                if (status == .delivered) {
                    _ = delivered_count.fetchAdd(1, .acq_rel);
                }
            }
        }.cb,
    });
    defer client.deinit();

    delivered_count.store(0, .release);

    try client.capture(.{
        .distinct_id = "posthog-zig-integration-test",
        .event = "sdk_callback_test",
    });

    // Poll up to 5s for the background thread to deliver and fire the callback.
    const io = posthog.defaultIo();
    var waited_ms: u64 = 0;
    while (waited_ms < 5_000 and delivered_count.load(.acquire) == 0) : (waited_ms += 50) {
        io.sleep(std.Io.Duration.fromMilliseconds(50), .awake) catch {};
    }

    try std.testing.expect(delivered_count.load(.acquire) > 0);
}

var delivered_count = std.atomic.Value(usize).init(0);
