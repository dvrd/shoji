# macOS 15.6 validation

Target: macOS **15.6**, build **24G84**, **arm64**. This is the daily-use validation
milestone; it does not certify compatibility with every upstream macOS release.

## Repeatable evidence

Run from the repository:

```sh
task validate
./bin/shoji-harness validate --preflight-only
./bin/shoji-harness validate --live-animation
./bin/shoji-harness live desktop
./bin/shoji-harness live spaces --load-payload
```

The first command runs compiler/vet checks, native and Rosetta tests, tooling
tests, universal builds, the arm64e loader self-test and bootstrap relocation
inspection. It then checks Accessibility/window inspection and the payload
handshake. Logs, binary SHA-256 hashes, target/build identity, Git HEAD and working
tree status are saved in a fresh temporary directory printed by the command.
Desktop inspection logs include window titles; review before sharing them.

The live-animation option additionally runs the existing disposable-window crash
recovery harness when desktop prerequisites pass. It does not start a daemon,
install a service, or restart Dock. An explicit `--dock-restart` option additionally
restarts Dock and reloads the payload during the fixture test; run that only when
ready for the desktop interruption and with working sudo access.

A failed prerequisite is recorded as blocked, never as a successful live test.
Passing selected checks does not mark the entire milestone complete.

## Current implementation fixes

- Native edge drags now enter the tiling resize path: BSP split changes reflow
  neighboring tiles, scrolling column changes reposition adjacent columns, and
  pointer-driven frame writes bypass animation. A live reproduction showed both
  private mouse-event window-ID fields returning zero, which had caused the
  first implementation to forward the drag to the app. Session-tap clicks now
  fall back to WindowServer hit-testing, skipping Shoji's own proxy surfaces.
  The zero-ID case has regression coverage alongside nested splits, axis locks,
  single-tile stability, scrolling neighbors and floating/interior passthrough.
  The user confirmed live coordinated resizing after the hit-test fix, and the
  trace identified a captured border drag with both neighboring frames changing.
  The user also reported remaining lag. Full desktop rediscovery is now deferred
  during captured drags, preserving pending notifications until release; failed
  drags still allow reconciliation. All 163 deterministic tests pass. The signed
  follow-up is installed with verbose mouse tracing disabled; the responsiveness
  improvement still needs a live user check.
  A sole tile now follows the resize while dragging, then fills its usable
  Space again on mouse release, including in scrolling layout. The temporary
  frame survives reconciliation during the drag; multi-window releases retain
  their adjusted split ratios. Backend failure preserves the prior drag frame.
  Mouse-down/drag/up regression coverage verifies the release behavior with
  animation enabled globally: pointer tracking remains immediate, and the fill
  after release uses the configured animation duration and easing.
  The user observed stretched content with the proxy-based fill. The release
  transition now interpolates real Accessibility window frames, letting the app
  redraw at its native scale without creating, hiding behind, or scaling a
  screenshot proxy. Discovery waits until the short animation completes, and a
  new edge drag interrupts it at the last applied frame. Tests cover real-frame
  interpolation, completion, retargeting, interruption and frame-write failure.
  All 168 tests pass. The active fill duration remains 0.18 seconds with
  `ease_out_circ`. The signed update is installed; its visual quality still needs
  live user confirmation.

  The user subsequently reported that real-window fill looked much better and
  requested a slightly slower duration; the running and saved configuration were
  changed to 0.24 seconds. A later recording showed flicker/gaps while resizing
  neighboring windows. Interactive steps and live animation frames now bracket
  their window writes in a nested WindowServer presentation batch, and raw frame
  writes join that batch. Presentation is re-enabled even when a frame write
  fails. A current native bounds query also permits a pure resize or move to use
  one AX attribute write instead of unconditional size/position/size writes;
  combined moves/resizes retain the screen-clamping workaround inside the batch.
  All 171 tests pass, including nesting, failure cleanup and minimal-write cases.
  The signed build is installed; live flicker verification remains pending.

  The user reported continued redraw flicker during rapid back-and-forth drags
  and stretched content on window-close reflow. The event path is now changed:
  ordinary native edge drags are passed through to AppKit, while Shoji observes
  the accepted WindowServer geometry and resizes the neighbors. It does not
  issue competing frame writes to the dragged window; pending model discovery
  still waits for release. Modifier-driven mouse operations retain Shoji's
  existing control path. Default animated size changes, including close reflow,
  now select real-frame interpolation; same-size translations may use proxies.
  Regression coverage includes native event passthrough, accepted geometry
  lagging behind pointer motion, direction reversal without another input event,
  no frame writes to the dragged window, and default close-size classification.
  All 180 current tests pass. The user confirmed the installed native-drag and
  unscaled close-reflow changes look good on 2026-10-25 after being asked to
  repeat rapid back-and-forth resizing and window closing. This closes the
  reported visual regression on the current host; it does not establish
  Niri-style client-buffer transaction synchronization or macOS 27 support.

