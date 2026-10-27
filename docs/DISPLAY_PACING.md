# Display-paced scrolling validation

Implemented and measured on 2026-10-27, macOS 15.6 (24G84), on the user's laptop. This is an independent implementation guided by [Niri's testing and timing study](NIRI_ANIMATION_TESTING.md).

## What changed

Scrolling now uses `NSScreen.displayLink(target:selector:)`, backed by CADisplayLink on the main run loop. The callback replaces one pending presentation pulse instead of queuing render jobs. It uses `targetTimestamp` to predict the short time until presentation; a bounded relative offset converts Core Animation uptime to the model's wall-time epoch. This is not a claim that AX writes present at that timestamp. [Apple screen display link](https://developer.apple.com/documentation/appkit/nsscreen/displaylink(target:selector:)), [timestamp guidance](https://developer.apple.com/documentation/quartzcore/cadisplaylink/timestamp).

Input events accumulate until a pulse is consumed. Gesture layout and spring sampling use the same timestamp for that update. A newer pulse supersedes an unconsumed older pulse; repeated pulses cannot be consumed twice. If a native call blocks, the next update samples the current trajectory rather than replaying missed frames. Actual native calls still run sequentially on the main thread.

The link pauses while idle and switches when the selected display changes. If the API is unavailable, or an existing link provides no callbacks for 100ms, a throttled 60Hz timer fallback prevents stranded windows. The active Space's display supplies the clock; independent simultaneous presentation at different refresh rates on multiple monitors has not been validated. Other layouts keep their existing motion paths.

Command execution also obtains a fresh action timestamp immediately before calling the engine. A regression found that slow synchronous desktop discovery could leave a queued resize with a timestamp older than its entire spring duration, causing the next sample to jump to completion. The socket-path regression failed before the fix and passes afterward. Pending scroll input now defers desktop rediscovery until presentation, preserving coalesced input.

## Real-app comparison

The same existing Chrome and Ghostty windows were resized through 600, 1000, 700, 1200, 650 and 1000 point requests, with rapid interruptions and settling pauses. Each app was temporarily placed in scroll layout on its existing Space. All layouts, the original active Space and final full work-area geometry were restored. No Dock restart or application-content actions were performed.

Two alternating pacing-off/on trials used the same signed binary and command sequence:

| App | Pacing off: sample interval p95 | Pacing on: sample interval p95 |
| --- | --- | --- |
| Ghostty | 22.64 / 22.65ms | 13.45 / 14.01ms |
| Chrome | 25.30 / 24.69ms | 17.81 / 21.24ms |

These are spring-sample completion intervals, including deliberate idle gaps, not displayed-frame intervals. There were no native frame-call failures and no timer fallback ticks in these alternating trials. The initial pre-update measurements and full rows are retained in the [comparison summary](evidence/pacing-24G84/comparison.json). This is a small local comparison, not a statistical performance guarantee.

The owned AppKit scenario runner also completed three repetitions through the new clock: 1362 samples, median interval 8.335ms, p95 9.203ms. A matching unpaced run produced 13238 samples with median 0.118ms, p95 5.608ms. The unpaced run's smaller intervals indicate excessive sampling between display refreshes, not greater displayed frame rate. The display-paced fixture still reports immediate native bounds disagreements, so execution success does not certify presentation synchronization.

A later verification exposed stale command timing (documented above). Its raw trace is retained, rather than discarded as an outlier. The final build includes the regression fix and was checked again on both apps. One of the earlier verification runs used a fallback tick, demonstrating that the fallback can occur on the live path; it must not be described as universally unused.

## Tests, controls and rollback

243 deterministic tests pass with warnings as errors, including newest-pulse replacement, single consumption, stale-pulse handling, throttled fallback, invalid timestamp rejection, gesture input coalescing, rediscovery deferral and fresh queued-command timing. The optimized signed binary builds without compiler warnings.

Pacing defaults to on in the native daemon. It can be compared or disabled without restarting:

```sh
./bin/shoji -m config scroll_frame_pacing off
./bin/shoji -m config scroll_frame_pacing on
```

The native scenario runner can compare both schedulers independently of user applications:

```sh
task build:fixture
./bin/shoji-harness-fixture motion-lab bin/unpaced.json 1 3
./bin/shoji-harness-fixture motion-lab-paced bin/paced.json 1 3
```

Existing [bounded trace capture](MOTION_LAB.md) remains opt-in. `presentation-tick` carries the predicted target in Core Animation uptime seconds, nominal period in `duration_ms`, and fallback flag in `value`; `unpaced-tick` distinguishes the comparison path. `command` marks actual execution. Input source timestamps remain in their separate CGEvent clock domain.

The pre-update executable is retained at `bin/pacing-20261027/shoji-before-pacing`. Raw traces, snapshots, and red/green regression output are under `bin/pacing-20261027/`. Preserve these before cleaning ignored build artifacts. Restore the executable atomically and restart only Shoji if a binary rollback is needed.

## Remaining limits

We have measured native-call and model-sample timing, not displayed FPS, screen-recorded motion quality or input-to-photon latency. Manual swipe reversal acceptance, simultaneous foreign-client movement and varied refresh-rate/output behavior remain open. Chrome still takes roughly 15–18ms at the 95th percentile for individual native frame calls in these trials, which can exceed an 8.33ms display interval. A display link cannot make those calls atomic, prevent all client repaint delays, or supply foreign clipping. Reason-aware resize presentation and further correction/gesture tuning remain subsequent work.

Final verification with the stale-clock fix: Ghostty sample p95 16.25ms, Chrome 17.11ms; no native frame-call failures or fallback ticks. Chrome produced 119 native frame calls and intermediate sizes through repeated requests. [Final summary](evidence/pacing-24G84/final.json).
