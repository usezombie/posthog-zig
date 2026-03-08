const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const integration = b.option(bool, "integration", "Run integration tests (requires POSTHOG_API_KEY)") orelse false;

    // ── Public module for consumers ──────────────────────────────────────────
    const posthog_mod = b.addModule("posthog", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── Unit tests ───────────────────────────────────────────────────────────
    const unit_tests = b.addTest(.{
        .name = "posthog-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // ── Caller simulation tests ───────────────────────────────────────────────
    const caller_tests = b.addTest(.{
        .name = "posthog-caller-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/caller_sim_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "posthog", .module = posthog_mod },
            },
        }),
    });

    const test_step = b.step("test", "Run unit + caller simulation tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(caller_tests).step);

    b.step("test-unit", "Run unit tests only").dependOn(&b.addRunArtifact(unit_tests).step);
    b.step("test-caller", "Run caller simulation tests only").dependOn(&b.addRunArtifact(caller_tests).step);

    // ── Integration tests (live PostHog, gated by -Dintegration=true) ────────
    if (integration) {
        const int_tests = b.addTest(.{
            .name = "posthog-integration-tests",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/integration_test.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "posthog", .module = posthog_mod },
                },
            }),
        });
        b.step("test", "Run unit + integration tests").dependOn(&b.addRunArtifact(int_tests).step);
    }

    // ── Test binary for kcov coverage ────────────────────────────────────────
    const install_tests = b.addInstallArtifact(unit_tests, .{
        .dest_sub_path = "posthog-tests",
    });
    b.step("test-bin", "Build test binary for coverage (kcov)").dependOn(&install_tests.step);

    // ── Bench ────────────────────────────────────────────────────────────────
    const bench_tests = b.addTest(.{
        .name = "posthog-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    b.step("bench", "Run benchmarks (capture hot-path latency)").dependOn(&b.addRunArtifact(bench_tests).step);
}