- Bootstrap Mach-O sections explicitly use regular,pure_instructions so the
  linker recognizes their code and unwind metadata. The relocation checker
  now also verifies the section instruction flag.

- Patched Odin's assembly checker to model returning ARM64 BL/BLR and
  authenticated calls as fallthrough, and mark the link address as consumed by
  the callee. The compiler regression suite checks conditional, sequential,
  authenticated and direct calls, outputs after calls, and preserved diagnostics
  for genuine dead writes and tail branches. Both compiler build paths apply
  the checked-in patch; the shared Odin checkout is left unchanged.

- Local executable builds use a persistent Keychain identity and fixed signing
  identifier. The designated requirement pins the certificate instead of a binary
  cdhash. Builds verify a candidate before atomically replacing the installed
  executable, and refuse an implicit ad-hoc fallback. CI explicitly opts into
  ad-hoc signing. The one-time transition and Keychain setup are in SETUP.md;
  retained Accessibility permission across two real signed builds still requires
  live confirmation after that initial grant. All 24 tooling tests and a real
  build/sign/atomic-install smoke check passed (the isolated smoke binary used
  explicit CI ad-hoc mode). Certificate setup from the agent context was rejected
  by Keychain (CSSM_ModuleLoad / invalid parameters); no identity was created.
  Run signing:setup from the user's terminal before the first persistent build.

- Corrected native layer keys: below uses BackstopMenu (3 / -20), normal uses
  Normal (4 / 0), above uses Floating (5 / 3). The former minimum-level key
  (1) placed tiled documents at observed sublevel 5 on the target, above
  About This Mac at 3. A bounded native WindowServer query confirmed Ghostty
  and Chrome at 5; resetting them to normal produced 0, and the user confirmed
  About This Mac stayed visible. New clients fall back to normal document levels
  with older loaded payloads, avoiding a Dock restart. The rebuilt payload
  advertises Window_Layer_Keys and normalizes legacy keys. Native API tests
  verify ordering and exact values; tests cover old-payload fallback and legacy
  client normalization. The ordinary exported sublevel getter returns zero on
  this target, so model layer labels alone do not establish actual native order.

- Accessory AXWindows polling is gated by one on-screen WindowServer owner
  snapshot per refresh, with the frontmost app included even before its window
  appears in that snapshot. Windowless menu helpers are skipped; known off-screen
  panels retain references via native ownership checks. Accessory application AX
  calls have a 25 ms timeout instead of 250 ms. A live pre-fix sample spent
  2121 of 2207 main-thread samples in refresh AX attribute reads; disassembly
  identified AXWindows. Repeated read-only queries took 1.07–1.09 seconds.
  Post-fix live timing remains to be measured after service restart.

- Accessory apps are now observed, with their windows floating by default and
  AXWindow panels above regular document windows. System Information declares
  LSUIElement; the live About This Mac window was absent from the previous
  daemon query because discovery only accepted regular apps. Tests cover accessory
  discovery, validation PID isolation, floating/layer behavior and layer overrides.
  Visual confirmation after restarting the updated daemon remains required.

- Confirmed fixed-size windows float before initial tree insertion. Native resize
  capability is read before classification; failed capability queries remain
  unknown. Explicit management rules retain precedence. Regression tests verify
  unchanged dialog geometry, exclusion from frame writes, normal automatic layer,
  unknown capabilities and explicit management. About This Mac live confirmation
  is still required.

- The active profile's 32 configuration/rule commands passed engine validation.
  Hammerspoon shortcuts and service controls now use Shoji; the user confirmed
  the service and shortcuts work on 2026-10-25. See SETUP.md for setup instructions.
- Chained window commands support the existing float/grid shortcut.
- Display/Space enumeration failures preserve the last complete model and labels;
  successful enumeration orders the Space array by current native indices.
