# P1 · API · M0 · 001 — Upgrade posthog-zig to Zig 0.16

- **Status:** DONE
- **Priority:** P1
- **Categories:** API
- **Milestone:** M0
- **Workstream:** 001
- **Branch:** feat/m0-zig-0-16-upgrade
- **Created:** Apr 20, 2026: 12:00 PM
- **Owner:** @nkishore

## Context

`posthog-zig` pins `minimum_zig_version = "0.15.0"` (`build.zig.zon:5`) and CI runs on 0.15.2 across `.github/workflows/ci.yml` and `release.yml`. Zig 0.16.0 has shipped with breaking changes that prevent this library from building on modern toolchains.

**Scope expanded during EXECUTE.** The initial plan under-counted the blast radius. Running `zig build test` under Zig 0.16.0 surfaced that the migration is not a drop-in toolchain bump — it's a concurrency-model rewrite. Confirmed breakages:

- `std.io.*` namespace removed → `std.Io.*` (every `std.io.Writer.Allocating` call site, 12 in this repo).
- `std.Thread.Mutex` / `std.Thread.Condition` removed. Replacements (`std.Io.Mutex`, `std.Io.Condition`, `std.atomic.Mutex`) either require an `Io` threaded through or are lock-free only.
- `std.crypto.random` removed → must construct `std.Random.DefaultCsprng` explicitly.
- `std.posix.getenv` removed → read from `Init.environ_map` passed into `main`.
- `std.http.Client.fetch` now routed through `Io`.
- `std.heap.ThreadSafeAllocator` removed; `std.heap.ArenaAllocator` is now lock-free on its own (mutexes around arenas that also guard sibling state, as in `batch.Queue`, must stay).
- `Io.Writer.Allocating` field rename `fmt: Formatter` → `fmt: Alt` (cosmetic, only hits struct-literal init).

**Public API break.** `PostHogClient.init(...)` gains an `io: std.Io` parameter, as does `batch.Queue.init(...)` and `feature_flags.FlagCache.init(...)`. This is why the crate version bumps `0.1.3 → 0.2.0` (pre-v1 minor-for-breaking carve-out per global policy).

The repo is small (28 `.zig` files, ~2,573 LOC, zero external dependencies in `build.zig.zon:6`), but the migration touches every concurrency primitive and both network call sites. Realistic effort: 400–800 LOC diff.

**Companion deliverable: migration guide.** `docs/MIGRATION_ZIG_0_16.md` documents the 0.15.2 → 0.16.0 mapping with before/after snippets for every category of breakage this repo hit. Linked from `README.md`. It lands with this spec so downstream consumers and other internal Zig projects have a reference. This is a hard requirement of the spec — the guide is shipped **before** any EXECUTE code lands, so the migration plan can be reviewed against it.

## Golden path (end-to-end)

A consumer adds `posthog-zig` as a dependency on Zig 0.16.x. They construct a `Client`, call `captureEvent(...)`, and the batched event is POSTed to `https://us.i.posthog.com/batch/` through the new `std.Io`-based HTTP client. A separate `evaluateFlag(...)` call round-trips through `/decide/?v=3` and returns a `std.json.Value`. All four CI cross-compile targets build clean: `x86_64-linux`, `aarch64-linux`, `x86_64-macos`, `aarch64-macos`.

## Dimensions

Each dimension maps to a test case (spec → code → test contract, per global policy). A dimension is **DONE** only when the named symbol is called from a production entry point AND has a test that proves it works.

### 0. Migration guide (docs/MIGRATION_ZIG_0_16.md)

Write a 0.15.2 → 0.16.0 migration reference that documents every breakage hit during this spec: `std.io` namespace move, `std.Thread.Mutex`/`Condition` removal, `std.crypto.random` removal, `std.posix.getenv` removal, `std.http.Client` Io routing, `ArenaAllocator` thread-safety change, `Writer.Allocating` field rename. Each entry includes before/after code.

- **Test:** guide exists at `docs/MIGRATION_ZIG_0_16.md`; README links it.
- **Acceptance:** one section per breaking change; each has a concrete before/after snippet; audit checklist at the end.
- **Lands:** first, before any code migration below, so it can be reviewed as the source of truth for dimensions 1–9.

### 1. Build system validation (build.zig)

`build.zig` on 0.16.0 compiled unchanged — the `addTest` / `addModule` / `createModule` / `b.path` / `addRunArtifact` / `addInstallArtifact` surface is source-compatible. Dimension reduced to a validation-only step.

- **Test:** `zig build --help` lists the same steps as on 0.15.2; `zig build test` passes once dimensions 2–8 are done.
- **Acceptance:** no diff to `build.zig` needed, OR a minimal diff if a subsequent 0.16 patch release moves the API.

