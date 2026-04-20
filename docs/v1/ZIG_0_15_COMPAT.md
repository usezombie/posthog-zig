# Using posthog-zig on Zig 0.15.2

`posthog-zig` ≥ **0.2.0** requires **Zig 0.16.0 or newer**. The 0.2.0 release
absorbs Zig 0.16's concurrency redesign: `std.io.*` moved to `std.Io.*`,
`std.Thread.Mutex/Condition` were removed in favour of `std.Io.Mutex/Event`,
`std.crypto.random` / `std.posix.getenv` / `std.time.{milli,nano}Timestamp` /
`std.Thread.sleep` were removed, and `std.http.Client` was routed through
`std.Io`. These are load-bearing API changes — `posthog-zig` 0.2.x will not
compile on 0.15.x.

If you are still on Zig 0.15.2, pin the **0.1.x** line.

## Pinning posthog-zig 0.1.x in your `build.zig.zon`

```zig
.dependencies = .{
    .posthog = .{
        .url = "https://github.com/usezombie/posthog-zig/archive/refs/tags/v0.1.3.tar.gz",
        // zig fetch will fill in the hash for you.
    },
},
```

Or, if you vendor with `zig fetch --save`:

```sh
zig fetch --save "https://github.com/usezombie/posthog-zig/archive/refs/tags/v0.1.3.tar.gz"
```

`0.1.3` is the last release on the pre-0.16 API surface. It supports Zig
0.15.2 end-to-end (CI, cross-compile, integration). No bug fixes or new
features will land on the `0.1.x` line — it is a compatibility branch only.

## Differences between 0.1.x and 0.2.x

| Surface | 0.1.x (Zig 0.15.2) | 0.2.x (Zig 0.16.x) |
|---|---|---|
| `posthog.init(...)` | `(allocator, config)` | `(allocator, io, config)` — extra `io: std.Io` arg |
| Default `io` helper | n/a | `posthog.defaultIo()` returns `std.Options.debug_threaded_io.?.io()` |
| Synchronisation | `std.Thread.Mutex` / `Condition` | `std.Io.Mutex` / `std.Io.Event` |
| HTTP client | `std.http.Client{ .allocator = a }` | `std.http.Client{ .allocator = a, .io = io }` |
| Env access | `std.posix.getenv(...)` | `std.Options.debug_threaded_io.?.environ.process_environ.getPosix(...)` |
| Retry jitter | `std.crypto.random` | thread-local `std.Random.DefaultPrng` seeded from `Io.Clock.awake` |
| Timestamps | `std.time.milliTimestamp()` | `std.Io.Clock.real.now(io).nanoseconds` (helpers in `types.zig`) |

## Migrating from 0.1.x to 0.2.x

See [`MIGRATION_ZIG_0_16.md`](./MIGRATION_ZIG_0_16.md) for the full mapping
of Zig 0.15.2 → 0.16.0 breaking changes that posthog-zig's 0.2.0 had to
absorb. The user-visible impact is a single `io` argument added to
`posthog.init(...)`; the rest is internal.

```zig
// Before (0.1.x, Zig 0.15.2)
var client = try posthog.init(allocator, .{ .api_key = key });

// After (0.2.x, Zig 0.16.x)
var client = try posthog.init(allocator, posthog.defaultIo(), .{ .api_key = key });
```

## Why no back-compat shim

A single codebase cannot paper over `std.Thread.Mutex` vs `std.Io.Mutex` —
they are different types with different method signatures, and the
`std.Io.Mutex.lock(io)` call needs an `io` value that 0.15 has nowhere to
provide. A conditional compile based on `@hasDecl(std, "Io")` would force
the public API to degrade to a 0.15 shape on 0.15 and a 0.16 shape on 0.16,
which is strictly worse than shipping two lines. Pinning `0.1.x` for 0.15
users is the clean split.