- Automatic-payload startup waits for its verified handshake before launching
  configuration, and does not rerun the config on later Dock reloads.

- Same-display two-operation moves/swaps compensate a failed second operation
  through real backend moves. Tests exercise all source/target positions and
  failures at both operation boundaries.
- Cross-display swaps exchange entire tiling views, insertion state, zoom
  references, labels and override settings while retaining destination geometry
  and native Space identity. Window-move failure compensation is retained.
- Accessibility frame writes temporarily disable enhanced UI when enabled and
  restore it after success or failure. Restoration failures reach the caller.
- Task commands can use isolated libraries from the pinned Odin revision, avoiding
  mismatches caused by a shared compiler checkout advancing independently.

## Acceptance checklist

| Area | Required evidence | Status |
| --- | --- | --- |
| Build and tests | Compiler/vet, native and Rosetta tests, universal binaries, loader and bootstrap checks | Automated runner available; see latest report |
| Desktop access | Current rebuilt binary can inspect windows in the GUI login session | Passed from desktop terminal on 2026-10-25; blocked in agent execution context |
| Payload | Matching protocol, required private operations, disposable-window operation checks | Desktop handshake and tracked Space create/focus/destroy passed on 2026-10-25 |
| Basic management | Owned test windows: focus, frame, minimize/restore, close, BSP/stack/float, selectors | Owned-window desktop test passed on 2026-10-25; remaining selector edge cases tracked in PORTING.md |
| Rules and queries | Application/dialog matching, one-shot retries, projections/schema against pinned upstream | Deterministic coverage exists; remaining parity review and live checks pending |
| Mouse | Modifier move/resize, click replay, focus-following, cross-Space drops, previews | Synthetic coverage exists; live input pending |
| Native tabs | Switch tabs repeatedly, destroy inactive tabs, retain full-stack membership correctly | Deterministic coverage exists; live applications pending |
| Displays | Focus empty/populated displays, negative coordinates, disconnect/reconnect, display ordering | Deterministic coverage exists; live second display pending |
| Spaces/fullscreen | Reorder/swap failure recovery, fullscreen enter/exit, Mission Control and swipe settling | Tracked create/focus/return/destroy passed; reorder regression coverage exists; fullscreen, Mission Control and swipe checks pending |
| Events | Workspace notifications, rapid transitions, wake, Dock preferences/restart | Deterministic coverage exists; live notification delivery and coalescing differences pending |
| Animation | Capture/proxy motion, alpha correction, batching, orphan watchdog, journal replay and Dock restart | Recovery harness exists; live rendering and remaining upstream behavior pending |
| Service | Install/start/status/restart/stop/uninstall, startup config, unattended payload reload | Service install/start and Hammerspoon bindings confirmed by user; unattended reload and login checks pending |
| Responsiveness | AX/payload stalls do not freeze command/event processing beyond defined bounds | IPC deadlines tested; synchronous backend latency remains |
| Distribution | Remote CI, installed archive smoke test, documented supported target | Local archive/tooling checks available; remote CI and installation pending |
| Remaining port differences | Missing configuration, child-window layers, application retry/suppression, selector/query/rule differences in PORTING.md | Open |

## Desktop session blocker

On 2026-10-25 the agent process could reach a loaded payload outside the sandbox,
but `AXIsProcessTrusted` remained false and the disposable AppKit fixture received
no WindowServer connection. A GUI launchd-domain probe also failed. These are
execution-context limitations; they do not establish a defect in tiling or prove
that a user-granted Accessibility setting is wrong. Run the commands above from
the user's desktop terminal to distinguish the two contexts.

The desktop-terminal preflight passed on the exact target on 2026-10-25. Evidence:
`/var/folders/dr/rhcpqcds1wqd3824tvjn0f940000gn/T/shoji-validation-uise0wd8/report.json`.
Both inspection and payload handshake returned exit status 0. This establishes
desktop access, not animation or window-management correctness.

The Shoji-specific sudoers file `/etc/sudoers.d/shoji-load-sa` exists. Reading it
from the agent context was denied; `sudo -n -l` outside the sandbox failed with
`you do not exist in the passwd database`. The user's desktop-terminal `sudo -n -l`
output confirms a root NOPASSWD rule for the exact command:
`/Users/kakurega/dev/projects/shoji/bin/shoji --load-sa /Users/kakurega/dev/projects/shoji/bin/shoji-sa.dylib`.
No sudoers edits are needed. Live unattended reload behavior is still pending.

