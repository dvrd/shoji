# Motion scenarios and timing capture

Implemented 2026-10-27, following the independent [Niri testing study](NIRI_ANIMATION_TESTING.md). The scenarios use Shoji's production layout and spring code. They do not copy Niri implementation or tests.

## Repeatable scenarios

```sh
task build:fixture
# No windows or GUI required; also run by CI.
./bin/harness-fixture motion-check bin/motion-check.json 1 3
# Disposable owned AppKit windows; run in the logged-in macOS session.
./bin/harness-fixture motion-lab bin/motion-normal.json 1 3
# Same model timeline, three times slower, one repetition.
./bin/harness-fixture motion-lab bin/motion-slow.json 3 1
```

Arguments are output path, slowdown (0.1–10; default 1), repetition count (1–10; default 1). The runner covers focus reversal, repeated width changes, gesture reversal/release, insertion/closing, stacked-row resizing, and small column/row adjustments. [Small-resize policy and validation](RESIZE_MOTION_QUALITY.md) explain its guarded size completion and existing positional coalescing tolerance. It checks finite positive geometry, completion and no immediate frame jump when focus/width/height retarget an already sampled trajectory. Model-only playback uses deterministic 120Hz clock steps; this does not assert a 120Hz native display.

Native playback uses the general run loop as a baseline. It records monotonic sample intervals, work duration, camera position/velocity, worst native bounds disagreement with expected/observed frames, and invalid readback counts. Native readings are taken immediately, without waiting for convergence. A passing execution/continuity result does not certify readback agreement or visual smoothness. The owned-window path is different from cross-process Accessibility.

The fixture creates and closes only its own windows. It does not restart Dock, change Spaces or manage user application windows. Slowdown is confined to this tool; live Shoji timing is unchanged.

## Capture real application motion

The installed daemon offers an opt-in memory capture:

```sh
./bin/shoji -m debug motion start
# Use scrolling layout in Chrome/Ghostty: reverse a swipe, change widths,
# focus quickly, and open/close a window.
./bin/shoji -m debug motion stop
./bin/shoji -m debug motion dump > bin/motion-real.json
./bin/harness-fixture motion-report bin/motion-real.json
./bin/shoji -m debug motion clear
```

Capture stops accepting records after 30 seconds or 8192 events, whichever is reached first. `start` discards the previous capture; `stop` preserves it; `dump` exports it; `clear` releases it. No files are written during motion. Export while stopped to keep serialization off the measured path. Capture records geometry and IDs, without application titles or window contents. It is disabled by default.

Event kinds: `input` (callback receipt plus CGEvent uptime timestamp), `input-consume`, `gesture-sample`, `sample` (spring tick completion), `native-frame` (AX/batch call duration and immediate bounds), and `loop`. Times are monotonic milliseconds relative to capture start; source input timestamps have their separately labeled CGEvent uptime clock. Do not subtract the two clock domains directly.

The report shows sample completion intervals (including idle gaps), native frame-call duration percentiles/failures and latest callback-to-consumption delay. A burst coalesces multiple input events, so the latest-event metric does not measure the oldest queued input. Native frame duration includes batch overhead and the additional diagnostic readback, rather than isolating AX time alone. Instrumentation affects timing and should be compared with uninstrumented observations.

These are CPU/WindowServer observations, not displayed FPS or input-to-photon latency. The initial tool-only baseline did not change scheduling. Shoji now has a [display-paced scheduler and real-app comparison](DISPLAY_PACING.md); perceptual parity and reason-aware resizing remain open.

## Validation

237 deterministic tests pass with warnings as errors. Three model repetitions produce 1371 samples; the complete frame trajectory is identical when the slowdown argument changes from 1 to 3 in model-only mode. Native normal-speed playback completed three repetitions with 5372 samples and zero invalid bounds readbacks. The broad sample interval distribution (p50 0.191ms, p95 15.289ms, p99 17.212ms) demonstrates that these are event-loop samples rather than display frames. Immediate native disagreement peaked at 642 points at insertion, while final samples settled within one point. Preserve this discrepancy for investigation rather than treating execution success as geometry synchronization.

Raw local artifacts: `bin/motion-lab-20261027/`. The service was restarted successfully with layouts, gesture setting and animation duration preserved; trace start/stop/export/clear were checked over IPC. Tracing was cleared afterward, and the animation recovery journal was empty. The pre-update executable is `bin/motion-lab-20261027/shoji-before-motion-trace`.

Three-times-slower native playback also completed (12393 samples, zero invalid readbacks). [Machine-readable baseline summary](evidence/motion-24G84/summary.json) preserves both runs. Slowdown stretches the scenario timeline; it does not rate-limit the general run loop.
