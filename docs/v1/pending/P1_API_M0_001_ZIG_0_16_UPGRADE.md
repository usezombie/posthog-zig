# P1 · API · M0 · 001 — Upgrade posthog-zig to Zig 0.16

- **Status:** PENDING
- **Priority:** P1
- **Categories:** API
- **Milestone:** M0
- **Workstream:** 001
- **Branch:** feat/m0-zig-0-16-upgrade
- **Created:** Apr 20, 2026: 12:00 PM
- **Owner:** @nkishore

## Context

`posthog-zig` pins `minimum_zig_version = "0.15.0"` (`build.zig.zon:5`) and CI runs on 0.15.2 across `.github/workflows/ci.yml` and `release.yml`. Zig 0.16.0 has shipped with breaking changes that prevent this library from building on modern toolchains:

- All networking APIs (`std.http.Client` family) migrated to `std.Io`.
- `std.io.Writer.Allocating` gained an alignment field; `fmt: Formatter` was renamed to `fmt: Alt`.
- `std.Build` module/test APIs reorganized.
- `heap.ThreadSafeAllocator` removed; `ArenaAllocator` is now thread-safe and lock-free.

This spec moves the library to 0.16, refreshes CI, and bumps the crate version to `0.2.0` (pre-v1 minor-for-breaking carve-out per global policy — the toolchain floor is user-visible).

The repo is small (28 `.zig` files, ~2,573 LOC, zero external dependencies in `build.zig.zon:6`), so the change is mechanical but touches the HTTP transport and the build system — both load-bearing.

## Golden path (end-to-end)

A consumer adds `posthog-zig` as a dependency on Zig 0.16.x. They construct a `Client`, call `captureEvent(...)`, and the batched event is POSTed to `https://us.i.posthog.com/batch/` through the new `std.Io`-based HTTP client. A separate `evaluateFlag(...)` call round-trips through `/decide/?v=3` and returns a `std.json.Value`. All four CI cross-compile targets build clean: `x86_64-linux`, `aarch64-linux`, `x86_64-macos`, `aarch64-macos`.

## Dimensions

Each dimension maps to a test case (spec → code → test contract, per global policy). A dimension is **DONE** only when the named symbol is called from a production entry point AND has a test that proves it works.

### 1. Build system migration (build.zig)

Reconcile `addTest`, `addModule`, `createModule`, and `b.path()` usage in `build.zig` with the 0.16 signatures. No behavior change — `zig build test`, `zig build test-caller`, `zig build test-unit`, `zig build test-bin`, and `zig build bench` must all produce the same steps they do today.

- **Test:** `zig build --help` lists the same steps as on 0.15.2; `zig build test` passes.
- **Acceptance:** `build.zig` compiles on 0.16; no step renamed or removed.

### 2. HTTP transport migration (src/transport.zig)

Rewire `postBatch` and `postDecide` onto the `std.Io`-based `std.http.Client`. Keep the existing `TransportError` surface and the exact `/batch/` + `/decide/?v=3` payload shapes.

- **Interfaces (post-upgrade signatures unchanged):**
  ```zig
  pub fn postBatch(
      allocator: std.mem.Allocator,
      host: []const u8,
      api_key: []const u8,
      events: []const []const u8,
  ) TransportError!u16;

  pub fn postDecide(
      allocator: std.mem.Allocator,
      host: []const u8,
      api_key: []const u8,
      distinct_id: []const u8,
  ) ![]u8;
  ```
- **Tests:** existing `postBatch: empty events returns 200`, `postBatch: builds correct JSON payload shape`, `postDecide: builds correct JSON payload shape` all pass.
- **Acceptance:** `zig build test` green; integration run (dimension 6) succeeds.

### 3. Writer.Allocating field renames (src/transport.zig tests)

Rename `fmt: Formatter` references to `fmt: Alt` if reached; update any struct-literal init that references reorganized fields. No functional change.

