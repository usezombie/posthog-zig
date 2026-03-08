# Architecture

Design decisions, tradeoffs, and the target evolution of posthog-zig.

---

## Why this SDK exists

posthog-zig is the server-side analytics layer for the usezombie stack. The first
consumer is `zombied` — a Zig control plane daemon where latency and reliability
matter. The SDK had to be:

- **Non-blocking on the hot path.** `capture()` cannot touch the network.
- **Pure Zig.** No C FFI, no libuv, no linking complexity.
- **Error-tracking first.** `captureException()` with PostHog `$exception` format
  is the must-have for a backend service, not an afterthought.

---

## Memory model: double-buffer arena (v0.1)

### The insight

The natural allocation unit is not the event — it is the **flush envelope**. One
flush cycle produces one HTTP POST. Everything in that POST lives and dies together.
That is the definition of an arena.

The obstacle is that events arrive continuously from the calling thread while the
flush thread may be mid-POST. The solution is **ping-pong arenas** (double
buffering).

### Design (implemented in `src/batch.zig`)

```
┌─────────────────────────────────────────────────────────────────┐
│  Arena A  (write side)          │  Arena B  (flush side)        │
│  [ev1_json][ev2_json][ev3_json] │  [being POSTed right now]     │
│  one contiguous backing alloc   │  one contiguous backing alloc │
└─────────────────────────────────────────────────────────────────┘
```

**capture():**
1. Lock
2. Serialize event directly into Arena A (bump pointer, no fragmentation)
3. Append pointer into write-side event index
4. Signal if flush_at reached
5. Unlock — returns immediately

**flush fires:**
1. Lock
2. Swap A ↔ B (one pointer swap, O(1))
3. Unlock
4. Flush thread owns all of B — no contention with producers
5. Build batch payload from B's events (into B itself, or a scratch arena)
6. POST
7. `arena_b.reset()` — O(1), pointer bumped back to zero, backing allocation reused

**New capture() during flush:** writes into A while B is in-flight. No blocking,
no lock contention beyond the initial enqueue.

### Properties

| | Per-event heap (rejected) | Double-buffer arena (v0.1) |
|---|---|---|
| Alloc cost | N mallocs per flush | 1 reset per flush |
| Free cost | N frees | 1 reset (O(1)) |
| Fragmentation | Accumulates over time | None — fixed backing regions |
| Memory bound | Unbounded if flush falls behind | Fixed: 2 × (max_queue_size × avg_event_size) |
| Predictability | Poor under load | Deterministic |
| Crash safety | N orphaned pointers | 2 contiguous regions |

### Sizing

```
backing_size = max_queue_size × avg_event_size
             = 1000 × 2KB = 2MB per arena
total fixed  = 4MB
```

---

## Crash delivery

### v0.1: best-effort

Delivery guarantee in v0.1:

| Shutdown path | Outcome |
|---|---|
| `SIGTERM` → `client.deinit()` | Queue drained, events delivered |
| `SIGKILL` | Queue lost — no delivery |
| Zig panic (unhandled) | Queue lost — no delivery |
| OOM during flush | Retry up to max_retries, then drop |

**This is honest and documented.** For handled application errors (`captureException`
on a caught error) the queue path is fine — the process is healthy. For true crashes
the queue cannot help.

### v0.2: crash file (Ghostty pattern)

Ghostty's crash reporter writes a `.ghosttycrash` envelope to disk in the transport
callback — no network call, no allocator, one `write()` syscall on an already-open
file descriptor. The file is uploaded on next startup.

For posthog-zig v0.2, `captureException` with `level == .fatal` will:

1. Serialize the event into a stack buffer (no allocator)
2. Write synchronously to `$RUNTIME_DIR/posthog-crash-{uuid}.jsonl`
3. Also enqueue normally (best-effort network delivery if the flush thread lives)