The first desktop animation run created its fixture but failed when parsing the
alpha observation. A desktop-independent reproduction showed Odin's formatter
interpreting the literal JSON opening brace as a formatting directive. The helper
now uses JSON serialization; a regression test compiles and runs its actual output
path without a WindowServer connection. Malformed observations retain their raw
stdout/stderr in the evidence directory and fail with a diagnostic. Animation
recovery itself remains unverified until the desktop test passes.

The next desktop run passed the initial alpha query, then failed at the proxy
operation with `Operation_Failed` (evidence `/tmp/shoji-live-crash-eyu9pbby`). The
payload now reports the first failing transaction stage and native error code,
advertised by the `Transaction_Diagnostics` handshake capability. This adds
diagnostics; it does not establish the cause or fix the native operation failure.
The rebuilt payload must be loaded into a fresh Dock to use these diagnostics:
`./bin/shoji-harness live animation --reload-payload`. This explicitly restarts Dock
before test windows are created and checks the exact noninteractive sudo command
before the restart. It does not exercise the mid-test Dock-restart case unless
`--dock-restart` is also specified.

The old reload harness sent SIGTERM and relied on Dock relaunching itself. That
failed on the target machine; the user restored Dock with `launchctl kickstart`
using the correct `com.apple.Dock.agent` label. The harness now verifies access to
that launchd job before any restart, requests restart through `kickstart -k`, and
requests a recovery `kickstart` if restart observation fails. Regression tests
cover refusal before interruption and recovery without payload injection on a
timeout. The corrected restart path has not been run live and is not required by
the ordinary desktop/Space tests.

The owned-window desktop test passed on 2026-10-25, including WindowServer frame
checks, BSP/stack/float, focus, swaps, transforms, chained float/grid, resizing,
minimize/restore, close visibility, and removal after fixture-process exit.
Evidence: `/var/folders/dr/rhcpqcds1wqd3824tvjn0f940000gn/T/shoji-desktop-izz6n5b8`.
This test does not certify real mouse input, multi-display hotplug, native tabs,
or animation rendering.

The tracked Space test passed on 2026-10-25. Evidence:
`/var/folders/dr/rhcpqcds1wqd3824tvjn0f940000gn/T/shoji-spaces-1lm7csqv`.
It created Space 905, focused it, returned to original Space 44, and destroyed
905. Original IDs `[4, 90, 44]`, their order and the focused Space were identical
before and after. Dock was not restarted. This establishes basic payload Space
operations; fullscreen, swipe transitions and cross-display moves remain unverified.

Compiler warning validation on 2026-10-25: rebuilt the isolated standard compiler
and arm64e companion compiler with the assembly-call patch. All eight diagnostic
cases passed against each compiler; real dead-write and tail-branch errors were
retained. Shoji source checks and isolated native/Intel builds emitted no compiler
or linker warnings. All 147 native and 147 Intel/Rosetta tests passed; the arm64e
loader self-test and both bootstrap relocation/section checks passed. The isolated
native smoke build used explicit CI ad-hoc mode and did not replace bin/shoji.

### 2026-10-25 — macOS module simplification

Implemented direct internal frame writes (no command-dispatch reentry), distinct
live-resize/proxy presentation variants, shared owned WindowServer surfaces,
explicit drag phases and shared release/reset cleanup, window collection/model
reconciliation/effect stages, and minimal owned signal snapshots with pure event
diffing separated from signal launching. Removed the unused blocking command
server and capability helper; the two socket response tests use the incremental
production server. Initial-rule appearance reads still happen after rule effects;
unknown capabilities, spaces, and native-tab retention remain conservative.

Validation: 203 Odin tests passed with memory tracking, warnings-as-errors and
unused-code vetting; optimized executable and live-animation fixture builds passed.
The separately signed `bin/shoji-macos-refactor --inspect` successfully enumerated
1 display, 3 spaces and 1 window in the desktop session. `git diff --check` passed
for touched tracked files. The running daemon was not replaced or restarted, and
interactive resize/animation behavior has not been revalidated on this candidate.
This pass reduces duplicated paths and state ambiguity; explicit stages/types and
formatting increase macOS source lines from 3,841 to 4,374. It does not establish
macOS 27 runtime compatibility.

### 2026-10-25 — opening-window flicker investigation (unresolved)

