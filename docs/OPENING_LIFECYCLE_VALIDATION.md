# Shared opening lifecycle: implementation and validation

2026-10-27. Candidate implementation; real-application acceptance remains open.
The accepted contract is in `adr/0001-shared-window-opening-lifecycle.md`.

Native creation notifications and desktop enumeration now share `opening_observe`
and the engine's admission boundary. Discovery records a pending window without
inserting it into a layout. Preparation conceals the newcomer with the existing
journaled Dock proxy protocol, establishes accepted seed geometry, and plans
against a private copy of the current layout. Successful admission commits that
plan once. BSP applies native minima to effective split ratios without overwriting
requested ratios; scrolling preserves existing column widths. No readiness or
space failure changes a tiled newcomer into a floating window.

Pending windows retry independently. Duplicate observations do not replay an
entrance. A close removes membership immediately; later preparation uses the
remaining layout. Deliberate focus changes supersede an opening's completion.
A space-blocked window remains pending and gets a noninteractive notice. Clean
shutdown restores pending geometry and visibility; existing owner-checked recovery
records and Dock token liveness protect visibility after process failure.

## Checks completed

- All **255 Odin tests passed**, including admission, native-adapter convergence,
  focus precedence, readiness order, minimum-size constraints, layout rebuilds,
  scrolling entrance geometry, and move-only entrance without snapshot capture.
- Optimized application and native diagnostic helper compiled with warnings as
  errors and unused-symbol vetting. Candidate: `bin/shoji-lifecycle.new`.
- A controller restricted to disposable AppKit fixture windows exercised actual
  AX creation callbacks and native frame writes. The newcomer grew monotonically
  after preparation. Two ScreenCaptureKit streams requested only one pixel each
  inside the fixture: 32 red baseline samples, 23 green positive-control samples,
  **zero green samples over the existing window**. Log:
  `/tmp/shoji-first-presentation/lifecycle-fixture.log`.
- An impossible-fit native fixture stayed pending and outside the committed tree,
  retained its concealment guard, and created the room notice. Stopping the
  controller restored its original `{200,189,1400,828}` native frame. Log:
  `/tmp/shoji-first-presentation/lifecycle-blocked.log`.

The fixture controller and pixel sampler are temporary diagnostics under
`/tmp/shoji-birth-probe` and `/tmp/shoji-first-presentation`; they are supporting
evidence, not a substitute for the real-application matrix.

## Checks still required

No Mail/Ghostty/Chrome baseline-versus-candidate presented-frame comparison has
been completed for this implementation. Do not report the original visual issue
resolved. Do not treat the fixture or app-name adapter unit test as real-app proof.
The full acceptance matrix is in `NIRI_ANIMATION_TESTING.md`.

The user confirmed that the previous running build still flashes when opening
Mail. After that baseline confirmation, this session installed the signed
optimized candidate and restarted Shoji. It preserved animation duration `0.5`,
easing `ease_out_circ`, resize fade, scroll frame pacing, scroll animation, all
three BSP workspace layouts, and per-workspace padding, gap, ratio and placement
settings. Runtime snapshot: `/tmp/shoji-lifecycle-runtime-before.json`.
Previous binary backup: `/tmp/shoji-before-lifecycle-opening`.

The installed service responds to lifecycle-state queries. Existing Mail,
Ghostty and Chrome windows report `settled`. The metadata-only candidate observer
is `/tmp/shoji-opening-mail-candidate.log`. The candidate's real-app visual
outcome is still awaiting the repeated blank compose test; it is not a verified
fix. Automatic approval review previously rejected reading Mail's entire
Accessibility tree because it exposed private email content; that read was not
retried.


## Candidate feedback and diagnostic follow-up

The user reports that the candidate still flashes: the newcomer first appears at
its final shared tile size, becomes thin, then grows to that same final size.
The original visual issue is therefore **not resolved** by the candidate.

An instrumented optimized build is now running (`SHOJI_OPENING_TRACE=true`). It
automatically arms bounded in-memory motion capture on native window discovery.
The trace adds discovery, conceal/reveal native bounds and queried alpha, and all
native frame requests/results. It captures no titles or email contents. Read it
with `bin/shoji -m debug motion dump` after the repeated blank compose opening.
This is diagnostic instrumentation, not another claimed animation fix.

During this follow-up, resize-cover implementation and tests were being edited
concurrently in the same checkout. An intermediate full test run passed the
opening/admission tests but failed three resize-cover timing assertions; do not
reuse the earlier 255-test pass as a claim about this intermediate source state.

After the concurrent resize-cover edits settled, a fresh full test run passed
all **258 tests** (09:54 local). The Mail visual reproduction remains the required
next diagnostic step; this passing suite does not establish the visual outcome.


## Real Mail trace: delayed concealment during desktop collection

The metadata-only recorder captured multiple Mail openings in
`/tmp/shoji-mail-opening-capture/mail-*.json`. Mail was already at
`{866,42,858,1071}` on discovery. Shoji's first requested preparation frame was
`{1295,42,429,1071}`, followed by monotonic growth back to the 858-point tile.
The traces therefore distinguish the initial native size from Shoji's seed
request. Discovery-to-conceal request latency reached 303.6 ms during collection.

The confirmed code defect deferred all of `opening_attempt`, including masking,
until desktop collection ended. The fix extracts `stage_opening`: discovery
immediately stages/conceals an eligible newcomer before collecting appearance
and before continuing the desktop scan. Candidate layout planning, geometry
preparation, and admission still wait until collection completes, so closed
peers are removed before committing a plan. The regression
`newcomer_is_concealed_during_collection_before_other_apps_are_scanned` failed
before this change and passes afterward. All 262 tests passed on the final code.

A client-side system-alpha experiment was not representative of Dock privilege.
The follow-up pixel test through the exact existing Dock proxy command showed
concealment in approximately 29 ms and restoration in approximately 9 ms, with
ordinary alpha as a positive control. The proposed ordinary-opacity backend and
recovery changes were discarded before installation. Dock payload and protocol
remain unchanged by this fix. The nominal alpha query did not measure the
system-alpha mask and was removed from the diagnostic helper.

The native delayed-concealment negative control reproduces the flash under a
300 ms collection stall: two green samples over the existing red window, with
both baseline and newcomer positive controls present. Evidence:
`/tmp/shoji-first-presentation/delayed-control.log`.

The matching native positive test passed with zero first-frame flash samples,
9 red baseline samples and 2 newcomer positive-control samples. The new window
grew monotonically after preparation. Evidence:
`/tmp/shoji-first-presentation/early-conceal.log`.

Installed the optimized immediate-discovery-concealment candidate after those
checks, preserving runtime settings and all three BSP layouts. Snapshot:
`/tmp/shoji-early-conceal-runtime-before.json`; previous executable:
`/tmp/shoji-before-early-conceal`. The real Mail candidate comparison is recorded
separately under `/tmp/shoji-mail-early-conceal-capture`. Its presented visual
outcome remains pending user confirmation; the native fixture result is not a
claim that the original real-app issue is resolved.
