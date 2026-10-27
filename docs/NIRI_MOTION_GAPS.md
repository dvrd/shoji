# Niri motion gaps

Investigated 2026-10-26. Shoji's behavioral reference remains Niri v26.04 (`8ed0da44d974c32c6877d2f4630c314da0717ecb`); current official docs were also checked for timing guidance. No Niri code was copied. This is a source comparison, not a measured performance diagnosis. The user reports that Chrome/Ghostty functional checks pass, while smoothness, reversal and settling remain rough.

## What already matches

Shoji's camera and geometry trajectories use critical damping, stiffness 800 and epsilon-derived settling time. They preserve position/velocity when retargeted, and resize/neighbor/camera movement share the same model timing. These match the documented Niri defaults and synchronization intent. Changing spring constants alone does not address the backend differences below. [Niri animation settings](https://niri-wm.github.io/niri/Configuration:-Animations.html), [Shoji camera](../src/engine/scroll_motion.odin), [geometry](../src/engine/scroll_geometry.odin).

## Concrete differences relevant to smoothness

| Area | Niri reference | Current Shoji | Implication |
| --- | --- | --- | --- |
| Presentation timing | Samples animations for predicted monitor presentation time; one shared clock stays fixed throughout an action | General run loop waits up to 16ms, then sequential work samples wall time; no display-link/presentation target in this path | Scheduling is not refresh-aligned. This is an architectural gap; actual latency/jitter must be measured |
| Native rendering | Owns compositor redraw submission and waits for output VBlank | Reads bounds and sends AX frame writes to each foreign window; update suppression batches calls | A shared mathematical trajectory does not establish synchronized client repaint/presentation |
| Resize presentation | Distinguishes layout/client resize from visual resize effects; documents manual resize animation and skipping size changes up to 10px | Geometry changes above 0.001 tolerance animate in general; each sample can issue native size writes | No equivalent small-change/animation-reason policy; intermediate app layout work may matter and needs profiling |
| Accepted-size correction | Immediate logical actions remain effective while client content catches up | After quiet/stable native observations, accepted-size adaptation uses immediate reflow | This correction intentionally avoids animating through an already accepted frame, but can cause a visible second adjustment |
| Gesture reversal | Velocity participates in release spring | Timestamped deltas feed a 150ms velocity window and coalesced input; physical deltas follow directly | Core contract exists; reversal response needs a measured trace before changing velocity filtering |

Timing sources: [Niri animation timing](https://niri-wm.github.io/niri/Development:-Animation-Timing.html), [redraw loop](https://niri-wm.github.io/niri/Development:-Redraw-Loop.html), [immediate-action design](https://niri-wm.github.io/niri/Development:-Design-Principles.html). Resize policy: [animations](https://niri-wm.github.io/niri/Configuration:-Animations.html#window-resize).

Shoji evidence: [daemon loop](../src/macos/daemon_darwin.odin:199), [input coalescing and native ticks](../src/macos/scroll_darwin.odin), [AX frame writes](../src/macos/frame_darwin.odin:80), [presentation batching](../src/macos/frame_updates_darwin.odin), [accepted-size correction](../src/macos/size_feedback_darwin.odin:56). The 16ms run-loop limit is a maximum wait, not a guarantee of 62.5fps or proof that it is the dominant bottleneck.

## Next implementation order

1. Instrument event timestamps, input consumption, layout sampling, AX call durations and native observed bounds. Measure Chrome/Ghostty at the laptop's actual refresh rate, including reversal, repeated focus and resizing. Separate application response time from Shoji scheduling time.
2. Introduce a display-paced scheduling path with one consistent action/sample timestamp, newest-target coalescing and bounded work per frame. A display callback alone cannot make foreign AX writes atomic; validate improvement against the measurements.
3. Add reason-aware resize presentation and a tested small-change policy, keeping logical actions immediate. Reduce redundant requests and assess correction behavior without discarding retained user sizing preferences.
4. Tune gesture takeover/reversal and settling using recorded traces, then test close/minimize/restore and interrupted motion. Preserve the existing pinned release fixtures.

## Feature parity scope

No: Shoji does not implement all Niri features. The [experience checklist](NIRI_EXPERIENCE_CHECKLIST.md) records missing or partial focus indication, complete tab concealment/controls, insertion feedback, drag-edge scrolling, dynamic workspaces, overview/rearrangement, unmodified gesture vocabulary and output behavior. Foreign clipping/coherent presentation remain backend capability gates.

That checklist is a scoped v26.04 experience target, not an exhaustive inventory of every current Niri feature. Current docs also describe recent-window switching and further configuration, effects and device integrations; future additions must be version-scoped rather than silently implied by a checked core-layout item. [Current animation inventory](https://niri-wm.github.io/niri/Configuration:-Animations.html), [gesture inventory](https://niri-wm.github.io/niri/Gestures.html).

## Update — display pacing implemented, 2026-10-27

The original timing gap above now has a native display-linked implementation, pending-pulse coalescing, idle pause/fallback and fresh per-command action timing. Alternating real Chrome/Ghostty trials favored pacing. This does not establish synchronized foreign rendering or perceptual parity; [measurements and remaining limits](DISPLAY_PACING.md) supersede the earlier scheduling status.
