# Fixture-only visual swipe experiment

This diagnostic compares two foreign fixture windows moved by Accessibility and a separate controller-owned blue indicator. It alternates the same 50-step forward/reverse trajectory with and without the `SLSDisableUpdate`/`SLSReenableUpdate` calls used by Shoji. A ScreenCaptureKit display filter includes only those three windows. The program stores per-frame color-edge coordinates and monotonic callback times, not images or application contents, and separately stores call timings.

The fixture must be the same executable, expose exactly two windows with the exact fixture titles and IDs, and run in the logged-in GUI session. The run script installs a temporary title-specific float rule in the active Shoji daemon, launches the fixture, and removes the rule and fixture on exit. It does not restart Shoji, Dock or WindowServer. This test uses private SkyLight APIs and requires existing Accessibility and Screen Recording permissions for the signed controller.

Build and run from the repository root. The persistent signing operation uses Shoji's configured local certificate and designated identifier; it does not replace the installed executable.

```sh
mkdir -p /tmp/shoji-swift-cache
CLANG_MODULE_CACHE_PATH=/tmp/shoji-swift-cache xcrun clang -Wall -Wextra -Werror -c \
  tools/harness/swipe-visual/transaction.c -o /tmp/shoji-swipe-transaction.o
CLANG_MODULE_CACHE_PATH=/tmp/shoji-swift-cache SWIFT_MODULECACHE_PATH=/tmp/shoji-swift-cache \
  xcrun swiftc -warnings-as-errors tools/harness/swipe-visual/main.swift /tmp/shoji-swipe-transaction.o \
    -o /tmp/shoji-swipe-visual.new -F /System/Library/PrivateFrameworks -framework SkyLight
./bin/dev signing sign /tmp/shoji-swipe-visual.new --install /tmp/shoji-swipe-visual --codesign codesign
zsh tools/harness/swipe-visual/run.zsh
```

The controller tests the update-suppression primitive with AX movement and an AppKit indicator. It does not execute the actual Shoji gesture path, use the production focus-ring surfaces or record physical display scanout. ScreenCaptureKit can drop or independently compose frames. A complete color readback does not prove input alignment or uninterrupted presentation. Sampling must be assessed before drawing conclusions, and no precise input-to-photon latency can be inferred from callback timestamps.

## Recorded run: macOS 15.6, 24G84

On 2026-10-28, two batched and two unbatched trials produced 242 analyzed trial frames; all contained the three color markers. The stationary red-to-green pixel-edge distance was 21 capture pixels and the red-to-blue indicator offset was 12 pixels (capture scale 1). The edge convention is `greenLeft - redRight`, so 21 is not a 21-point native-window gap. Both modes produced 17–25 pixel edge distances and 8–16 pixel indicator offsets. Frames with a nonbaseline edge distance: 40/123 batched and 35/119 unbatched. These four short trials do not establish a statistically meaningful difference; they do show that the captured scene is not always presented at the planned common 4-point step in either mode.

Across 50 calls per trial, mean elapsed time for the two AX position calls, indicator update and any batching was 2.05–2.52 ms batched and 1.00–1.25 ms unbatched. This small control does not establish production latency or causation. Nominal capture interval was 1/60 second. The initial color calibration run was inconclusive because the green detector used inappropriate thresholds; it was not included in these results. Raw experiment outputs are retained in Git history at commit `aa84c45`.

The fixture process and windows were gone and the temporary rule absent after the run. Original temporary logs were `/tmp/shoji-swipe-visual.TSZ9Dqvr/`. Source compiled with Swift warnings treated as errors. The normal daemon's layout, input and actual focus ring were not changed for this experiment.

## Production motion path experiment

`controller/main.odin` builds a separate PID-scoped controller using Shoji's real engine, `motion_frame_tick`, AX backend, update batch and native focus-ring surfaces. It validates the fixture executable path, both titles and each WindowServer owner PID, and rejects other windows. It uses a blue ring to distinguish it from the red and green fixture contents; the ring construction and motion logic are the production implementation. An explicit readiness file synchronizes capture startup; the controller fails if its trajectory never moves at least 30 points. The scroll samples are synthetic, and the controller is not the running daemon or its actual display-link scheduler.

To build the isolated controller after building the Swift helper above, then run the test:

```sh
ODIN_ROOT="$PWD/.toolchain/Odin" .toolchain/Odin/odin build tools/harness/swipe-visual/controller \
  -out:/tmp/shoji-swipe-controller.new -o:speed -warnings-as-errors -target-features:pauth \
  -extra-linker-flags:'-F/System/Library/PrivateFrameworks'
./bin/dev signing sign /tmp/shoji-swipe-controller.new --install /tmp/shoji-swipe-controller --codesign codesign
zsh tools/harness/swipe-visual/run-production.zsh
```

