# Logic and memory allocation review

Reviewed 2026-10-27 against the current worktree on macOS 15.6 (24G84), ARM64.
The findings below record the initial review, with isolated reproductions and
read-only measurements of the previously installed daemon. The implementation
and regression fixes were subsequently completed; see the resolution record at
the end. The initial measurements are historical baselines.

Four actionable correctness findings were identified. The native allocation
finding deserves priority, followed by animation identity and failed geometry.

1. **P1 — Periodic Cocoa work lacks a surrounding autorelease pool.**
   [The daemon loop](../src/macos/runtime_darwin.odin) runs
   [workspace polling](../src/macos/runtime_darwin.odin) outside an autorelease
   pool. `refresh` has its own pool, but draining that later nested pool does not
   release objects autoreleased before it was pushed. In an isolated process using
   the same `runningApplicationsWithBundleIdentifier:` call, 200 warmed-up polls
   retained 800 native allocations / 54,400 bytes. Draining the surrounding pool
   released that growth completely. Giving each poll a pool produced zero live
   allocation growth. Add a pool around the complete main-loop iteration, with
   cleanup on every exit. Audit initialization and callbacks outside that scope.
   This confirms one retention source; it does not attribute the daemon's entire
   physical footprint or all observed growth to this particular call.

2. **P2 — An animation can resize a replacement window with the same ID.**
   [Animation jobs](../src/macos/motion_darwin.odin) retain a window ID and
   geometry without its process identity/generation.
   [The tick](../src/macos/motion_darwin.odin) checks whether that ID exists,
   then applies the old animation. The reproduction starts a live resize for PID
   42, removes that window, inserts PID 99 with the same ID, and ticks the original
   animation: the new window receives one stale resize and its frame changes.
   Store/check identity on jobs and cancel jobs when observations replace or remove
   a window. Apply the same guard to completion and interruption paths, so cleanup
   cannot apply an old final target to a replacement.

3. **P2 — Failed geometry reads overwrite known-good geometry.**
   [window_frame](../src/macos/backend_darwin.odin) returns a plain Rect even
   when AXPosition/AXSize reads or AXValue conversion fail. Zero-initialized fields
   then reach [reconciliation](../src/macos/runtime_darwin.odin), which
   unconditionally overwrites the previous frame. The model-side reproduction
   feeds such an invalid observation and turns a valid 800 × 600 frame into a
   zero rectangle.
   Position-only failure can instead look like a move to the origin. Carry read
   validity explicitly, preserve the prior frame on failure, and only update size
   feedback from valid observations. Include partial attribute-read failures in
   regression coverage.

4. **P2 — Display-link initialization cannot recover on the same display.**
   [Creation](../src/macos/motion_darwin.odin) requires both a nil link and a
   changed display, but sets `clock.display` before several fallible native calls.
   A missing screen or nil display link leaves the remembered display set; later
   calls for it skip initialization forever. A probe seeded with that failure state
   remains without a link/listener and does not start. Retry whenever the link is
   absent, with bounded backoff and cleanup of partially initialized listeners.
   Keep the existing fallback clock usable while retrying.

The live memory measurements show why RSS alone is insufficient:

| Measurement | First sample | Second sample |
| --- | ---: | ---: |
| Time, local | 17:44:27 | 17:48:19 |
| Physical footprint, vmmap | 223.6M | 227.0M |
| Default malloc-zone live blocks | 2,951,385 | 2,999,081 |
| Default malloc-zone allocated bytes, vmmap | 185.3M | 188.4M |

An earlier `ps` reading showed only 21,648 KiB RSS. `vmmap` reports substantial
swapped-out memory, which explains why that resident reading understates the
accounted footprint. The two samples establish growth during this interval, not
a long-term leak rate. Full attribution of the roughly three million live native
allocations remains open; the read-only review did not walk the live object's heap
or record allocation stack traces. Large reserved/purgeable virtual regions are
not equivalent to committed physical memory or a proven leak.

Odin-managed lifetime results were substantially better:

| Workload | Result |
| --- | --- |
| 100 BSP create/configure/query/remove/destroy cycles, 24 windows each | Zero retained tracked bytes; zero bad frees |
| Same workload with Scroll layout | Zero retained tracked bytes; zero bad frees |
| 1,000 snapshots of 24 unchanged windows, then teardown | Zero retained tracked bytes; zero bad frees |
| Existing core suite, leak failures enabled | 266 passed |
| Existing harness suite, leak failures enabled | 16 passed |
| Existing scanner suite, leak failures enabled | 17 passed |

The suites used `ODIN_TEST_FAIL_ON_BAD_MEMORY=true` and
`ODIN_TEST_ALWAYS_REPORT_MEMORY=true`. They cover tracked Odin allocations, not
all malloc/CoreFoundation/Objective-C/graphics resources. Regex allocations and
other foreign allocations also require native instrumentation.

There are three allocation-quality improvements worth making:

