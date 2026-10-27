# How Niri tests animation behavior

Investigated 2026-10-26 against the official current documentation and GitHub `main` files retrieved by the web tool. These links are moving references; a current-main commit could not be resolved in this environment. Shoji's separate behavioral reference remains pinned to v26.04. This is source inspection, not an executed Niri test run or measured Niri frame-rate comparison. No upstream test implementation was copied.

## Deterministic geometry tests

Niri constructs its test layout with `Clock::with_time(Duration::ZERO)` and fake `TestWindow` clients. Clients retain requested sizes separately from their actual geometry, can force a different size, and apply changes through explicit `Communicate` operations. This lets tests control client responses independently from layout actions. [Test harness](https://github.com/niri-wm/niri/blob/main/src/layout/tests.rs).

`src/layout/tests/animations.rs` deliberately configures resize and window movement as **1000ms linear animations**, instead of production springs. Tests advance the clock explicitly and compare formatted animated widths/heights and render positions with `insta` text snapshots. These are geometry snapshots, not screenshot comparisons.

Examples include `height_resize_animates_next_y` (after 500ms, height 100→50 is 75 and the sibling Y is also 75), `height_resize_and_back` (retargeting causes no instantaneous position jump), and `width_resize_and_cancel_of_column_to_the_left` (a resizing left neighbor preserves the focused right column's X). `clientside_height_change_doesnt_animate` distinguishes spontaneous client resizing from a compositor-issued resize. The linear test curve makes intermediate assertions easy to calculate; **1000ms is not the recommended production animation duration**. [Animation tests](https://github.com/niri-wm/niri/blob/main/src/layout/tests/animations.rs).

## Visual test application

`niri-visual-tests` is an interactive GTK application using mock windows with the actual layout and rendering code. Its cases include opening between windows, opening multiple windows quickly, opening to the left, oversized versions, and client-side-decoration shadows. A slowdown slider ranges from 0 to 10 with default 1. Developers inspect the resulting motion visually. [Application cases and controls](https://github.com/niri-wm/niri/blob/main/niri-visual-tests/src/main.rs).

The inspected CI runs ordinary tests separately, and its long randomized-test job sets `PROPTEST_CASES=200000` plus rejection/shrinking limits of 200000. The visual-test job **builds** the visual application; it does not launch it and score perceptual smoothness. [CI workflow](https://github.com/niri-wm/niri/blob/main/.github/workflows/ci.yml).

## Real runtime verification and profiling

The documented development workflow starts with a nested compositor window, then a separate TTY, then use as the main compositor. For diagnosing slowdowns, the current recommended profiling build is `cargo build --release --features=profile-with-tracy-ondemand`; Tracy collects while connected and can show CPU scheduling/context-switch information with the documented Linux tracing setup. The always-on `profile-with-tracy` option is also available for startup/CLI profiling. [Development and profiling guide](https://niri-wm.github.io/niri/Development:-Developing-niri.html).

Niri's clock can be overridden for deterministic tests and for rendering at a predicted next monitor presentation time. Its redraw loop follows output refresh/VBlank rather than treating an arbitrary timer tick as a displayed frame. These mechanisms support consistent timing; they do not make a geometry unit test a measurement of actual displayed smoothness. [Animation timing](https://niri-wm.github.io/niri/Development:-Animation-Timing.html), [redraw loop](https://niri-wm.github.io/niri/Development:-Redraw-Loop.html).

## Production animation defaults

| Animation | Type | Parameters |
| --- | --- | --- |
| Horizontal view movement | Spring | Damping ratio 1, stiffness 800, epsilon 0.0001 |
| Window movement | Spring | Damping ratio 1, stiffness 800, epsilon 0.0001 |
| Window resize | Spring | Damping ratio 1, stiffness 800, epsilon 0.0001 |
| Overview open/close | Spring | Damping ratio 1, stiffness 800, epsilon 0.0001 |
| Workspace switch | Spring | Damping ratio 1, stiffness 1000, epsilon 0.0001 |
| Window open | Easing | 150ms, ease-out-expo |
| Window close | Easing | 150ms, ease-out-quad |

These values come from [animation defaults](https://github.com/niri-wm/niri/blob/main/niri-config/src/animations.rs). Spring mass is fixed at 1. For critical damping, the implementation estimates duration as `-ln(epsilon)/sqrt(stiffness)`: about 326ms at stiffness 800 and 291ms at 1000. These are derived settling times, not fixed-duration easing configuration. [Spring implementation](https://github.com/niri-wm/niri/blob/main/src/animation/spring.rs).

## Apply the testing approach independently in Shoji

1. Keep deterministic clock/geometry tests, including mid-animation retargeting and delayed/refused native sizing. Add reason-aware animation cases rather than checking only final layouts.
2. Build a repeatable visual scenario runner with normal-speed and slowdown controls, using the same production motion code. Cover rapid reversals, quick insertion/close and focused-neighbor anchoring.
3. Measure real Chrome/Ghostty input timestamps, frame sampling, native call durations and observed frames. Compare distributions and missed presentation opportunities at the laptop's actual refresh rate before and after scheduling changes.

The inspected sources do not establish a universal automated Niri smoothness score, an FPS pass threshold or a latency percentile target. Shoji must define and measure those explicitly; passing deterministic assertions alone is insufficient.

## Transaction expiry and initial mapping

Checked during the opening-lifecycle design session on 2026-10-27 against the
pinned v26.04 reference. The 300 ms deadline completes the synchronization
transaction and releases its transaction blockers. It does not float windows,
cancel their layout membership, or manufacture a ready client buffer. Ready
commits can proceed; a late commit no longer waits on that completed transaction.
Other readiness blockers, such as a pending DMA-BUF, remain independent.
[Transaction completion](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/src/utils/transaction.rs),
[mapped-surface commit handling](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/src/handlers/xdg_shell.rs).

For an already mapped window, existing committed content remains available until
replacement content commits. A newcomer that has not supplied its first mapped
buffer stays in the unmapped-window path; the transaction deadline is not a
general initial-window admission timeout.
[Initial mapping](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/src/handlers/compositor.rs).
The proposed Shoji fallback of floating a window on preparation failure is not
Niri's deadline behaviour. The user explicitly rejected this fallback on
2026-10-27; see [the opening lifecycle decision](adr/0001-shared-window-opening-lifecycle.md).

Shoji now has an independent [motion scenario runner and bounded live trace capture](MOTION_LAB.md). Native sample timing is not a displayed-frame measurement.

## Opening lifecycle acceptance on real applications

The [shared opening lifecycle contract](adr/0001-shared-window-opening-lifecycle.md)
must be verified with actual Mail, Ghostty and Chrome windows. Fixture results,
native bounds, successful API replies and unit tests are supporting evidence;
they do not establish the real applications' first-presentation behaviour.

Record a failing baseline before the implementation change, then repeat the same
real-app scenarios on the candidate build. Evaluate normal-speed recordings and
their individual presented frames, with lifecycle traces correlated to the
recording where necessary. Preserve the user's configuration during validation.

| Scenario | Required outcome |
| --- | --- |
| Open an independent window beside existing tiles | Preparation itself leaves existing tiles unchanged; one coordinated opening follows readiness, without a native full-size flash or preparatory shrink-and-grow cycle. |
| Open multiple windows with different readiness times | Ready newcomers proceed independently; pending ones do not change classification or block other apps. |
| Admit another window during an opening transition | Motion continues from visible positions; previously admitted windows do not replay their opening effects. |
| Select another window while a newcomer prepares | Completion does not take focus back. |
| Close an existing tile during preparation | The close is processed immediately; the pending opening uses the remaining layout. |
| Close a pending newcomer | No later admission, reflow or focus action may refer to that closed window. |
| Open a parent-associated dialog | The dialog stays above its parent and does not reflow the tiling layout. |
| BSP geometry encounters a native minimum | Preserve split direction and adjust the ratio only as necessary when participants can fit; establish geometry before visible opening. |
| BSP cannot fit the newcomer | Keep it pending with a clear indication, preserve the selected layout and admit normally when room becomes available. |
| Receive duplicate or late observations | An existing window is not admitted or opened again. |

Run applicable scenarios with both BSP and scrolling geometry policies, including
cross-application arrivals. A native presentation limitation must be reported as
unresolved rather than concealed by a per-application fallback or a passing
fixture test. The first-frame visibility guarantee remains an acceptance target,
not an established macOS backend capability.