On 2026-10-28 the controller submitted 50 successive 4-point gesture movements and then settled, while ScreenCaptureKit included both fixture windows and all eight real ring surfaces. The controller logged 100 AX frame events with no reported errors; all 100 immediate native-bounds reads were 4 points behind their requested X position. Across the 50 moving samples, the left ring plan was also 4 points behind the focused window's requested model frame. This is consistent with the implementation reading the current native bounds for ring placement; it does not prove why WindowServer or the fixture had not applied the request at the time of readback.

Capture returned 138 frames, of which 111 had all three colors detectable on the scanline. The blue marker was not detected in 27 frames; the moving ring approached the display edge, and a missing marker must not be interpreted as its disappearance. The measured red/green edge distance varied from 13 to 24 capture pixels across complete frames, compared with a 24-pixel stationary baseline; this edge distance is affected by the ring overlay and edge detection and is not the model's 16-point native gap. Some frames showed red before the detected blue ring at the left edge, but ScreenCaptureKit's filtered output and callback timestamps do not independently establish physical display presentation order or input-to-photon latency.

The 4-point finding is a same-tick request/readback comparison, not proof that production app windows or all refresh rates behave identically. Two earlier runs were rejected: a fixture without a resizable style could not accept layout, and a later fixture had scroll input disabled and produced no motion. The running Shoji service and Dock were not restarted, and the fixture and temporary rule were confirmed absent after the successful run.

## Ring-position strategy investigation

The separate controller also supports `observed`, `requested` and experimental `hybrid` focus-frame probes. The hybrid uses the requested frame only when the independently observed frame is within 4.5 points in position and one point in size; otherwise it falls back to observed geometry. This threshold was chosen only for the experiment, not as a production recommendation. The `ignored` mode simulates an application silently ignoring movement by suppressing the focused fixture's frame operation; it does not emulate an actual AX error. The `slow` fixture blocks its own AppKit main thread for 80 ms every 200 ms. The final argument sets the synthetic movement step. For example:

```sh
zsh tools/harness/swipe-visual/run-production.zsh hybrid ignored normal 4
zsh tools/harness/swipe-visual/run-production.zsh hybrid normal slow 4
zsh tools/harness/swipe-visual/run-production.zsh hybrid normal normal 8
```

Results from one run of each condition on 24G84, using 50 moving samples, are below. The pixel measurements use only complete color detections from callback times between controller sample 0 and 49, excluding frames where the red left edge is near the display edge or the detected blue surface is far to its right. Stationary red-to-blue edge offset was 7 capture pixels. Callback times are not display timestamps; filtering, occlusion, display-edge clipping and unequal sample counts limit comparison. In particular, a frame can include older compositor content than its callback time.

| Condition | Ring-plan versus requested model position | Captured frames with baseline 7-pixel edge offset | Captured offset range |
| --- | --- | --- | --- |
| Observed, normal, 4-point step | 50/50 differed, maximum 4 points | 44/69 | -4 to 7 pixels |
| Requested, normal, 4-point step | 0/50 differed | 49/68 | -4 to 7 pixels |
| Hybrid, normal, 4-point step | 0/50 differed | 47/63 | -4 to 7 pixels |
| Observed, simulated ignored move | 49/50 differed, maximum 100 points | 59/59 | 7 pixels |
| Requested, simulated ignored move | 0/50 differed | 3/76 | 7 to 96 pixels |
| Hybrid, simulated ignored move | 47/50 differed, maximum 100 points | 58/58 | 7 pixels |
| Observed, slow fixture | 50/50 differed, maximum 4 points | 50/87 | -4 to 7 pixels |
| Requested, slow fixture | 0/50 differed | 71/86 | -4 to 7 pixels |
| Hybrid, slow fixture | 0/50 differed | 70/87 | -4 to 7 pixels |
| Observed, normal, 8-point step | 46/50 differed, maximum 8 points | 13/38 | -8 to 9 pixels |
| Hybrid, normal, 8-point step | 46/50 differed, maximum 8 points | 16/35 | -8 to 9 pixels |
| Requested, normal, 8-point step | 0/50 differed | 19/35 | -8 to 9 pixels |

