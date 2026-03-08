# posthog-zig

[![ci](https://github.com/usezombie/posthog-zig/actions/workflows/ci.yml/badge.svg)](https://github.com/usezombie/posthog-zig/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/usezombie/posthog-zig/branch/main/graph/badge.svg)](https://codecov.io/gh/usezombie/posthog-zig)
[![version](https://img.shields.io/badge/version-0.1.0-blue)](https://github.com/usezombie/posthog-zig/releases/tag/v0.1.0)
[![zig](https://img.shields.io/badge/zig-0.15.x-orange)](https://ziglang.org)
[![license](https://img.shields.io/badge/license-MIT-green)](LICENSE)

A server-side PostHog analytics client for Zig. Non-blocking event capture with background batch delivery, retry, and graceful shutdown.

**Version:** 0.1.0
**Zig:** 0.15.x
**PostHog API:** `/batch/` (capture) + `/decide/` v3 (feature flags)

---

## What's in v0.1

| Feature | API | Notes |
|---|---|---|
| Event capture | `client.capture()` | Non-blocking — enqueues to ring buffer, returns immediately |
| User identification | `client.identify()` | Non-blocking |
| Group analytics | `client.group()` | Non-blocking — workspace / org level traits |
| Error tracking | `client.captureException()` | Non-blocking — emits PostHog `$exception` format for Error Tracking UI |
| Batch delivery | background thread | Flushes on timer (default 10s) or queue threshold (default 20 events) |
| Retry | exponential backoff | base 1s, max 30s, jitter, 3 attempts; drops after max retries |
| Graceful shutdown | `client.deinit()` | Drains remaining queue with configurable timeout (default 5s) |
| Feature flags | `client.isFeatureEnabled()` | Calls `/decide/` v3, caches per distinct_id with 60s TTL |
| Feature flag payloads | `client.getFeatureFlagPayload()` | Same cache as above |
| Manual flush | `client.flush()` | Synchronous — blocks until current queue is delivered |

## Delivery guarantees

| Shutdown path | Outcome |
|---|---|
| `SIGTERM` → `client.deinit()` | Queue drained, events delivered |
| `SIGKILL` | Queue lost — no delivery |
| Zig panic (unhandled) | Queue lost — no delivery |
| OOM during flush | Retry up to `max_retries`, then drop |

**v0.1 is best-effort.** For handled application errors — a caught `error.NotFound`,
a failed DB query — the queue path is fine; the process is healthy and the flush
thread is alive. For true crashes (allocator corruption, unhandled panic) queued
events may not be delivered.

**v0.2 will add crash-safe delivery:** `captureException` with `level == .fatal`
will write a crash file to disk synchronously (no allocator, one `write()` syscall),
delivered on next startup. See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for
the full design.

## What's not in v0.1

- Crash file / disk-backed fatal delivery (v0.2) — see delivery guarantees above
- Super properties / global property middleware (v0.2)
- WASM / embedded targets — requires OS threads and `std.http.Client`
- Session recording, autocapture — browser-only, use posthog-js

---

## Install

```bash
zig fetch --save https://github.com/usezombie/posthog-zig/archive/refs/tags/v0.1.0.tar.gz
```

`build.zig`:

```zig
const posthog = b.dependency("posthog", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("posthog", posthog.module("posthog"));
```

---

## Usage

```zig
const posthog = @import("posthog");

// Init — heap-allocates client, spawns background flush thread.
// Heap allocation ensures &client.queue is a stable address for the flush thread.
const client = try posthog.init(allocator, .{
    .api_key = "phc_...",
    .host = "https://us.i.posthog.com", // default
    .enable_logging = true,              // default
    .flush_interval_ms = 10_000,         // default
    .flush_at = 20,                      // flush when N events queued
    .max_queue_size = 1000,              // drop newest if exceeded
    .max_retries = 3,                    // default
    .shutdown_flush_timeout_ms = 5_000,  // default
});
defer client.deinit(); // drains remaining events before exit

// Capture — non-blocking
try client.capture(.{
    .distinct_id = "user_clerk_id",
    .event = "run_started",
    .properties = &.{
        .{ .key = "workspace_id", .value = .{ .string = "ws_abc" } },
        .{ .key = "spec_count",   .value = .{ .integer = 3 } },
    },
});

// Identify — non-blocking
try client.identify(.{
    .distinct_id = "user_clerk_id",
    .properties = &.{
        .{ .key = "email", .value = .{ .string = "alice@example.com" } },
        .{ .key = "plan",  .value = .{ .string = "pro" } },
    },
});

// Group — non-blocking
try client.group(.{
    .distinct_id = "user_clerk_id",
    .group_type  = "workspace",
    .group_key   = "ws_abc",
    .properties  = &.{
        .{ .key = "name", .value = .{ .string = "Acme Corp" } },
    },
});

// Error tracking — non-blocking
// Shows up in PostHog → Error Tracking UI with full user context
try client.captureException(.{
    .distinct_id      = "user_clerk_id",
    .exception_type   = "WorkspaceError",
    .exception_message = "workspace not found: ws_abc",
    .handled          = false,
    .level            = .err,
    .properties       = &.{
        .{ .key = "workspace_id", .value = .{ .string = "ws_abc" } },
        .{ .key = "run_id",       .value = .{ .string = "run_xyz" } },
    },
});

// Feature flags — sync, cached (one HTTP call per distinct_id per TTL)
const enabled = try client.isFeatureEnabled("new-dashboard", "user_clerk_id");
const payload = try client.getFeatureFlagPayload("new-dashboard", "user_clerk_id");

// Manual flush — blocks until queue is empty
try client.flush();
```

---

## Integration pattern for calling systems

posthog-zig is a library. It cannot install a panic handler. The calling application
owns that responsibility.

### Minimal integration (zombied / any Zig daemon)

```zig
// src/main.zig
const posthog = @import("posthog");

// Hold the client at application scope so the panic hook can reach it.
var ph_client: ?*posthog.PostHogClient = null;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Init — spawns background flush thread.
    // Pass null api_key to disable analytics (e.g. when env var is absent).
    if (std.posix.getenv("POSTHOG_API_KEY")) |key| {
        ph_client = try posthog.init(allocator, .{ .api_key = key });
    }
    defer if (ph_client) |c| c.deinit(); // deinit frees the heap-allocated client // drains queue on SIGTERM / clean exit

    // ... rest of your service
}

// Zig calls this on unhandled panics.
// Keep it minimal — the allocator may be corrupted.
pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    // v0.1: best-effort. If the flush thread is still alive it may deliver
    // events already in the queue. Do not attempt to enqueue new events here —
    // the allocator state is unknown.

    // v0.2: ph_client.writeCrashFile() will be safe here (zero allocation,
    // single write() syscall of the arena buffer). Not implemented yet.

    std.debug.defaultPanic(msg, trace, ret_addr);
}
```

### Capturing errors without panicking

```zig
// In any request handler or worker:
fn handleRun(client: *posthog.PostHogClient, user_id: []const u8) !void {
    const result = runSpec() catch |err| {
        // Handled error — process is healthy, queue path is safe.
        client.captureException(.{
            .distinct_id      = user_id,
            .exception_type   = @errorName(err),
            .exception_message = "spec execution failed",
            .handled          = true,
            .level            = .err,
        }) catch {};  // never let analytics fail the request
        return err;
    };
    _ = result;
}
```

### Optional client pattern

posthog-zig is designed to be optional in production — pass `null` when no API key
is configured. Wrap calls at the callsite:

```zig
if (ctx.posthog) |*ph| {
    ph.capture(.{ .distinct_id = user_id, .event = "run_started" }) catch {};
}
```

The `catch {}` is intentional: analytics must never propagate errors to the caller.

---

## Design

### Non-blocking hot path

`capture()`, `identify()`, `group()`, and `captureException()` serialize the event
into the write-side arena and return. No per-event heap allocation, no I/O, no blocking.
The flush thread swaps arenas (O(1) under mutex) and owns all network activity.

```
capture() ──► write arena ──► swap (O(1)) ──► flush thread ──► POST /batch/
 < 1μs        (mutex lock)    (flush fires)   owns flush arena   (std.http.Client)
               enqueue                         POST all events    │
               return         new capture()    arena.reset()      └─ retry on 5xx/429
                              writes to        (one free, O(1))   └─ drop after max_retries
                              other arena
```

**Memory model — double-buffer arena.** Two `ArenaAllocator` instances alternate roles.
After each flush, `arena.reset()` reclaims all event memory in one operation regardless
of batch size. Fixed memory footprint: `2 × max_queue_size × avg_event_size` (~4MB at
defaults). No per-event malloc/free, no heap fragmentation.

**Overflow.** When the write-side arena is at capacity, new events are dropped (drop-newest)
and counted. The next flush cycle resets the arena and restores full capacity.

### Retry policy

- Retries on: 5xx, 429 (respects `Retry-After` header), network errors
- Does not retry on: 4xx (except 429) — bad data, logged and dropped
- Backoff: `min(1s * 2^attempt, 30s)` + random jitter 0–500ms

### Feature flag cache

`/decide/` responses are cached per `distinct_id` with a 60s TTL and an LRU cap of 1000 entries. After the first call, `isFeatureEnabled()` returns from cache without hitting the network.

### Shutdown

`client.deinit()` signals the flush thread to stop accepting new events, drains the remaining queue with a final `POST /batch/`, and waits up to `shutdown_flush_timeout_ms`. Events that cannot be delivered within the timeout are logged and dropped — they are not persisted to disk.

For deeper design rationale — memory model, crash delivery tradeoffs, v0.2 double-buffer arena target, and serialization approach — see [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

---

## Configuration

| Option | Default | Description |
|---|---|---|
| `api_key` | required | PostHog project API key (`phc_...`) |
| `host` | `https://us.i.posthog.com` | PostHog ingestion host |
| `enable_logging` | `true` | Enable SDK logs (`warn`/`err`/`info`/`debug`) |
| `flush_interval_ms` | `10_000` | How often the flush thread wakes (ms) |
| `flush_at` | `20` | Flush when this many events are queued |
| `max_queue_size` | `1000` | Queue capacity; drops newest on overflow |
| `max_retries` | `3` | Max delivery attempts per batch |
| `shutdown_flush_timeout_ms` | `5_000` | Max time `deinit()` waits for final flush |
| `feature_flag_ttl_ms` | `60_000` | Feature flag cache TTL per distinct_id |

---

## Building and testing

```bash
# Build
cd ~/Projects/posthog-zig && zig build

# Unit tests
zig build test

# Integration tests (requires PostHog API key)
POSTHOG_API_KEY=phc_... zig build test -Dintegration=true

# Verify no external C dependencies
zig build -Dtarget=x86_64-linux --summary all 2>&1 | grep "link with" && echo "WARN: C deps" || echo "PASS: pure Zig"

# Benchmark capture() hot path
zig build bench
```

---

## Disclaimer

This is a **server-side SDK**. It assumes `std.http.Client`, `std.Thread`, and a real OS. It does not support browser WASM, session recording, or autocapture. For frontend analytics, use [posthog-js](https://github.com/PostHog/posthog-js).

---

## License

MIT — see [LICENSE](LICENSE).

Built for [usezombie](https://usezombie.com). Used in `zombied` (Zig control plane daemon) for production analytics.
