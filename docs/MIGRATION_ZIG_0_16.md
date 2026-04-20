# Migrating from Zig 0.15.2 to 0.16.0

Zig 0.16 ships a large, cohesive redesign around `std.Io` — the networking,
concurrency, filesystem, and time APIs all now flow through an explicit `Io`
instance. Hidden globals (e.g. `std.crypto.random`, `std.posix.getenv`) are
gone; callers pass the capability in.

This guide documents every breaking change `posthog-zig` hit during its upgrade.
It is ordered from highest-frequency hits first. Paths reference this repo's
0.15.2 code so you can grep your own codebase for the same patterns.

---

## 1. `std.io.*` → `std.Io.*`

The `std.io` namespace was removed. The replacement is the capitalised
`std.Io` namespace, which is now a capability handle, not just a module.

### 0.15.2

```zig
var aw = std.io.Writer.Allocating.init(allocator);
defer aw.deinit();
const w = &aw.writer;
try w.writeAll("hello");
const bytes = aw.written();
```

### 0.16.0

```zig
var aw = std.Io.Writer.Allocating.init(allocator);
defer aw.deinit();
const w = &aw.writer;
try w.writeAll("hello");
const bytes = aw.written();
```

**Change is mostly cosmetic for `Writer.Allocating`** — same method surface,
just the namespace capitalisation. The reader side (`std.io.Reader` →
`std.Io.Reader`) has more substantive changes if you were buffering reads.

**Hits in this repo:** `src/client.zig` (×4), `src/transport.zig` (×6),
`src/types.zig` (×2).

---

## 2. `std.Thread.Mutex` and `std.Thread.Condition` removed

`std.Thread` is now just a kernel-thread wrapper. Synchronisation primitives
moved and now require an explicit `Io` (or use a lock-free cousin from
`std.atomic`).

| 0.15.2 | 0.16.0 blocking replacement | 0.16.0 lock-free cousin |
|---|---|---|
| `std.Thread.Mutex` | `std.Io.Mutex` | `std.atomic.Mutex` |
| `std.Thread.RwLock` | `std.Io.RwLock` | — |
| `std.Thread.Semaphore` | `std.Io.Semaphore` | — |
| `std.Thread.Condition` | `std.Io.Condition`¹ | — |

¹ Verify availability in your 0.16 install — the design landed during 0.16 dev
and signatures may still shift.

### 0.15.2

```zig
const Queue = struct {
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,

    fn enqueue(self: *Queue, x: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        // ...
        self.cond.signal();
    }

    fn wait(self: *Queue, timeout_ns: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.cond.timedWait(&self.mutex, timeout_ns) catch {};
    }
};
```

### 0.16.0 (Io-routed)

```zig
const Queue = struct {
    io: std.Io,            // threaded through at init
    mutex: std.Io.Mutex,
    cond: std.Io.Condition,

    fn enqueue(self: *Queue, x: []const u8) error{Canceled}!void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock();
        // ...
        self.cond.signal();
    }

    fn wait(self: *Queue, timeout_ns: u64) error{Canceled}!void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock();
        try self.cond.timedWait(self.io, &self.mutex, timeout_ns);
    }
};
```

**Two downstream consequences:**

1. **Your public API probably grows an `io: std.Io` parameter.** Everything
   that owns a mutex needs an `Io` to lock it. In `posthog-zig` this pushes
   `Io` into `PostHogClient.init(...)`, `batch.Queue.init(...)`, and
   `feature_flags.FlagCache.init(...)`.
2. **`lock()` is now cancellable.** `std.Io.Mutex.lock` returns
   `Cancelable!void`. Either propagate the error or use
   `lockUncancelable(io)` to preserve pre-0.16 semantics.

**Hits in this repo:** `src/batch.zig:71,72`, `src/feature_flags.zig:14`.

---

## 3. Background threads and `std.Thread.spawn`

`std.Thread.spawn(...)` still works — kernel threads are still a thing. But
the spawned thread needs its own `Io` to use blocking primitives. The usual
pattern is to hand it an `std.Io.Threaded` that wraps the kernel thread.

### 0.15.2

```zig
const handle = try std.Thread.spawn(.{}, workerFn, .{&queue});
// ...
handle.join();
```

### 0.16.0

```zig
// Parent creates a Threaded Io; child uses it for blocking ops.
var child_threaded = std.Io.Threaded.init(allocator);
defer child_threaded.deinit();
const child_io = child_threaded.io();

const handle = try std.Thread.spawn(.{}, workerFn, .{ &queue, child_io });
// ...
handle.join();
```