The slow fixture produced maximum individual native frame calls of 76.1 ms observed, 78.0 ms requested and 78.5 ms hybrid, with no reported native-frame failures. Timing includes the actual backend's trace readback and batching overhead. A fixed threshold cannot remove the lag at higher step sizes, while unconditionally using requested geometry detached the ring from a window whose move was silently ignored. The small, unmatched-per-frame visual differences do not establish a robust improvement, so no production policy was changed. Test callback timestamps and model sample timestamps are both uptime-based but refer to different asynchronous events and do not give a reliable same-frame correlation.

The strategy measurements contain only color-edge measurements, window IDs and geometry/timing logs. These are synthetic test conditions, not proof of Chrome/Ghostty behavior or a physical display latency benchmark. A production improvement still needs an independently validated presentation signal or another strategy that handles delayed and ignored movement across gesture speeds without ring detachment.

## Presentation signals and transaction probe

The companion [source review](PRESENTATION-SIGNALS.md) distinguishes display pacing, AX notifications, WindowServer capture timestamps, Metal presented callbacks and private transform transactions. On 24G84, the instrumented production-path fixture recorded `AXMoved` notifications, actual native bounds, and ScreenCaptureKit frame status plus raw and converted Mach display timestamps. In the clock run, 173/173 capture samples had status 0 and a display timestamp. The Mach timebase was 125/3; the sampled converted Mach clock and callback uptime differed by 0.0007–0.0122 ms. Callback time minus display metadata ranged from -5.25 to +11.58 ms, so the metadata is not treated as a calibrated input-to-photon measurement or an unconditional proof that presentation preceded delivery.

For each of the first 49 movements, the first notification for the focused fixture arriving between consecutive controller sample times had a bounds X position four points behind the preceding requested position. Callback timing was approximately 0.06–1.72 ms after that sample. This is one fixture and one matching rule; AX notifications may be delayed or coalesced and this does not prove their meaning in other apps. It does show these notifications cannot be assumed to acknowledge the latest model position in this run. Captured images were filtered to fixture windows and real ring surfaces; no user-app pixels were saved.

`run-transaction.zsh` tests `SLSTransactionSetWindowTransform` through a C ABI wrapper using a controller-owned blue window and a separate red fixture window. The wrapper preserves and restores each original transform, and the helper checks restoration readback; it applies no operation to other window IDs. On the final transaction run, owned transform readback changed from -90 to -50 and returned to -90; the foreign readback remained -250 throughout. Of 29 transformed-phase samples, the owned blue edge was at x=50 in 28 (baseline x=90; one boundary sample was x=90); the foreign red edge remained x=250 in all 29. Both returned to their baseline edges in all 30 restored-phase samples. This is an ordinary-client, specific API/build result, not proof of behavior from Dock, all private calls, input routing or physical atomicity. The transaction commit/setter returns are not treated as status.

The Dock move run used the already-loaded addition without restarting or injecting Dock. Its first `Window_Move` response was `Operation_Failed`, and the controller stopped. However, immediate bounds readback already showed the focused fixture at the requested x=92 rather than its x=96 baseline. The existing payload ORs results of movement and Space reassociation before returning a status, so the failure does not identify which stage failed and must not be interpreted as proof that no movement occurred. The experiment does not justify retrying blindly, using that operation for production scrolling, or suppressing its error. Fixtures and temporary rules were cleaned up.

```sh
zsh tools/harness/swipe-visual/run-transaction.zsh
zsh tools/harness/swipe-visual/run-production.zsh observed dock normal 4
```

## Responsiveness and background-worker investigation

`zsh tools/harness/swipe-visual/run-keyboard-timing.zsh` uses the same fixture and PID-scoped controller without screen capture. It alternates focus commands while the fixture intentionally blocks its main thread, and fails if any of 80 sample intervals exceeds 50 ms. Build and sign `/tmp/shoji-swipe-controller` and `/tmp/shoji-swipe-visual` as above before running it. On 2026-10-28 two runs on macOS 15.6 had seven intervals over 50 ms each, with a maximum interval of 108 ms in the first run and an 86 ms individual frame operation in the second. This exposes a repeatable motion deadline failure through the keyboard path, but is not proof of the user's longer freeze or an input-to-display measurement.

The fixture-only `keyboard-async` mode (`zsh tools/harness/swipe-visual/run-keyboard-timing.zsh keyboard-async`) coalesces position writes on a worker thread and verifies the two final native positions after joining it. Three runs had 1, 3, and 1 intervals above 50 ms; all failed the timing check. One recorded focus command itself took 89 ms, producing a 114 ms interval, even though frame writes were off-thread. The fixture backend only handles fixed-size position writes and uses fixed, retained fixture references. It has no production lifecycle, generation checks, window-removal handling, recovery, or bounded shutdown; it is not wired into Shoji. Moving frame writes alone therefore does not resolve the focus path or demonstrate correct screen presentation.