- **Test:** same tests as dimension 2 compile and pass.
- **Acceptance:** no `Formatter` symbol references remain (`git grep -n 'io\.Writer\.Allocating.*Formatter'` → 0 hits).

### 4. ArenaAllocator mutex audit (src/batch.zig)

`heap.ArenaAllocator` is now lock-free in 0.16. Audit `src/batch.zig:30,54` to decide whether the surrounding `std.Thread.Mutex` is still load-bearing. **Do not remove the mutex unless removal is obviously safe** — if in doubt, defer to a follow-up spec. Record the decision here.

- **Test:** `zig build test` still passes; caller simulation test remains green.
- **Acceptance:** decision documented inline in `batch.zig` if any change is made, otherwise no-op.

### 5. JSON API compatibility check (src/feature_flags.zig, src/transport.zig tests)

Confirm `std.json.parseFromSlice(std.json.Value, allocator, buf, .{})` still compiles on 0.16; update field accessors only if the compiler rejects current usage.

- **Test:** existing JSON payload-shape tests pass.
- **Acceptance:** no code changes required, OR minimal diff that leaves accessor semantics identical.

### 6. Integration verification (tests/integration_test.zig)

Run `zig build test -Dintegration=true` against a live PostHog project using `POSTHOG_API_KEY` from 1Password. Proves the new `std.Io`-routed HTTP client actually reaches the PostHog API — compile-pass alone is insufficient for an API rewire of this size.

- **Test:** integration test green, at least one real `/batch/` 2xx and one `/decide/?v=3` 2xx observed.
- **Acceptance:** screenshot or log snippet pasted into Ripley's Log at CHORE(close).

### 7. CI toolchain refresh (.github/workflows/ci.yml, release.yml)

Bump Zig to `0.16.x` (track latest patch) across both workflows. All 4 cross-compile targets in `ci.yml:89-100` must stay green.

- **Test:** branch CI green on push.
- **Acceptance:** CI summary screenshot / URL pasted into Ripley's Log; no workflow file references `0.15` anywhere (`git grep -n '0\.15' .github/` → 0 hits).

### 8. Version + docs (VERSION, build.zig.zon, README.md, docs/ARCHITECTURE.md)

Bump `VERSION` and `build.zig.zon:3` from `0.1.3` → `0.2.0`. Update `minimum_zig_version` in `build.zig.zon:5` from `0.15.0` → `0.16.0`. Update README Zig badge and `docs/ARCHITECTURE.md` Zig-version line.

- **Test:** `cat VERSION` → `0.2.0`; `grep minimum_zig_version build.zig.zon` → `0.16.0`.
- **Acceptance:** `<Update>` block appended to release notes (internal-only tag acceptable since API surface for consumers is unchanged aside from toolchain floor).

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

- [ ] `build.zig.zon:5` reads `minimum_zig_version = "0.16.0"`.
- [ ] `build.zig.zon:3` and `VERSION` read `0.2.0`.
- [ ] `zig build test` passes locally on Zig 0.16.x.
- [ ] All 4 cross-compile targets build clean.
- [ ] `zig build test -Dintegration=true` returns a 2xx from `/batch/` and `/decide/?v=3`.
- [ ] CI workflows bumped to `0.16.x`; branch CI green.
- [ ] README badge + `docs/ARCHITECTURE.md` updated.
- [ ] No `0.15` references remain outside release notes / CHANGELOG.
- [ ] Spec moved `pending/` → `active/` → `done/`, `Status: DONE`.
- [ ] `<Update>` block added to release notes.
- [ ] Ripley's Log at `docs/nostromo/LOG_APR_20_<HH_MM_SS>_M0_001.md` with integration evidence.

## Non-goals

- No behavioral changes to batching, retry, or flag evaluation logic.
- No public API surface changes beyond the toolchain floor.
- No dependency additions.
- No migration from `docs/v1/` — this spec bootstraps the tree; future specs follow the same layout.
