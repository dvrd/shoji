# Scrolling feature validation

Validated 2026-10-25 local time (2026-10-26 UTC), macOS 15.6 / 24G84, Apple silicon.

## Deterministic checks

The complete test package passed **197 tests** with `-warnings-as-errors`. Source and owned-fixture checks passed with unused-import/variable checking. The feature cases cover:

- Pinned-reference three/four-column sizing, insertion and camera anchoring.
- Close return, intervening focus, removal/resize to the left, viewport shrink and oversized fixed requests.
- Width/height preset cycling, strict one-pixel tolerance, preset reset, proportional widths across output changes and full-width restoration.
- Legacy/directional consume and expel, selected focus, failed native focus before mutation, column movement and proportional requests across warp.
- Fixed and weighted rows, sequential rounding, replacing a fixed row, known conflicting width limits and minimum-height allocation.
- Never/Always/OnOverflow centering and per-Space settings.
- Tabbed geometry and active ordering without repeated ordering on unchanged flushes.
- Modifier gesture ownership, cancellation, momentum after modifier release, native CG-event routing and coalescing, immediate frames and interruption of stale animation with failed-restoration retention.

Expected Niri values are source-derived, not differential results from executing Niri. See [pinned reference](NIRI_PORT_REFERENCE.md).

## Native smoke test

`tools/shoji-harness/fixtures/desktop/scroll_layout.odin` creates four accessory windows owned by its process. Its backend rejects operations on other IDs. It drives the real engine and applies frames through its own NSWindows; WindowServer bounds are queried independently through `SLSGetWindowBounds`. Every window closes on exit.

Passed **42 bounds observations**: successive opening of four columns, proportional width change, complete-column movement, directional consumption, tabbed and normal display, fixed row height, directional expulsion and width cycling. Readback tolerance is one point for native frame rounding. [Raw final observations](evidence/scroll-24G84/owned-scroll.jsonl).

The first smoke run queried before AppKit committed some updates. Replacing a fixed number of early-returning run-loop calls with a bounded one-second settling loop made the same bounds assertions pass. The final run did not require the full bound. No geometry tolerance was widened.

This validates owned AppKit windows. It does **not** validate foreign-app AX size acceptance, third-party minimum sizes, tab input/occlusion parity, visual animation smoothness, real-device modifier gestures, multi-display behavior, hotplug or compositor clipping. The ordinary daemon was not stopped for this fixture, and no existing windows or Spaces were rearranged.

## Installation

`task build:scroll-preview` completed with warnings as errors. Signature verification succeeded using identifier `tech.shoji.window-manager` and the existing certificate fingerprint `6D7E315604019D4D0424770736986C54C9CA44CF`.

The signed binary was atomically installed at `bin/shoji`, and only `gui/501/tech.shoji.window-manager` was restarted. After startup configuration completed, IPC reported BSP, the new width/height presets, `never` centering, half-width defaults and gestures off. Runtime animation duration was preserved at 0.5 seconds. Dock was not restarted and its payload was unchanged.

Pre-feature executable SHA-256: `d86f3e5175b8ee10b193a62a6ff87b565132f705d665c3ecf46ed9b07c9ccf99`.

Installed feature executable SHA-256: `1d5dcaf0161cc34fea6cfdabbda4bdc312420dc8315b472d3194239e4a5030b5`.

Rollback copy: `bin/scroll-live-20261026/shoji-before-features`. Commands and remaining capability limits are in [scrolling layout](SCROLL_LAYOUT.md).

## BSP Space-swipe update

The modified-horizontal input path now dispatches by the layout where a sequence starts. A BSP swipe accumulates 80 points before requesting the adjacent Space on the same display, then suppresses further requests for that physical sequence and its momentum. Native synthetic CG scroll events exercise the complete callback-to-engine dispatch with a recording backend. Additional tests cover direction, preserved mode when crossing to a scroll Space, ordinary/vertical/cancelled/disabled input, no wrapping, other displays, stale origins and backend failure. All 206 tests pass with warnings as errors. Actual hardware swipe recognition remains user acceptance; the user has already confirmed Fn plus two-finger input reaches Shoji.

The signed update is installed, LaunchAgent PID 8765 responded with BSP, gestures on, modifier Fn and preserved animation duration 0.5. Dock was not restarted. Installed SHA-256: `56324ca3fe068a3b95c5e0602e43d5e53ed79f0b6531f08c1f31f4d5e869bf9a`. Rollback executable: `bin/space-gesture-20261026/shoji-before`. The shojirc now persists the previously runtime-enabled gesture setting; its backup is `~/.config/shoji/shojirc.before-space-gesture-20261026`.

### Cyclic Space navigation

The subsequent user-requested update wraps from the last Space to the first and from the first to the last, within the originating display. A sole Space is a no-op. One-switch-per-swipe and momentum ownership are unchanged. Both wrap directions, other-display exclusion, stale origins and the single-Space case are covered; all 207 tests passed with warnings as errors. The signed build and signature check passed, and the service restarted with BSP and gestures enabled (PID 11720). Installed SHA-256: `9a6f78f5f64acf78b3065ea656b2d31e95e87f73c14a41e8117205921243222e`. Pre-wrap executable: `bin/space-gesture-20261026/shoji-before-wrap`.

## Shared camera and release settling

The next polish update replaces independent scroll-window animations with one rendered camera position. A critical spring (unit mass, stiffness 800, epsilon 0.0001) drives translation, retargeting retains position and velocity, and gesture contact takes over at the rendered position. Native presentation batches each update and defers desktop rediscovery during motion. Scroll pointer warping defaults off while BSP keeps its previous mouse behavior.

Release uses a 150ms history of native CG event timestamps, viewport-normalized physical motion, the pinned reference's projected stopping distance, column edge/center snapping and directional visible-column focus. The claimed native momentum tail is swallowed without applying a second displacement. Five pinned release examples, shared spacing, settle completion, retargeting, takeover, left-side geometry rebasing, failed release focus, idle velocity, pointer policy, native callback-to-spring routing and rediscovery gating have deterministic coverage. All **221 tests** pass with warnings as errors, and source/fixture vet checks pass. This does not establish complete Niri parity for every window constraint, centering edge case or renderer behavior.

The expanded owned-window experiment passed **70 WindowServer bounds checks**, including 28 additional observations at a baseline and six sampled spring times. Visible columns retained their 632-point pitch. [Raw observations](evidence/scroll-24G84/owned-motion.jsonl). The fixture samples deterministic animation times and waits for AppKit acknowledgment; it is not a real-time frame-rate measurement or foreign-app AX test. An initial fixture run stopped because its model opacity was unset while native windows started opaque; correcting the fixture's initial opacity allowed the same engine focus operation to run. No bounds assertions or tolerances were relaxed.

The signed update was installed and only Shoji restarted (PID 22091). IPC reported shared scroll animation on, pointer warp off, gestures on, and the original BSP layout. The previous animation duration was retained and the recovery journal was empty. Dock and the payload were unchanged. Installed SHA-256: `1e81e5d743934f17c7dd17ca5fbbf58bf3bb4044e3d1303447868ee7c6188f32`. Rollback executable: `bin/scroll-motion-20261026/shoji-before`.