- **Reuse scratch arenas.** The daemon creates/destroys a Dynamic_Arena each tick;
  the AX observer does the same per callback. A synthetic 10,000 small-formatting
  workload made 20,000 backing allocations, requesting 656,000,000 bytes in total,
  with only 65,600 bytes peak live. Reusing/resetting one arena needed two backing
  allocations and 65,600 total bytes. Both cleaned up completely. This measures
  churn, not a leak or proven animation bottleneck. Use an owned reusable arena
  for the main loop; keep callback scratch safe for nested/reentrant delivery.
- **Avoid rebuilding unchanged snapshots.**
  [observe_changes](../src/macos/workspaces_darwin.odin) recreates maps and
  clones application/window strings on every refresh. The 1,000 unchanged
  observations made 53,002 tracked backing allocations, including per-iteration
  arena overhead, despite no semantic changes. Reuse map capacity and retained
  strings, or update a persistent observation snapshot incrementally. Preserve
  the existing ownership of strings across tick boundaries.
- **Budget captured pixels/bytes, not only window count.** Resize transitions
  [limit concurrent covers to eight](../src/macos/motion_darwin.odin) but have
  no aggregate byte/pixel budget. As an illustrative calculation, eight initial
  3840 × 2160 images at four bytes per pixel require about 253 MiB before backing
  surfaces and any final images. Actual allocation depends on capture format and
  scale. Existing release paths and cover deadlines are useful; add native-image
  size accounting and a fallback when the budget is exhausted. This is a resource
  risk, not a demonstrated capture leak.

The bounded motion trace is about 1.06 MiB at its 8,192-event limit. IPC limits
concurrent clients to 32 and request bodies to 1 MiB; slow responses own their
storage across ticks. Window strings, trees, rule filters and observation snapshots
showed correct teardown in the exercised paths. PBZM decoding uses explicitly
freed bounded buffers rather than retaining the entire decoded archive.

The normal Taskfile test commands do not enable `ODIN_TEST_FAIL_ON_BAD_MEMORY`.
The pinned Odin test runner defaults it to false. Enable that flag in the routine
test/CI commands, and add a separate native allocation soak test. Passing the
existing test suite should not be treated as proof that native retention is absent.

Recommended sequence: fix autorelease scope and add its native regression, guard
animation identities, preserve failed observations, repair display-link retries,
then implement reusable arenas and snapshot reuse. Measure a bounded interactive
workload before tuning screenshot budgets or claiming an improvement in smoothness.

Evidence is retained under `.cruft/memory-review/`: the isolated probe source and
output, strict-memory test logs, and both `vmmap` summaries. Rebuild the probe with
the pinned compiler and private-framework linker path; its native application
polling requires the user's login-session access. The timing numbers are synthetic
and machine-specific. Temporary validation executables are removed after review.

## Resolution — 2026-10-27

All four correctness findings have implementation and regression coverage.
The daemon now drains native autoreleases every iteration; the polling helper
also owns its pool for callers outside that loop. Reusable scratch storage is
safe for nested AX callbacks and releases exceptional bursts. Animation jobs and
resize covers carry window-generation identity, including same-process ID reuse.
Geometry observations carry validity and preserve prior frames on read failure.
Display-link failures clean up partial listeners, preserve fallback pacing and
retry with a 500ms deadline.

Observation storage alternates between two owned snapshots, reusing maps and
unchanged strings while keeping before/after event data independent. The measured
1,000-observation workload dropped from 53,002 backing allocations to 106, including
initialization; teardown retained zero tracked bytes. A warmed snapshot regression
checks that 1,000 unchanged observations allocate no new owned storage.

Retained resize images are measured using image row bytes and height, and owned
surface backing is estimated from dimensions. A 128 MiB aggregate budget admits
initial, final and interrupted-fade captures, with preflight checks before capture
and release accounting on teardown/error. This limits retained capture data,
rather than promising an operating-system-wide hard memory limit.

The regular test tasks now enable `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`. A separate
`task test:memory` runs the production polling helper in a native malloc soak:
2,000 polls measured zero live bytes and zero live blocks of growth. It requires a
logged-in session with Dock and does not silently pass a missing prerequisite.

Validation: 274 core tests on ARM64 and Intel/Rosetta, 16 harness tests, 17 scanner
tests, warning-strict checks, compiler diagnostics, and 1,479 motion samples passed.
Real CoreGraphics images exercise capture reservation and release; nested-callback,
snapshot ownership, reused-ID and partial-read regressions cover the new lifetimes.
The Intel loader timed out once under concurrent builds; its isolated retry and
the final full Intel run passed.

The signed build was installed with the existing persistent identity and the
Shoji LaunchAgent restarted once. All four BSP Space layouts were preserved.
The initial post-startup sample was 19.4M physical footprint with 10,214 default
malloc-zone live blocks; startup peak was 54.7M. This fresh-process reading alone
does not establish a long-term improvement over the historical process.

A follow-up on the same process at 18:30:23, 234 seconds after the first sample,
reported 19.3M footprint and 8,428 default malloc-zone live blocks. The historical
process grew from 223.6M to 227.0M over a comparable 232-second interval. The new
process showed no sustained native allocation growth during this short soak.
Longer interactive workloads can still exercise caches and graphics allocations
that this four-minute interval does not cover. Raw evidence is retained in
`.cruft/memory-fixes/live-after-first.txt` and `live-after-second.txt`.