The fixture-only `keyboard-async-rapid` mode also queues AX focus actions and alternates target every three ticks. The fixture app is activated once before testing; this does not test switching between different applications. Sampling showed that the diagnostic observer's own synchronous `_AXUIElementGetWindow` and bounds reads could delay the controller run loop, so keyboard timing modes now skip those extra observer reads. With this corrected observer, the synchronous baseline missed seven 50 ms intervals; three combined-worker rapid runs missed none and reached the last requested focus and positions. Immediate bounds checks sometimes lagged successful writes, so final-position verification now waits up to one second. `SHOJI_KILL_FIXTURE=1` terminated the fixture mid-run and the controller detected a worker error. These tests do not establish visual smoothness, instantaneous application, cancellation of in-flight writes, safe recovery, app switching, or bounded worker shutdown; the code remains an experiment and is not used by the daemon.

The fixture worker now uses the reusable `Motion_Coordinator` state machine. It coalesces position and focus requests, rejects stale completions after window replacement or Space invalidation, and selects the oldest pending position to reduce starvation. Two rapid fixture runs passed the timing and final-state checks after integration; a separate run had one 56 ms interval. Killing the fixture produced a detected failure. The coordinator cannot cancel a native AX operation once issued, and these results still do not validate cross-application focus, a production worker, or recovery.

The coordinator also supports cooperative stop: pending jobs are discarded, new requests and in-flight results are rejected, and idle is reached only after the in-flight call returns. The `keyboard-stop` fixture exercises this path. It cannot bound the duration of a blocked native call. A separate `run-production.zsh observed keyboard-async-rapid slow 4 batch` experiment captured the fixture surfaces only; it recorded 183 frames. Among 105 frames with a detected blue edge, the distance to the nearest detected red or green leading edge exceeded 20 pixels in 29 frames and 50 pixels in four frames. Window clipping and missing edge detections can affect this simple measurement; it is not proof of the exact discrepancy, but the run does not validate visual synchronization. Evidence: `/tmp/shoji-swipe-production.ucGZv4RL/`.

On 2026-10-28 the production motion-path controller used a fixture that blocks its AppKit thread for 80 ms every 200 ms. In two batched and two unbatched trials, 9–12 of the first 49 motion-tick intervals exceeded 50 ms; the longest interval was 112–124 ms. Each trial recorded 8–10 native-frame calls over 50 ms. The difference between update suppression modes was not clearly distinguishable in these short trials. A separate experiment bypassing the enhanced-accessibility query while retaining the AX position writes still produced 108–120 ms maximum intervals. This is a controlled slow-application reproduction, not proof of the cause of the user's reported whole-machine freeze.

Setting 25 ms AX timeouts on both the fixture application and windows caused `AXPosition` error -25204 and aborted both test gestures; lowering the timeout alone is not a safe fix.

The Swift helper's `async` mode is a separate, non-production proof of concept: one serial worker retains a single latest pair of pending positions and performs the two AX writes away from a synthetic main timing loop. In three slow-fixture trials, the 80 timing samples had maximum intervals of 17.94–17.96 ms while worker operations took up to about 80–83 ms. The worker applied 61–62 coalesced requests, returned both windows to x=250 and x=550, and reported no AX failures. When the fixture exited mid-run, a first version submitted 67 failed requests; the revised version latched the first failure, cleared pending work, exited the worker and reported failed readbacks. The expected failure is retained as `async-exit`.

This prototype tests background position writes and coalescing, **not** Shoji's actual engine, live gesture, focus ring, resize or capture path. It does not implement production-safe generation checks, cancellation, rapid focus/Space changes, app relaunch, bounded shutdown, synchronization with WindowServer presentation, or recovery from a temporarily slow but still alive app. It is not sufficient to claim the real freeze or visual gap is fixed and is not wired into the daemon. `jq -f tools/harness/swipe-visual/verify-async.jq <result.json>` checks the synthetic normal-run timing and final positions; the intentional app-exit run must fail that check. The user's exact reported freeze still requires a red-capable real-path reproduction and a validated fix.

After building the Swift helper as above, run `zsh tools/harness/swipe-visual/run-async.zsh slow` or `zsh tools/harness/swipe-visual/run-async.zsh slow-exit`. Both operate only on the temporary fixture, with a temporary exclusion rule.
