# C1: two-window layout and per-frame pixel experiment

This is the next experiment after
server-context placement. It targets
only the disposable `Shoji Test` guest, build 26A434. It does not integrate
the experimental payload into the production Shoji daemon.

**Fixture acceptance passed:** three matched repetitions, 18 gated layout
changes, zero mixed frames in 852 change-interval frames, maximum complete
callback 0.472 ms. See RESULTS.md for evidence and limitations.

## Question and acceptance

Can one staged layout move two already visible windows together between
consecutive captured display frames, while the server callback takes less
than 8 ms? Compare with an intentionally staggered positive control that
moves red first and green 40 ms later. That control tests the detector; it
is not a latency benchmark of the production AX backend.

The fixture owns a red and a green 160 × 120 borderless window. Layout A is
red (100, 200), green (400, 200); layout B is red (100, 450), green (400, 450).
A separate 20 × 20 ordering marker triggers the server seam. Each run makes
six alternating A↔B changes and reads both fixture positions independently.
A separate fixture executable draws a small black/white patch at 60 Hz in
each window to keep capture active. The driver establishes and verifies the
initial layout after AppKit's first surface commit, before starting capture.

One ScreenCaptureKit **display** stream includes exactly the two selected
windows, verified against their fixture PID. Both positions are therefore
measured in the same pixel buffer, not reconstructed from independent
per-window streams. An 800 × 600 crop covers both layouts. The probe scans
BGRA pixels, counts red/green samples, saves their vertical centroids, frame
status, display tick and callback tick, and retains a PNG per observed state:

- `AA` / `BB`: both windows in the same complete layout.
- `AB` / `BA`: an intermediate mixed layout.
- A `?` band or too few color pixels makes the evidence inconclusive.

Acceptance requires all six visual transitions and successful independent
readback. Every positive-control change must expose a mixed frame. Every run
needs at least 24 change-interval frames and no gap over 50 ms. The gated run
must have no captured mixed frame and six matching automatic callback events,
all under 8 ms. Capture can omit frames; this is not physical scanout proof,
an assurance for arbitrary applications, or a claim about resizing windows.

## Staged protocol and server path

The existing Mach message format now supports:

```sh
swift gate-ctl.swift layout-begin
swift gate-ctl.swift layout-add RED_ID 100 450
swift gate-ctl.swift layout-add GREEN_ID 400 450
swift gate-ctl.swift layout-arm MARKER_ID 8000
# fixture orders its marker in
swift gate-ctl.swift layout-status
```

Commands 8–11 are LayoutBegin, LayoutAdd, LayoutArm and LayoutStatus.
The plan has eight fixed slots, rejects duplicate IDs, invalid coordinates,
an empty plan, a marker also present in the layout, or a budget over 8000 µs.
The same PID+pidversion ownership and hold-generation rules apply.

The ordering callback claims the marker once. It allocates no memory and
performs no external IPC or intentional sleep. It resolves every target and
validates every initial bounds rectangle before the first movement. It then
applies every position with the previously verified exact-build server
helpers, verifies final bounds, and forwards the original ordering call.
Observer `held=3` denotes this automatic layout callback, distinct from the
single-placement externally released hold (`held=1`) and timeout (`held=2`).

LayoutStatus returns generation, applied count and helper-path elapsed µs.
Status 8 means canceled/unavailable, 10 means final bounds verification
failed, and 11 means the measured timing budget was exceeded. The budget is
measured, **not hard preemption**: a slow helper is not interrupted halfway
through a prevalidated layout. There is no claimed rollback guarantee if a
native movement itself fails after previous movements succeeded.

## Build, run and analyze

```sh
task build:windowserver-ordering-observer build:gate-client build:layout-frame build:layout-fixture
swift tools/window-interception/lifecycle/test_report.swift
swift tools/window-interception/gate-handoff/tests/test_analyze_placement.swift
swift tools/window-interception/fixtures/layout-frame/test_analyze.swift
```

The capturer is packaged as `bin/Shoji Layout Capture.app` with
identifier `tech.shoji.layout-frame`. The VM copy is
`/Users/Shared/shoji-ws-observer.Qwiazd/Shoji Layout Capture.app`.
The guest must have an active `shoji-test` desktop and macOS Screen Recording
permission for this app. Grant that permission through normal guest System
Settings; do not alter TCC databases or weaken host privacy settings.

Stage the app, controller, payload and `run.swift` in the existing guest harness.
The run script is named `run.swift` there. Run as `shoji-test`:

```sh
swift /Users/Shared/shoji-ws-observer.Qwiazd/run.swift cascade
swift /Users/Shared/shoji-ws-observer.Qwiazd/run.swift gated
```

It saves unique `/tmp/shoji-layout-frame.*` directories. It launches the
capturer through a temporary job in the **guest GUI session**, then removes
that job on completion or error. This gives TCC a GUI application identity;
launching the capturer directly through SSH instead attributes responsibility
to `com.apple.sshd-keygen-wrapper`. The temporary job does not grant any
permission. OS refusal still fails the capture.

Copy a completed run back to local ignored artifacts, then:

```sh
swift tools/window-interception/fixtures/layout-frame/analyze.swift RUN_DIRECTORY
```

Keep raw PNGs, `frames.jsonl`, fixture events, controller responses and the
observer response together. The analyzer refuses absent transitions, missing
colors/timestamps, mixed gated frames, and callbacks exceeding the budget.
Rebuilding/re-signing the app may require macOS to re-evaluate its permission.

`fixture.swift` builds the separate `shoji-layout-fixture` executable. Update
it independently when changing the content pulse or fixture scheduling; keep
the authorized capture app unchanged while collecting a comparable run set.

## Validated result — 2026-11-04

- 370 deterministic tests pass outside the host execution sandbox, including
  the bounded/sealed plan test. The sandbox blocks two existing local IPC tests.
- Eight pixel-evidence analyzer tests pass, including refusal of sparse
  capture, mixed frames, missing transitions/colors and slow callbacks.
- Payload and controller compiled and were installed in guest WindowServer
  50224, owner 50289. Protocol-only live checks rejected duplicates, marker
  collisions and an excessive budget, then verified pending→canceled state.
- After the user authorized capture, three final run pairs passed every
  acceptance check: 18 gated changes, no mixed frames, callbacks under
  0.473 ms; 54 mixed frames in controls, exposing all 18 staggered changes.
- WindowServer retained PID 50224 with no new crash report. Temporary fixture
  processes and capture jobs were cleaned up. Raw failed permission and
  sparse-capture attempts remain archived and excluded from accepted runs.
- C1's bounded fixture experiment is complete. Production integration and
  broader behavior remain unvalidated; see RESULTS.md.