On next startup, `posthog.init()` will check for crash files and deliver them
before the first normal flush. The crash file path is the delivery guarantee;
the queue path is the fast path.

### Why disk-write is safe in a crash handler but network is not

In a panic or signal handler the process is in undefined state. The allocator
may be corrupted. A network call requires:
- Allocating a payload buffer
- TLS state machine (allocates)
- TCP write (may block, may allocate)

A disk write requires:
- A file descriptor (already open, or openable with `O_CREAT | O_APPEND`)
- One `write()` syscall

The double-buffer arena design of v0.2 makes the disk write trivially cheap:
the write-side arena is one contiguous slice — a single `write()` of
`arena_a.buffer[0..arena_a.end_index]` captures all pending events without
any additional allocation.

### Calling system panic hook

posthog-zig is a library. It cannot install a panic handler. The application
registers one in its root source file:

```zig
// zombied/src/main.zig
const posthog_client = &global_state.posthog;  // app-owned pointer

pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    // v0.1: best-effort — flush thread may or may not still be alive
    // Call deinit only if you are confident the allocator is healthy.
    // On OOM or UB-triggered panics, skip this.

    // v0.2: write crash file — safe because it requires no allocator
    // posthog_client.writeCrashFile() catch {};

    std.debug.defaultPanic(msg, trace, ret_addr);
}
```

Keep the panic handler **minimal**. If the panic was caused by allocator corruption,
complex work inside the handler will itself crash. The crash file write in v0.2 is
designed to require zero allocations for this reason.

---

## Serialization approach

We use a custom `writeJsonStr` helper (in `src/types.zig`) rather than
`std.json.stringify` or `std.json.fmt`. Reasons:

1. `std.json.stringify` was removed in Zig 0.15 — API changed to `std.json.Stringify`.
2. The field values we write are simple (strings, integers, booleans). The overhead
   of the full JSON serializer is not justified.
3. `writeJsonStr` handles the subset we need: proper escaping of `"`, `\`, `\n`,
   `\r`, `\t`, and control characters.

For structured data (feature flag responses), we parse with `std.json.parseFromSlice`
since we need full JSON value traversal. The split is intentional: hand-write
serialization for known shapes, stdlib for unknown shapes.

Comparison to other Zig codebases:

- **nullclaw/audit.zig**: `fixedBufferStream` + stack buffer + `{s}` format. Zero
  allocation, but `{s}` does not escape — safe only for controlled enum/bool values,
  not user-supplied strings.
- **Ghostty/sentry_envelope.zig**: `std.Io.Writer.Allocating` + `std.json.fmt` with
  `.whitespace = .minified`. Cleanest — delegates escaping to stdlib. Requires
  `std.json.Value` as intermediate representation which we avoid for hot-path events.
- **posthog-zig**: `std.io.Writer.Allocating` + `writeJsonStr`. Middle ground —
  heap-dynamic like Ghostty, custom escaping like audit.zig but correct for all
  input.

---

## What we deliberately excluded

**Redis Streams bus pattern.** Considered: events → Redis Stream → posthog-node
consumer. Rejected: posthog-zig IS the fire-and-forget buffer layer. A bus adds
an operational dependency (Redis must be available) without removing the network
I/O problem — you still need something to read from the stream and call PostHog.
The background flush thread is simpler and removes the operational dependency.

**JSONL audit log.** Considered: write every event to a local JSONL file as a
delivery receipt. Rejected for v0.1: adds I/O on every enqueue, complicates
cleanup, and the `on_deliver` callback covers the observability need. The v0.2
crash file is a targeted version of this idea, scoped to fatal events only.

**Per-event retry queue on disk.** Rejected for v0.1: scope creep. The in-memory
retry (up to `max_retries` with exponential backoff) is sufficient for transient
network failures. Persistent retry requires a compaction strategy, read-back
logic, and a format specification. Worth revisiting if PostHog ingestion proves
unreliable in production.