The child function now takes `io: std.Io` and passes it to every
`mutex.lock(io)` / `cond.wait(io, ...)` call.

**Hits in this repo:** `src/flush.zig` (FlushThread.spawn), the integration
tests in `src/flush.zig`, and `src/batch.zig`'s `"integration: concurrent
producers"` test.

---

## 4. `std.crypto.random` removed

The ambient CSPRNG is gone. Construct one explicitly.

### 0.15.2

```zig
const jitter_ms = std.crypto.random.intRangeLessThan(u64, 0, 500);
```

### 0.16.0

```zig
var csprng = std.Random.DefaultCsprng.init(seed_bytes);
const rng = csprng.random();
const jitter_ms = rng.intRangeLessThan(u64, 0, 500);
```

For non-cryptographic jitter (which is the common case — retry backoff, load
shedding) a seeded `std.Random.DefaultPrng` is cheaper.

**Recommendation:** cache the PRNG on a struct that outlives the hot path —
reseeding per call defeats the point.

**Hits in this repo:** `src/retry.zig:10`.

---

## 5. `std.posix.getenv` removed

Environment access is no longer a posix-layer free function. In 0.16, `main`
receives an `Init` struct whose `environ_map: *Environ.Map` holds the
environment; you read from that map.

### 0.15.2

```zig
if (std.posix.getenv("POSTHOG_API_KEY")) |key| {
    ph_client = try posthog.init(allocator, .{ .api_key = key });
}
```

### 0.16.0

```zig
pub fn main(init: std.process.Init) !void {
    if (init.environ_map.get("POSTHOG_API_KEY")) |key| {
        ph_client = try posthog.init(init.gpa, init.io, .{ .api_key = key });
    }
    // ...
}
```

If you can't restructure `main` (e.g. library code running before `main`
control), `std.process.Environ.createMap` + `.get` works but allocates.

**Hits in this repo:** `src/client.zig:435` (test path), `tests/caller_sim_test.zig:590`.

---

## 6. `std.http.Client` routed through `Io`

All networking APIs migrated to `std.Io`. The `Client` now needs an `Io` to
perform `fetch`.

### 0.15.2

```zig
var client = std.http.Client{ .allocator = allocator };
defer client.deinit();

var resp_aw = std.io.Writer.Allocating.init(allocator);
defer resp_aw.deinit();

const result = try client.fetch(.{
    .location = .{ .url = url },
    .method = .POST,
    .headers = .{
        .content_type = .{ .override = "application/json" },
    },
    .payload = payload,
    .response_writer = &resp_aw.writer,
});
```

### 0.16.0 (sketch — verify exact signature in your release)

```zig
var client = std.http.Client{ .allocator = allocator, .io = io };
defer client.deinit();

var resp_aw = std.Io.Writer.Allocating.init(allocator);
defer resp_aw.deinit();

const result = try client.fetch(io, .{
    .location = .{ .url = url },
    .method = .POST,
    .headers = .{
        .content_type = .{ .override = "application/json" },
    },
    .payload = payload,
    .response_writer = &resp_aw.writer,
});
```

The exact shape (Io passed to `fetch` vs stored on the client) may vary
between 0.16 dev snapshots and the 0.16.0 release; check `lib/std/http/Client.zig`
in your install. In `posthog-zig`, both `postBatch` and `postDecide` grow an
`io: std.Io` parameter passed down from `PostHogClient`.

**Hits in this repo:** `src/transport.zig:61,67,86,92`.

---

## 7. `std.heap.ThreadSafeAllocator` removed; `ArenaAllocator` is now lock-free

In 0.15.2 you needed `std.heap.ThreadSafeAllocator` to wrap an allocator for
cross-thread use. In 0.16 that wrapper is gone — `std.heap.ArenaAllocator` is
now thread-safe and lock-free on its own.

### 0.15.2

```zig
const Queue = struct {
    arena: std.heap.ArenaAllocator,
    mutex: std.Thread.Mutex,  // guards the arena allocator

    fn enqueue(self: *Queue, x: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = try self.arena.allocator().dupe(u8, x);
    }
};
```

### 0.16.0

```zig
const Queue = struct {
    arena: std.heap.ArenaAllocator,
    // No mutex needed around arena allocation itself. You may still need
    // one to guard your own state (queue indices, counters, ...).

    fn enqueue(self: *Queue, x: []const u8) !void {
        _ = try self.arena.allocator().dupe(u8, x);
    }
};
```