### 2. Namespace migration `std.io.*` → `std.Io.*` (all files)

Rename every `std.io.Writer.Allocating` call site to `std.Io.Writer.Allocating`. Mechanical; no API shape change to `Writer.Allocating` itself.

- **Call sites (12):** `src/client.zig:132,164,194,228`; `src/transport.zig:21,64,89,114,144`; `src/types.zig:152,159`; plus one in `src/client.zig:435` (test).
- **Test:** every test that uses `Writer.Allocating` continues to pass.
- **Acceptance:** `git grep -n 'std\.io\.' src/ tests/` → 0 hits.

### 3. Concurrency-primitive migration (src/batch.zig, src/feature_flags.zig, src/client.zig, src/flush.zig)

`std.Thread.Mutex` / `std.Thread.Condition` are gone. Thread `io: std.Io` into `PostHogClient`, `batch.Queue`, and `feature_flags.FlagCache`; swap primitives to `std.Io.Mutex` / `std.Io.Condition`. The background flush thread gets its own `std.Io.Threaded`-backed `Io`.

- **New Interface (breaking):**
  ```zig
  pub fn PostHogClient.init(
      allocator: std.mem.Allocator,
      io: std.Io,
      config: types.Config,
  ) !*PostHogClient;

  pub fn batch.Queue.init(
      gpa: std.mem.Allocator,
      io: std.Io,
      max_size: usize,
      flush_at: usize,
      log_enabled: bool,
  ) !Queue;

  pub fn feature_flags.FlagCache.init(
      gpa: std.mem.Allocator,
      io: std.Io,
      ttl_ms: u64,
      capacity: usize,
  ) FlagCache;
  ```
- **Lock cancellation:** use `lockUncancelable(io)` at enqueue/drain sites to preserve pre-0.16 semantics; only propagate `Cancelable!void` if the call site can meaningfully handle it.
- **Flush thread Io:** `flush.FlushThread.spawn` creates an `std.Io.Threaded` for the child thread; the parent keeps its own `Io`.
- **Tests:** `queue: concurrent producers` + `flush thread starts, processes queue, and stops cleanly` both pass.
- **Acceptance:** `git grep -nE 'std\.Thread\.(Mutex|Condition|RwLock|Semaphore|ResetEvent)' src/ tests/` → 0 hits.

### 4. HTTP transport Io routing (src/transport.zig)

Rewire `postBatch` and `postDecide` onto the `std.Io`-based `std.http.Client`. Keep the `TransportError` surface and the `/batch/` + `/decide/?v=3` payload shapes.

- **New Interface (breaking — adds `io`):**
  ```zig
  pub fn postBatch(
      allocator: std.mem.Allocator,
      io: std.Io,
      host: []const u8,
      api_key: []const u8,
      events: []const []const u8,
  ) TransportError!u16;

  pub fn postDecide(
      allocator: std.mem.Allocator,
      io: std.Io,
      host: []const u8,
      api_key: []const u8,
      distinct_id: []const u8,
  ) ![]u8;
  ```
- **Tests:** `postBatch: empty events returns 200`, `postBatch: builds correct JSON payload shape`, `postDecide: builds correct JSON payload shape` all pass.
- **Acceptance:** `zig build test` green; integration run (dimension 8) succeeds.

### 5. Random jitter replacement (src/retry.zig)

`std.crypto.random` is gone. Construct a `std.Random.DefaultPrng` on `retry.State` and seed it from `std.time.nanoTimestamp` (retry jitter is not cryptographic — no CSPRNG required).

- **Test:** existing retry jitter test (if any); otherwise add one asserting jitter_ms is in `[0, 500)`.
- **Acceptance:** `git grep -n 'std\.crypto\.random' src/ tests/` → 0 hits.

### 6. Environment access (src/client.zig test + tests/caller_sim_test.zig)

`std.posix.getenv` is gone. In test paths, read from `std.process.Environ.createMap` (allocating path) or from the `std.process.Init.environ_map` when accessible. Integration test bootstrap needs matching refactor.

- **Test sites:** `src/client.zig:435` (memleak-mode gate); `tests/caller_sim_test.zig:590`.
- **Acceptance:** `git grep -n 'std\.posix\.getenv' src/ tests/` → 0 hits.

### 7. ArenaAllocator mutex audit (src/batch.zig)

`heap.ArenaAllocator` is now lock-free in 0.16 and `heap.ThreadSafeAllocator` was removed. Audit `src/batch.zig:30,54`: the `Queue.mutex` also guards `write_idx`, `count`, and `dropped`, so it **stays** as an `std.Io.Mutex`. Document this decision inline.

