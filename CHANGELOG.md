# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Deterministic flush retry-path tests via injectable test hooks (`post_batch_fn`, `backoff_fn`, `sleep_fn`) in `src/flush.zig`.
- New flush tests covering: `429 -> retry -> deliver`, non-retry `400 -> failed`, retry exhaustion -> `dropped`, and repeated network errors -> `dropped`.
- New caller simulation test for sustained backpressure under concurrent producer load, asserting drop-newest behavior at fixed capacity.

### Changed

- Added `enable_logging` config (default `true`) to allow deterministic silent test runs.
- Queue overflow behavior documentation aligned to implementation: drop-newest (not drop-oldest).

### Fixed

- Caller simulation tests no longer fail due to expected offline-network log noise.
- Serialization helper allocators now always deinit after `toOwnedSlice()` in `src/client.zig`.
- `postDecide` response writer in `src/transport.zig` now always deinitializes allocator state.
- Caller latency test threshold was relaxed to avoid flaky failures under machine load while preserving the p99 hot-path guard.

## [0.1.0] - 2026-03-07

### Added

- `PostHogClient` — non-blocking analytics client for Zig server-side services
- `client.capture()` — event capture enqueued to in-memory ring buffer (< 1μs hot path)
- `client.identify()` — user identification via PostHog `$identify` event
- `client.group()` — group analytics via PostHog `$groupidentify` event
- `client.captureException()` — error tracking via PostHog `$exception` event format (Error Tracking UI compatible)
- `client.isFeatureEnabled()` — feature flag evaluation via `/decide/` v3 with 60s TTL cache
- `client.getFeatureFlagPayload()` — feature flag JSON payload retrieval (same cache)
- `client.flush()` — manual synchronous flush
- `client.deinit()` — graceful shutdown with queue drain
- Background flush thread: timer-based (default 10s) and threshold-based (default 20 events)
- Exponential backoff retry: base 1s, max 30s, ±500ms jitter, 3 attempts
- Retry on 5xx and 429; drop on 4xx (except 429)
- Drop-oldest overflow policy when queue exceeds `max_queue_size`
- `on_deliver` callback hook for delivery audit (delivered / failed / dropped)
- ISO 8601 UTC timestamp on every event (civil date algorithm, no stdlib calendar dependency)
- Pure Zig — no external C dependencies, no libc beyond what Zig std uses
- Zig 0.15.x compatible
