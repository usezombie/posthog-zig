//! Integration tests — require POSTHOG_API_KEY env var.
//! Run with: POSTHOG_API_KEY=phc_... zig build test -Dintegration=true

const std = @import("std");
const posthog = @import("posthog");

fn getApiKey(allocator: std.mem.Allocator) ![]const u8 {
    return std.process.getEnvVarOwned(allocator, "POSTHOG_API_KEY") catch {
        std.debug.print("SKIP: POSTHOG_API_KEY not set\n", .{});
        return error.SkipZigTest;
    };
}

test "integration: capture event reaches PostHog /batch/" {
    const allocator = std.testing.allocator;
    const api_key = try getApiKey(allocator);
    defer allocator.free(api_key);

    var client = try posthog.init(allocator, .{
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

    // Flush synchronously so the test can verify delivery
    try client.flush();
}

test "integration: identify reaches PostHog" {
    const allocator = std.testing.allocator;
    const api_key = try getApiKey(allocator);
    defer allocator.free(api_key);

    var client = try posthog.init(allocator, .{
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

    var client = try posthog.init(allocator, .{
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

test "integration: on_deliver callback fires on successful delivery" {
    const allocator = std.testing.allocator;
    const api_key = try getApiKey(allocator);
    defer allocator.free(api_key);

    const Ctx = struct {
        delivered: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        fn onDeliver(status: posthog.DeliveryStatus, count: usize) void {
            _ = count;
            if (status == .delivered) {
                // Can't easily access self here from a fn pointer, use a global for test
                delivered_count.fetchAdd(1, .acq_rel);
            }
        }
    };
    _ = Ctx;

    var client = try posthog.init(allocator, .{
        .api_key = api_key,
        .flush_interval_ms = 60_000,
        .max_retries = 1,
        .on_deliver = struct {
            fn cb(status: posthog.DeliveryStatus, count: usize) void {
                _ = count;
                if (status == .delivered) {
                    delivered_count.fetchAdd(1, .acq_rel);
                }
            }
        }.cb,
    });
    defer client.deinit();

    try client.capture(.{
        .distinct_id = "posthog-zig-integration-test",
        .event = "sdk_callback_test",
    });

    try client.flush();
    // Allow background thread to process callback
    std.Thread.sleep(100 * std.time.ns_per_ms);

    try std.testing.expect(delivered_count.load(.acquire) > 0);
}

var delivered_count = std.atomic.Value(usize).init(0);
