# Small resize and native move polish

Implemented and validated 2026-10-27 on macOS 15.6 (24G84). This follows the [display-pacing work](DISPLAY_PACING.md) and independent [Niri animation study](NIRI_ANIMATION_TESTING.md).

## Changes

Small geometry changes can now finish in one content-size update while window positions retain their shared spring. The cutoff is at most 10 points, capped by the configured gap. Cancellation is permitted only for stationary or slow motion already heading toward the new size; fast motion and reversals preserve their existing spring velocity. Width and height are handled separately, so finishing one dimension does not restart the other. Large resizes retain their coordinated size/camera/neighbor trajectory. Native accepted-size corrections retain their existing immediate reflow behavior.

This is a conservative macOS adaptation of Niri's small-resize policy. It adds gap and velocity guards because Shoji changes real native window frames rather than transforming compositor-owned surfaces. It does not establish complete reason-aware resize parity.

Scroll frame writes also distinguish native size rounding from a real resize. With known previous geometry, a difference strictly below half a point does not issue AXSize during movement. A half-point change still issues a real resize. This tolerance is confined to the scrolling native path; existing callers retain exact comparison by default. In the injected native attribute regression, a rounded position-only change now sends one AXPosition write instead of AXSize/AXPosition/AXSize.

## Evidence

247 deterministic tests pass with warnings as errors. New cases cover rounded position-only motion, preservation of real half-point resizing, slow small-size interruption with continuous neighbor position, and fast/small-gap cases that retain coordinated resizing. The rounded-write and small-resize regressions failed before the policy changes. An exploratory manual-only reflow policy was excluded: abruptly changing large native content while animating neighbors can create overlap; the coordinated large-size path remains.

The expanded scenario runner adds a six-point column adjustment and five-point row adjustment. Model playback passed three repetitions (1479 samples). Display-paced owned AppKit playback passed three repetitions (1471 samples), with zero invalid bounds readbacks. Native observations still differ transiently from requested frames, as documented in the earlier runner; passing scenario execution is not a presentation barrier.

Existing frame-write coalescing allows differences below 1.5 points to remain until a later material update. Consequently, the runner permits that existing positional tolerance only when a documented small-size completion causes a frame write; larger retargets retain the stricter continuity check.

## Real application check

Chrome and Ghostty were run through the same six large resize requests, followed by 1000→1003→1000 point adjustments. Each app's existing Space was temporarily switched to scroll layout, then its previous layout and the original active Space were restored.

| App | Prior small-step behavior | Updated small-step behavior |
| --- | --- | --- |
| Ghostty | 25 then 33 spring samples; one native frame call per step | Zero extra spring samples; one native call per step, requesting exactly 1003 then 1000 |
| Chrome | 27 then 33 spring samples; one native frame call per step | Zero extra spring samples; one native call per step, requesting exactly 1003 then 1000 |

The old coalesced writes requested intermediate widths around 1001.6/1001.7 instead of the first step's final 1003. The new path issues the final small size directly. Native frame-call failures were zero before and after. [Machine-readable comparison](evidence/motion-quality-24G84/comparison.json) also retains overall timing, which was mixed and is not used to claim a universal speedup.

Raw local traces and before/after snapshots are retained under `bin/motion-quality-20261027/`. The pre-update executable is `bin/motion-quality-20261027/shoji-before-motion-quality`. Shoji was restarted successfully with its existing signing identity; animation duration, gestures, BSP layouts and full work-area window frames were preserved. Dock was not restarted. Capture was cleared afterward.

## Remaining acceptance

The native cases validate the policy and real app commands, not perceived motion quality or displayed frame rate. Manual swipe reversal, simultaneous foreign-client movement and larger application-driven reflows still need focused validation. This change does not add foreign-window clipping, compositor synchronization or snapshot-based resize rendering.