A shrinking-tile candidate uses a clipped native-scale capture and one real AX
resize, with live-frame fallback if capture is unavailable. Its regression tests
and the full 217-test suite passed. An owned red/green proxy capture confirmed
native-scale clipping, and a disposable-window control confirmed one AX write
per requested target, rapid retargeting, final geometry, and an empty journal.
The user still observed flicker in Ghostty after installation: these checks do
not establish visual success. Ordinary alpha getters do not measure Dock's
system alpha and must not be used as proof of real-window hiding/restoration.
Frame-start/frame-write tracing is currently enabled in the installed build;
animation duration 0.5 and existing BSP Space layouts were preserved. A new
Ghostty opening trace and distinction between continuous repainting and a final
content jump are pending. Do not mark this issue resolved.

The subsequent Ghostty trace captured one opening resize for window 58:
`(4,42,1720,1071) -> (4,42,858,1071)` with `live=false` and exactly one
`frame-write`. Closing then followed the existing live expansion path back to
1720 points. This rules out repeated Shoji AX writes during that opening on the
candidate, but does not explain/resolve the remaining reported visual flicker.
The red/green proxy rendering capture is `/tmp/shoji-owned-proxy-clip.png`;
it verifies actual cropping at native scale, rather than only region readback.

### 2026-10-26 — stage new tiled windows behind existing tiles

The user clarified that the new window initially covers the existing window,
rather than a content-resize defect. Removed the unaccepted clipped-shrink
workaround, its three tests/tool mode, and temporary frame tracing. Size changes
again use the previously validated live-frame animation path.

New managed tiles with existing peers are lowered before layout flush; their
managed layer is applied first so ordering can place them below existing tiles.
They remain pending until all animations/scroll camera motion in their Space
complete, then rise only if still focused. Floating windows, explicit layer
rules, read-only inspection, changed focus, closed windows, and Mission Control
are covered by the ordering tests.

The native check exposed the need to commit ordering explicitly. Window_Order
now uses SLSTransactionOrderWindowGroup plus a synchronous transaction commit.
The arm64e payload was rebuilt, ABI-normalized, signed, installed and loaded
through one Dock restart. Shoji was rebuilt/signed/restarted; runtime duration
0.5, ease_out_circ and all three BSP Space layouts were preserved. Backups and
runtime settings are in /tmp/shoji-opening-order-backup.

230 Odin tests passed with warnings-as-errors, unused-code vetting and memory
tracking. Optimized controller, arm64e payload and native helper builds passed.
`shoji-opening-order-check opening-order` passed against the installed payload:
independent WindowServer hit-tests confirmed front-order positive control,
new-window lowering, waiting through pending reflow, and final raising. Both
fixture-owned surfaces remained alive for the full comparison and were removed
afterward; no existing user window was resized by the check. Actual Ghostty
opening appearance still requires user confirmation; do not claim preemption of
an app's first display before its Accessibility creation event is observed.

### 2026-10-26 — grow new BSP tiles from a staged opening frame

The user reported a new window appearing at its destination before contracting
and filling again. The opening path previously retained the app's remembered
native frame, so an already-matching tile could skip animation entirely.

Animated BSP insertions now lower the new window, stage it at half the target
split dimension with the tile's outer edge anchored, and then use the ordinary
coordinated layout flush to contract the existing tile while the new tile moves
inward and grows. AX accepted geometry is read after staging and re-anchored to
respect app minimum sizes. Nonanimated openings and stacked/scrolling layouts
retain their existing presentation paths.

The new regression covers all four split directions and the remembered-frame
case. All 232 tests and the optimized build passed with warnings-as-errors and
unused-code vetting. A separate signed controller operated only on PID/title-
verified disposable size-fixture windows: it observed a 700-point native minimum,
kept the new tile's outer edge fixed, and measured monotonic growth from 700 to
800 while its peer contracted from 1600 to 800. Existing user-window frames were
unchanged. The one-off controller is under /tmp/shoji-fluid-validation.

The controller build was signed, installed and restarted; runtime duration 0.5,
ease_out_circ and existing BSP Space layouts were preserved. The Dock payload
was unchanged. The supplied recording predates the prior stacking fix; actual
appearance of the combined staging/growth sequence still needs user confirmation.

### 2026-10-26 — stage at the creation notification before first presentation

The 09:13:15 user recording still showed a native opening frame before staging.
The earlier controller began after creation and could not detect that flash.
The AX callback only marked the desktop dirty; staging waited for a full scan,
which is also deferred during live animations.