**Caution:** this only removes the mutex around the arena's *allocation*. If
you also used that mutex to guard adjacent state (a count, an index, a side
pointer), you still need a mutex (now `std.Io.Mutex` or `std.atomic`). Do
**not** delete the mutex wholesale without re-checking every field it
protects.

**Hits in this repo:** `src/batch.zig` — the Queue's mutex also guards
`write_idx`, `count`, and `dropped`, so the mutex stays; only the
justification narrows.

---

## 8. `Io.Writer.Allocating` field renames

Minor: `fmt: Formatter` on `std.io.Writer.Allocating` was renamed to
`fmt: Alt` in 0.16 (`std.Io.Writer.Allocating`). You only hit this if you
were building the struct literal by hand or naming the field in a pattern
match. Standard `init()` / `writeAll()` / `writer` usage is unaffected.

---

## 9. JSON, ArrayList, build system

**`std.json`:** `parseFromSlice(T, allocator, slice, options)` signature is
unchanged in 0.16. `.value.object.get(...)`, `.string`, `.bool` all still
work.

**`std.ArrayList`:** the pre-0.15 managed→unmanaged migration has settled;
nothing new breaks in 0.16 as long as your code compiled on 0.15.2.

**`std.Build`:** `b.addExecutable`, `b.addTest`, `b.addModule`,
`b.createModule`, `b.path`, `b.addRunArtifact`, `b.addInstallArtifact` are
source-compatible. `build.zig` in this repo needed no changes. The larger
release notes mention module-layer reorganisation — that lands as an
additive API, not a break to existing call sites.

---

## 10. `build.zig.zon`

One-line floor bump:

```zig
.minimum_zig_version = "0.16.0",
```

Nothing else in the manifest changed.

---

## Compile-error → fix reference table

When you run `zig build test` on 0.16 with 0.15 source, here's the mapping
from error text to the fix:

| Error text (abridged) | Fix |
|---|---|
| `struct 'std' has no member named 'io'` | `std.io.X` → `std.Io.X` |
| `struct 'Thread' has no member named 'Mutex'` | `std.Thread.Mutex` → `std.Io.Mutex` (+ thread `Io` through) or `std.atomic.Mutex` |
| `struct 'Thread' has no member named 'Condition'` | `std.Thread.Condition` → `std.Io.Condition` |
| `struct 'crypto' has no member named 'random'` | Use `std.Random.DefaultCsprng.init(seed)` / `.DefaultPrng` |
| `struct 'posix' has no member named 'getenv'` | `init.environ_map.get(...)` from `main(init: std.process.Init)` |
| `expected 1 argument, found 0` on `client.fetch(...)` | Pass `io` as first arg (verify against your install) |

---

## Audit checklist when porting a library

- [ ] No `std.io.` tokens left: `grep -rn 'std\.io\.' src/ tests/` → 0 hits.
- [ ] No `std.Thread.Mutex` / `Condition` / `Semaphore` / `RwLock` / `ResetEvent` left.
- [ ] No `std.crypto.random` left.
- [ ] No `std.posix.getenv` left.
- [ ] `minimum_zig_version` bumped.
- [ ] CI workflow uses 0.16.x.
- [ ] Any public API that owns a mutex now takes `io: std.Io`.
- [ ] Arena + sibling-state audit: if you removed a mutex around an arena,
      confirm nothing else it used to guard is now unprotected.
- [ ] Cross-compile matrix green (`-Dtarget=x86_64-linux`, `aarch64-linux`,
      `x86_64-macos`, `aarch64-macos`).
- [ ] At least one real network round-trip (integration test) verifies the
      `Io`-routed HTTP client, not just compile-pass.

---

## References

- Zig 0.16 release notes: <https://ziglang.org/download/0.16.0/release-notes.html>
- `std.Io` source: `$ZIG_INSTALL/lib/std/Io.zig`
- `std.atomic.Mutex` source: `$ZIG_INSTALL/lib/std/atomic.zig`
- `std.Random` source: `$ZIG_INSTALL/lib/std/Random.zig`

The migration is mechanical in volume but load-bearing in concurrency — the
`Io` parameter you thread through is not cosmetic, it's how 0.16 makes
cancellation, tracing, and alternate runtimes (`Threaded`, `Uring`) possible
without each library re-inventing them. Plan for an API break when you ship.
