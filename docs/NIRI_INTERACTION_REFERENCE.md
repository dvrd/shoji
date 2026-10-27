# Niri interaction reference

Reference: official Niri **v26.04**, commit `8ed0da44d974c32c6877d2f4630c314da0717ecb`. Investigated 2026-10-25. This describes behavior for an independent implementation; no upstream implementation code is reproduced. Numeric results below are source-derived, not observations from running Niri locally.

## What the “spread deck” analogy captures

The physical display is a stationary viewport. Windows occupy non-overlapping columns along a wider horizontal strip. Panning reveals another portion of that strip: every tiled column moves by the same screen displacement, retaining its width and relative spacing. Focusing another window does not reorder the columns. The analogy is useful if the cards are **spread side by side**; it would be misleading if it meant overlapping cards, bringing one raised card forward, or moving only the newly focused window. Floating windows and tabbed columns are separate behaviors. [Pinned README](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/README.md), [layout coordinates](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/src/layout/scrolling.rs#L2294).

For three half-width windows on a 1280-wide working area with gap16 and no decorations, each column is 616 wide. With A/B visible their screen X values are 16/648; focusing C slides the strip left632, giving A/B/C screen X -616/16/648. Focusing B at this point changes focus without moving the strip, because B is already visible. Focusing A then slides the strip right632. No window expands into a full-screen singleton merely because its neighbor became focused.

The official README links a [general demo](https://github.com/niri-wm/niri/assets/1794388/bce834b0-f205-434e-a027-b373495f9729), [touchpad demo](https://github.com/niri-wm/niri/assets/1794388/946a910e-9bec-4cd1-a923-4a9421707515), and [animation demo](https://github.com/niri-wm/niri/assets/1794388/ce178da2-af9e-4c51-876f-8709c241d95e). They are useful human comparison targets. The available web fetcher could not retrieve their media, so this investigation does **not** claim to have watched or measured those videos; the assertions here follow the pinned docs and source.

## Keyboard, focus and pointer ergonomics

Default bindings use `Mod+Left/Right` or `Mod+H/L` to change column focus; `Mod+Ctrl+Left/Right` changes column order. Those are different operations. Default centering is `Never`: keep the camera still whenever the new target is already fully visible, otherwise make the minimum edge-aligning pan needed to expose it. `Mod+C` explicitly centers the current column. [Default bindings](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/resources/default-config.kdl#L403), [focus policy](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/src/layout/scrolling.rs#L545).

`Always` is the option for a persistent centered interaction slot: in the same example the active616-wide column sits at X332. `OnOverflow` centers when the target and its arrival-side neighbor cannot fit together; it is not equivalent to centering whenever a workspace has three windows. Width, gaps, single-column centering and viewport policy are independent settings. [Pinned layout defaults](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/niri-config/src/layout.rs#L29).

Pointer warping and focus-follows-pointer are opt-in, commented out in the default configuration. Enabling warp normally changes only whichever pointer coordinate needs adjustment to enter the focused window; optional modes center both coordinates or always recenter. Changing keyboard focus therefore does not imply pointer movement by default. [Input settings](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/docs/wiki/Configuration%3A-Input.md#L304), [default configuration](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/resources/default-config.kdl#L65).

Focus and layout actions become effective immediately; animation follows the new state. Waiting until a visual transition completes before accepting the next focus command would diverge from Niri. [Design principles](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/docs/wiki/Development%3A-Design-Principles.md).

## Actual gesture vocabulary

| Input | Niri behavior |
| --- | --- |
| Three-finger horizontal swipe | Continuous horizontal viewport movement |
| Three-finger vertical swipe | Change workspace vertically |
| Four-finger vertical swipe | Open/close overview |
| Mod + middle-button horizontal drag | Continuous horizontal viewport movement |
| Mod + middle-button vertical drag | Workspace switching |
| Two-finger scroll inside overview | Pan horizontally or navigate workspaces vertically |
| Default Mod + horizontal wheel binding | Discrete column focus, rather than the three-finger viewport gesture |

[Pinned gesture documentation](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/docs/wiki/Gestures.md), [overview](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/docs/wiki/Overview.md), [wheel bindings](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/resources/default-config.kdl#L488).

Consequently, an opt-in modifier plus ordinary macOS two-finger scroll is a separate accessible control. It must work reliably if offered, but should not be described as already implementing Niri's native three-finger interaction. This distinction separates input capture failures from viewport-model failures.

## Deterministic continuous pan and release specification

The following is a behavioral description of [gesture begin/update/end](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/src/layout/scrolling.rs#L3012) and the [velocity tracker](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/src/input/swipe_tracker.rs), rather than translated code.

1. Beginning a pan takes over the viewport at its **current rendered position**, including an interrupted animation. An empty workspace or active interactive resize does not begin an ordinary pan. Logical active focus is retained during ordinary updates.
2. Physical updates continuously adjust camera position; touchpad movement is normalized by `working_width / 1200`. Thus 120 raw horizontal units pan 128 logical pixels on a 1280-wide working area, independent of how many columns exist. Mouse dragging uses unnormalized logical displacement.
3. Keep a 150ms velocity history; older samples drop out, while cumulative position retains all movement. Nonmonotonic timestamps are ignored. Release adds a zero-delta sample at release time, accounting for any pause before lifting fingers.
4. Predict the eventual camera location using normalized release velocity. The upstream deceleration constant is 0.997 per millisecond: projected extra travel is approximately **0.332833083 × velocity_in_pixels_per_second**. This prediction selects the snap; it is not a request to play an unsnapped native momentum stream first.
5. Choose the closest valid snap position. Noncentered normal columns have padded left/right boundary candidates. Outer candidates stop at the first column's left alignment and last column's right alignment; only interior candidates strictly between those bounds are added. Gaps reduce if the column nearly fills the working area. Fullscreen/maximized columns use different areas/padding. Always-centered mode provides one center candidate per ordinary column, left-aligning oversized columns. `OnOverflow` substitutes center candidates where the adjacent pair overflows.
6. Sort candidates by camera coordinate. Equal-distance candidates prefer the earlier coordinate. In noncentered mode, choose the furthest completely visible column in the **projected travel direction**, including padding, as the new focus. Positive or zero projected-versus-current displacement searches right; negative searches left. Centered mode activates the selected center's column directly.
7. Set new logical focus and animate from the release position toward the snap using release velocity; finally ensure the newly focused column is visible. Cancellation follows this settling path rather than restoring a saved original column.

### Exact release fixtures

Assume 1280 width, gap16, three 616-wide normal columns A/B/C at logical X 0/632/1264, zero struts and default `Never` centering. Their **only distinct permitted camera snaps are -16 and 616**. These expose A+B or B+C respectively; there is no intermediate centered-B snap. Velocity below is normalized pixels/second in the camera coordinate convention.

| Camera at release | Release velocity | Projected camera | Settled camera | New focus |
| --- | ---: | ---: | ---: | --- |
| 100 | +100 | 133.2833 | -16 | B, the rightmost fully visible column |
| 400 | -100 | 366.7167 | 616 | B, the leftmost fully visible column |
| 300 | +1000 | 632.8331 | 616 | C |
| 300 | -1000 | -32.8331 | -16 | A |
| 300 | 0 | 300 | -16 (equal-distance tie) | B (zero is rightward branch) |

For four half-width columns the distinct snaps are -16/616/1248. At snap 616, positive release focuses C and negative release focuses B. For `Always`, the three-column center candidates instead are -332/300/932. These fixtures intentionally distinguish release direction from simply focusing the column nearest the pointer or the viewport center.

## Animation contract

Defaults use a spring with damping ratio 1, stiffness 800, epsilon 0.0001 for horizontal camera movement, ordinary window movement and resizing. Workspace switching uses stiffness 1000, otherwise the same parameters. Ratio 1 is critically damped: no default oscillation from an initially stationary transition, while release velocity still influences the path. Opening/closing windows instead uses 150ms easing. [Pinned animation configuration](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/niri-config/src/animations.rs#L130).

For an independent mathematical implementation with mass 1, the target-relative displacement satisfies the conventional damped-spring equation `y'' + 2ζ√k y' + k y = 0`. At critical damping its analytic trajectory is `y(t) = (y₀ + (v₀ + √k y₀)t) exp(-√k t)`. Position is target plus that displacement. Use seconds and logical pixels; supply release velocity in pixels/second. Upstream's critical spring duration convention is `-ln(epsilon)/√k`, about 325.635ms for 800 and 291.257ms for 1000, then the animation returns the exact target. This is a numerical contract, not a fixed-duration cubic easing with a “spring” label. [Spring parameters and timing](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/src/animation/spring.rs), [animation evaluation](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/src/animation/mod.rs#L249).

Reproduce these state and timing contracts separately from rendering. Moving native macOS windows asynchronously does not by itself provide Niri's compositor-controlled clipping, atomic surface transforms or per-output presentation timing. Native momentum integration without the projection/snap/focus sequence above remains a distinct implementation, even if its final window arrangement sometimes matches.
