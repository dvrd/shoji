# Content fades during resize

Implemented and validated 2026-10-27 on macOS 15.6 (24G84). This replaces the experimental blur effect with the user's chosen content fade. The window remains visible and interactive throughout.

## Visible sequence

Ordinary BSP and Scroll resizes blend a retained old-content image over the **live application** while geometry changes. The blend uses the geometry animation's explicit clock progress, independent of size rounding, snapped dimensions and retained resize velocity. On an uninterrupted resize, halfway progress means 50% old-image opacity; it disappears when geometry ends. There is no separate post-resize fade, final-content screenshot, readiness wait or background phase. WindowServer scales and blends the retained surface; Shoji does not recapture or redraw it on each frame. Retargeting preserves visible opacity and applies the remaining blend to the new clock instead of restoring an opaque screenshot.

Existing-window BSP animation, Scroll animation and covers now share one display pulse, a fixed predicted sample time and one nested presentation batch. Covers are presented once after the corresponding geometry update. Background-color pixel readback is deferred until a prolonged manual drag actually needs it. See [motion polish evidence and remaining limits](RESIZE_PRESENTATION_POLISH.md).

This independently implements the default Niri resize presentation principle. Upstream's [resize shader](https://github.com/YaLTeR/niri/blob/fcbc971cf49a987b1e8d5ff1d64da6b1f61a1787/src/render_helpers/shaders/resize.frag) mixes the previous snapshot with the current client texture using clamped resize progress; [tile rendering](https://github.com/YaLTeR/niri/blob/fcbc971cf49a987b1e8d5ff1d64da6b1f61a1787/src/layout/tile.rs) uses the same animation for geometry. The [default resize spring](https://github.com/YaLTeR/niri/blob/fcbc971cf49a987b1e8d5ff1d64da6b1f61a1787/niri-config/src/animations.rs) has damping ratio 1, stiffness 800 and epsilon 0.0001. Shoji's Scroll geometry already uses that spring; BSP retains its configured geometry easing. This change adds no second easing curve to either blend. No Niri implementation code was ported.

A prolonged native edge drag holds the old contents for **650ms**, then fades them out over **600ms**. Its fallback color is inferred from the captured application's interior, excluding the title bar and outer edges. The most frequent quantized RGB group supplies the mean color. This is an estimate from app pixels, not the macOS window background or an app-name rule. Gradient/image-heavy or transparent content can make the inferred color less representative; no universal app background-color API is assumed.

After a manual drag settles, the final app image fades in over **100ms**. This fallback path retains its bounded final snapshot. Interrupting that incoming crossfade captures its visible composite and uses it as the next outgoing image. Small size changes retain the existing small-resize policy.

The underlying app keeps rendering and receiving input. A mouse-transparent owned surface handles presentation; native window opacity is not changed. Window close, Space changes, disabling the effect, pointer interaction, owner changes and failures clean up the surface. Ordinary transitions have a three-second hard deadline; active native edge drags have a fifteen-second bound. Eight simultaneous covers are allowed. Capture failure leaves the native window usable and does not change its layout membership. Images are retained in memory and released on cleanup; no screenshots are written by the effect.

Only the manual fallback uses stable WindowServer size observations with an 80ms quiet interval. It is a bounded heuristic, not a client repaint acknowledgment. Layout resizes expose live app updates and finish with geometry; macOS still owns client repaint and composition. This does not establish atomic compositor synchronization or guaranteed artifact-free rendering in every app, especially apps that repaint late or enforce native size constraints. Retargeted blends preserve opacity continuity rather than recreating Niri's internal compositor snapshot transactions: measured synchronous capture/composition stalls made that approach unsuitable for the default path.

## Configuration

Enabled by default in the native daemon:

```sh
./bin/shoji -m config window_resize_animation fade
./bin/shoji -m config window_resize_animation off
```

Persist the desired command in shojirc if overriding the default. Window queries expose `resize-transitioning`. The experimental `window_resize_blur` setting was replaced by this setting. No Core Image blur processing remains in this path.

## Validation

The latest presentation polish passes **262 tests** with warnings as errors, including direct clock progress despite retained velocity, one cover update per frame, shared BSP geometry/content batching, retargeting continuity and the earlier lifecycle/failure cases. The clock and duplicate-update regressions failed before the implementation changed.

The standalone native fixture verifies both paths: the manual background fallback and a coordinated resize with cover alpha 0.5 at halfway, no final screenshot and immediate cleanup at geometry completion. It also checks unchanged real-window alpha and point-query input routing. [Synchronized native result](evidence/resize-fade-24G84/synchronized-native.json). The [earlier manual result](evidence/resize-fade-24G84/native.json) predates the synchronized update. The [latest polish result](evidence/resize-polish-24G84/native.json) adds repeated-retarget continuity and background-readback checks.

Real Chrome and Ghostty resize sequences completed with zero native frame-call failures and restored layouts. Sampled fallback colors were **#161616** in Ghostty and **#0b1017** in Chrome's current content. [Color/timing summary](evidence/resize-fade-24G84/apps.json). These reflect this capture, not fixed app themes. Covers were inactive at final verification. Timing records are CPU/native observations, not displayed FPS or input-to-photon latency; capture still introduces preparation cost.

```sh
task build:resize-fade
# Run from the logged-in macOS session; creates one disposable owned window.
./bin/shoji-resize-fade bin/fade-check.json
```

The signed application is installed and the LaunchAgent is healthy. The prior layouts, animation duration and gesture settings were preserved; Dock was not restarted. The executable preceding synchronized blending is retained at `bin/niri-resize-reference/shoji-before-synchronized-resize`, alongside the failing regression output and passing update results. The pre-effect executable and earlier traces remain under `bin/resize-fade-20261027/`; preserve evidence before cleaning ignored build artifacts.