Creation notifications now handle the individual newborn synchronously inside a
presentation batch, then stage and flush its layout before returning. An owned
AppKit fixture demonstrated that AXWindowCreated can arrive with Space 0,
unordered status and zero native bounds despite a valid AX frame. Mapping and
Space assignment followed shortly afterward. A native readiness wait (capped at
64 ms) now keeps that handoff inside the same batch, without ordering hidden
windows onto the screen. Unready windows fall back to ordinary discovery, and
the batch is released on every exit. Completion checks actual foreground-app
focus before raising, since full discovery may not have observed the new focus.

All 234 tests and the optimized build passed with warnings-as-errors and unused
vetting. The native regression attached before a second disposable window was
created, used the real observer callback, and never ran desktop refresh. Without
the readiness wait it failed (Space 0/unordered at birth); with the final path it
staged the native window at width 432 before starting two animations and measured
monotonic growth to 864. The signed, PID-restricted controller and owned fixture
are under /tmp/shoji-birth-probe. This verifies event timing and native geometry;
it does not substitute for visual confirmation of Mail's exact opening sequence.

### 2026-10-26 — earlier AXCreated event and discovery-before-creation race

The 13:24:08 user recording still contains one native opening frame on top of the
existing window, followed by coordinated contraction/growth. Temporary metadata
tracing exposed an omitted event path: AXCreated can precede AXWindowCreated by
tens of milliseconds. The former only marked discovery dirty. Discovery could
register the newborn before the latter, whose handler then rejected any ID
already in the model. A known-but-unmapped newborn consequently missed staging.

Both events now enter the creation path. Generic AXCreated controls are filtered
by AXRole before starting a presentation batch. Existing model entries are
skipped only when already in a tiling tree; previously discovered unmapped
windows are reconciled and gain membership before staging. The later duplicate
notification therefore cannot restart the opening animation.

The native regression under /tmp/shoji-birth-probe now subscribes to both events
and deliberately registers the fixture at Space 0 / ordered false before
dispatching its creation event. The previous implementation failed with zero
animations and its original 1400-point native width. The corrected implementation
staged that same known ID at width 432, started both animations, and measured
monotonic growth to 864. Its subsequent AXWindowCreated did not restart staging.
All 234 tests and the optimized build passed. Temporary metadata logging was
removed after diagnosis. This establishes the event-order race and its fix;
Mail's physical first-presentation behavior remains subject to user confirmation.

### 2026-10-26 — verify presented pixels and order before native mapping

The 19:16:52 recording still has a native compose-window frame on top before
staging. A new external ScreenCaptureKit diagnostic samples two 1-by-1 pixel
regions covered by disposable opaque red/green fixture windows. No screen images
are saved. The existing red window is a baseline, and green on the right is the
new-window visibility control; green on the left is a failure because the new
tile never belongs there. Colour classification was calibrated against macOS's
rendered fixture colour (approximately RGB 114/233/91).

This exposed the previous tests' blind spot: native geometry passed while the
pixel check caught one or two opening frames in the wrong region. In the timed
failure, the presentation hold began at 55548.271931, the flash frame had PTS
55548.284312, and the hold ended at 55548.291971. Suppression on the tiler's own
connection did not prevent the foreign window's frame from entering capture.
Attempting suppression on the foreign owner connection returned native error
1000. Neither experiment changed user-window connections.

The opening path now lowers eligible newborn standard windows before waiting
for mapping/Space assignment and full collection. Previously it waited for the
app's original frame to be mapped before ordering it behind peers. Early ordering
is limited to visible BSP layouts with existing peers, preserves existing manual
floating/layer choices, and skips matching explicit rules, dialogs, accessory
apps and known fixed-size windows. A failed/abandoned collection restores the
initial normal layer. No opacity manipulation or new Dock payload is installed.

All 235 tests passed, including eligibility/rule coverage. The final production
callback passed three real creation/presentation runs: all had both colour
controls, two coordinated animations, monotonic growth, and zero flash frames.
Logs are /tmp/shoji-first-presentation/final-production-{0,1,2}.log; the signed
pixel sampler and fixture/controller sources are under /tmp/shoji-first-presentation
and /tmp/shoji-birth-probe. Mail's exact opening sequence still needs visual
confirmation; the fixture result is not a universal pre-presentation guarantee.