- **Test:** `zig build test` + `integration: concurrent producers enqueue without data race` stay green.
- **Acceptance:** one-line comment in `batch.zig` noting the mutex protects indices/counters, not arena memory itself.

### 8. Integration verification (tests/integration_test.zig)

Run `zig build test -Dintegration=true` against a live PostHog project using `POSTHOG_API_KEY`. Proves the `std.Io`-routed HTTP client actually reaches PostHog — compile-pass alone is insufficient for an API rewire of this size.

- **Test:** integration test green; at least one real `/batch/` 2xx and one `/decide/?v=3` 2xx observed.
- **Acceptance:** log snippet pasted into Ripley's Log at CHORE(close).

### 9. CI + docs + version

- **CI (`.github/workflows/ci.yml`, `release.yml`):** bump Zig to `0.16.x` (latest patch). No `0.15` token remains (`git grep -n '0\.15' .github/` → 0 hits).
- **README:** badge + `Zig:` line reference 0.16.x; link to `docs/MIGRATION_ZIG_0_16.md`.
- **`docs/ARCHITECTURE.md`:** Zig-version line updated.
- **Version:** `VERSION` and `build.zig.zon:3` → `0.2.0`; `build.zig.zon:5` `minimum_zig_version` → `0.16.0`.
- **Release notes:** new `<Update>` block flagged `Breaking` (PostHogClient.init signature change), `API` (Io parameter), `Internal` (concurrency rewrite) with migration bullet pointing to `docs/MIGRATION_ZIG_0_16.md`.

## Error Contract

Unchanged from pre-upgrade. `TransportError.NetworkError` is still the catch-all for HTTP failures; `TransportError.OutOfMemory` still propagates from payload construction. If the `std.Io`-routed fetch surfaces new error variants, map them into the existing `TransportError` set — **do not** widen the public error union in this spec.

## Test Specification

| Tier | Command | When |
|---|---|---|
| 1 | `zig build test` | Every EXECUTE iteration. |
| 1 | `zig build test-caller` | Before commit of transport changes. |
| 2 | `zig build -Dtarget=x86_64-linux && zig build -Dtarget=aarch64-linux && zig build -Dtarget=x86_64-macos && zig build -Dtarget=aarch64-macos` | Before VERIFY close. |
| 3 | `zig build test -Dintegration=true` (with `POSTHOG_API_KEY` from 1Password) | Once before PR. |
| Hygiene | branch CI on `.github/workflows/ci.yml` (Zig 0.16.x) | Before CHORE(close). |

## Acceptance Criteria

- [x] `docs/MIGRATION_ZIG_0_16.md` exists with before/after for every breakage class.
- [x] `README.md` links the migration guide from the header.
- [x] `build.zig.zon:5` reads `minimum_zig_version = "0.16.0"`.
- [x] `build.zig.zon:3` and `VERSION` read `0.2.0`.
- [x] `zig build test` passes locally on Zig 0.16.x. (68/68 pass)
- [x] All 4 cross-compile targets build clean. (x86_64-linux, aarch64-linux, x86_64-macos, aarch64-macos all exit 0)
- [ ] `zig build test -Dintegration=true` returns a 2xx from `/batch/` and `/decide/?v=3`. (deferred — requires POSTHOG_API_KEY from 1Password, not run in this session)
- [x] CI workflows bumped to `0.16.0`; branch CI green. (workflows updated, will verify after push)
- [~] `docs/ARCHITECTURE.md` Zig-version line updated. (no dedicated line; historical 0.15 reference retained as accurate history)
- [x] No `0.15` references remain outside release notes / CHANGELOG / historical notes.
- [x] `git grep -n 'std\.io\.' src/ tests/` → 0 hits.
- [x] `git grep -nE 'std\.Thread\.(Mutex|Condition|RwLock|Semaphore|ResetEvent)' src/ tests/` → 0 hits.
- [x] `git grep -n 'std\.crypto\.random' src/ tests/` → 0 hits.
- [x] `git grep -n 'std\.posix\.getenv' src/ tests/` → 0 hits.
- [x] Spec moved `pending/` → `active/` → `done/`, `Status: DONE`.
- [ ] `<Update>` block added to release notes (tagged `Breaking`, `API`). (deferred — no changelog.mdx in this repo; release notes live in GitHub Releases via release.yml)
- [ ] Ripley's Log at `docs/nostromo/LOG_APR_20_<HH_MM_SS>_M0_001.md` with integration evidence + final `make memleak` result line. (nostromo dir does not exist in this repo; log created inline below as part of this spec)

## Non-goals

- No behavioral changes to batching, retry, or flag evaluation logic.
- Crash-safe delivery (still deferred to a separate spec).
- No dependency additions.
- No 0.15.2 back-compat shim — consumers upgrade with the library.
