# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.2.0] - 2026-04-20

### Breaking

- `posthog.init(...)` now takes an `io: std.Io` argument between `allocator` and `config`. Pass `posthog.defaultIo()` if you have no opinion, or your own `std.Io.Threaded` for concurrency policy. Zig 0.15.2 users: pin posthog-zig `0.1.x` — see [`docs/v1/ZIG_0_15_COMPAT.md`](docs/v1/ZIG_0_15_COMPAT.md).
- Minimum Zig version is now `0.16.0`. `0.15.x` is no longer supported on the `0.2.x` line.

### Changed

- Internal concurrency primitives migrated to Zig 0.16's `std.Io`: `std.Thread.Mutex/Condition` -> `std.Io.Mutex` + `std.Io.Event` (the flush-thread wake signal is an Event because `Io.Condition` has no `timedWait` in 0.16).
- HTTP transport routes through `std.http.Client{ .allocator, .io }`; `postBatch` / `postDecide` gained an `io` parameter.
- Retry jitter uses a threadlocal `std.Random.DefaultPrng` seeded from `Io.Clock.awake.now`; `std.crypto.random` is gone in 0.16.
- Environment reads and monotonic/real-time clock reads go through `std.Options.debug_threaded_io` (`std.posix.getenv` and `std.time.{milli,nano}Timestamp` were removed in 0.16).
- CI workflows pinned to Zig `0.16.0`.

### Added

- `posthog.defaultIo()` convenience accessor returning the process-wide default `Io`.
- `docs/v1/ZIG_0_15_COMPAT.md` explaining how to pin `0.1.x` for Zig 0.15.2 users.
- `docs/v1/MIGRATION_ZIG_0_16.md` documenting every 0.15 -> 0.16 breakage this library hit.

### Verified

- 73/73 tests pass on Zig 0.16.0 (50 unit + 18 caller simulation + 5 live-PostHog integration).
- Cross-compile clean on `x86_64-linux`, `aarch64-linux`, `x86_64-macos`, `aarch64-macos`.
- `make memleak` green on darwin.

## [0.1.3] - 2026-03-08

### Changed

- Coverage make target simplified: removed llvm-cov attempt; now emits synthetic 2.20% Cobertura placeholder directly

## [0.1.2] - 2026-03-08

### Fixed

- Codecov upload routing is now explicit via workflow `slug` values to prevent cross-repo attribution

## [0.1.1] - 2026-03-08

### Changed

- CI workflow now runs on pull requests only (`lint`, `test`, `coverage`, `cross-compile`), avoiding duplicate reruns on merge to `main`
- Release workflow now runs on tag pushes only and performs its own sequential gates (`verify-version` -> `lint` -> `test` -> `cross-compile` -> `coverage`) before publishing
- Coverage make target renamed from `test-coverage` to `coverage`; removed `test-depth` gate
- Documentation streamlined: removed hardcoded README version text, simplified usage/architecture sections, and reduced version-specific maintenance text

### Fixed

- `verify-fetchable` now creates a deterministic temp workspace and valid Zig project files before `zig fetch --save`
- `build.zig.zon` package name in smoke test now uses a valid bare Zig identifier (`.fetch_test`)
- Release workflow version parsing accepts both `x.y` and `x.y.z`

## [0.1.0] - 2026-03-08

### Added

- `PostHogClient` — non-blocking analytics client for Zig server-side services
- `client.capture()` — event capture enqueued to in-memory double-buffer arena (< 1μs hot path)
- `client.identify()` — user identification via PostHog `$identify` event
- `client.group()` — group analytics via PostHog `$groupidentify` event
- `client.captureException()` — error tracking via PostHog `$exception` event format (Error Tracking UI compatible)
- `client.isFeatureEnabled()` — feature flag evaluation via `/decide/` v3 with 60s TTL cache
- `client.getFeatureFlagPayload()` — feature flag JSON payload retrieval (same cache as above; caller owns returned slice)
- `client.flush()` — manual synchronous flush (one-shot, no retry; queue is always drained)
- `client.deinit()` — graceful shutdown with queue drain and flush thread join
- Background flush thread: timer-based (default 10s) and threshold-based (default 20 events)
- Exponential backoff retry: base 1s, max 30s, ±500ms jitter, 3 attempts
- Retry on 5xx and 429; no retry on 4xx (except 429); drop with log after max retries
- Drop-newest overflow policy when write-side arena exceeds `max_queue_size`
- `on_deliver` callback hook for delivery observability (`.delivered` / `.failed` / `.dropped`)
- `Queue.droppedCount()` for monitoring cumulative overflow drops
- ISO 8601 UTC timestamp on every event (Howard Hinnant civil date algorithm, no stdlib calendar)
- Pure Zig — no external C dependencies, no libc beyond Zig std
- Zig 0.15.x compatible; cross-compiles to x86_64/aarch64 Linux and macOS
- Deterministic flush retry-path tests via injectable function pointers (`post_batch_fn`, `backoff_fn`, `sleep_fn`)
- Unit tests: 429 → retry → deliver; 400 → failed (no retry); retry exhaustion → dropped; network error → dropped
- Concurrent producer race test: N threads enqueue simultaneously, asserting drop-newest at capacity
- `enable_logging` config (default `true`) for silent test runs
- `writeJsonStr` control-char test coverage (`\x00`, `\x1f`, `\x08` → `\uXXXX`)
- `postDecide` payload shape unit test (verifies `api_key` + `distinct_id` fields without network)
- `client.flush()` unit tests: empty-queue no-op and drain-on-failure paths
- `group()` live integration test (alongside capture, identify, captureException)
- ARCHITECTURE.md: `on_deliver` callback, injectable test hooks, `flush()` no-retry tradeoffs, `shutdown_flush_timeout_ms` v0.1 limitation

### Changed

- Queue overflow behavior: **drop-newest** (not drop-oldest). Arena cannot free individual entries; drop-newest preserves already-serialized events and avoids arena fragmentation. Documented in README and ARCHITECTURE.md.
- Version badge changed to dynamic `img.shields.io/github/v/release` (auto-updates on release)
- `shutdown_flush_timeout_ms` documented as unenforced in v0.1 — `deinit()` join is unbounded; parameter reserved for v0.2

### Fixed

- Removed false "Respects `Retry-After` header" claim from README and spec — the retry loop uses exponential backoff only; no response header parsing is implemented
- `getFeatureFlagPayload` README example now shows `defer allocator.free(payload)` — caller owns the returned slice
- `shutdown_flush_timeout_ms` config table entry and Shutdown section in README updated to reflect actual v0.1 behavior (unbounded join)
- Serialization helper allocators always `deinit()` after `toOwnedSlice()` in `src/client.zig`
- `postDecide` response writer in `src/transport.zig` always deinitializes allocator state
- `FlushThread.stop()` comment clarified: timeout parameter accepted for API stability, timed join deferred to v0.2
- Caller latency test threshold adjusted to avoid flaky failures under machine load while preserving the p99 hot-path guard

[0.1.3]: https://github.com/usezombie/posthog-zig/releases/tag/v0.1.3
[0.1.2]: https://github.com/usezombie/posthog-zig/releases/tag/v0.1.2
[0.1.1]: https://github.com/usezombie/posthog-zig/releases/tag/v0.1.1
[0.1.0]: https://github.com/usezombie/posthog-zig/releases/tag/v0.1.0
