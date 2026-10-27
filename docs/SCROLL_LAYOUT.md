# Scrolling columns

Shoji independently implements scrolling-column behavior while retaining its MIT license. The [Niri v26.04 behavior study](NIRI_PORT_REFERENCE.md) pins the reference and explains the numerical acceptance cases. Upstream implementation and test code were not copied or translated. This is not a clean-room development claim: upstream source was studied.

Track remaining interaction and platform work in the [Niri experience checklist](NIRI_EXPERIENCE_CHECKLIST.md).

## Layout behavior

- Columns default to half width after allowing for gaps. New windows insert immediately right of the active column without resizing existing columns.
- East/west focus reveals the destination with minimal movement. North/south focus changes the active row. Changes to earlier columns preserve the active column's screen position.
- Closing a newly opened column restores the preceding view unless an intervening focus change canceled the return. Floating focus retains the Space's active column.
- Pixel and proportional width requests are retained separately from resolved widths. Proportional requests adapt to display changes; oversized fixed requests remain fixed and left-align when focused. Full-width toggling restores the previous request on exit.
- Width and height presets cycle in both directions. Explicit resizing clears the selected preset. Uncached cycling uses the reference's strict one-pixel tolerance.
- Rows support automatic weights, fixed heights and proportional height requests. Setting a new fixed row converts the previous fixed row to an automatic weight that preserves its apparent proportion. Automatic rows distribute remaining height around minimum constraints; rounded cumulative edges preserve the total.
- Consume, expel and directional consume/expel have separate membership and focus policies. Moving a column carries its width policy with it.
- Centering supports never, always, on-overflow and optional single-column centering. Viewport changes refit the active column.
- Small, slow size adjustments can finish in one native content update while neighbor movement continues; the cutoff is capped at 10 points and the available gap. Fast reversals keep their spring. See [resize motion validation](RESIZE_MOTION_QUALITY.md).
- A shared critically damped camera spring translates the column strip as one unit. Retargeting preserves the current rendered position and velocity; beginning a gesture takes over at that position. The pointer remains stationary by default in scroll layout.

Tree leaves supply ordered column membership; BSP split ratios do not determine scrolling geometry. Existing native Spaces and utility-window policies remain in effect.

## Enable and configure

The feature binary is installed as `bin/shoji`. The existing LaunchAgent was restarted and checked successfully. The currently selected BSP layout and runtime animation duration were preserved. Gestures default to off.

```sh
./bin/shoji -m space --layout scroll
./bin/shoji -m config scroll_center_focused_column never
./bin/shoji -m config scroll_center_single_column off
./bin/shoji -m config scroll_animation on
./bin/shoji -m config scroll_warp_pointer off
./bin/shoji -m config scroll_default_column_width ratio:0.5
./bin/shoji -m config scroll_width_presets ratio:0.3333333333333333,ratio:0.5,ratio:0.6666666666666666
./bin/shoji -m config scroll_height_presets ratio:0.3333333333333333,ratio:0.5,ratio:0.6666666666666666
```

Layout settings also accept `config --space SELECTOR NAME VALUE`; global changes preserve each Space's explicitly overridden settings. Preset lists accept 1–16 comma-separated `abs:pixels` or `ratio:fraction` values. Persist desired settings in your existing shojirc.

`scroll_animation` is a global renderer setting, enabled by default in the daemon. Its camera uses a unit-mass critical spring with stiffness 800 and a 0.0001 settling threshold (about 326ms), rather than independent per-window easing. `window_animation_duration 0` also disables camera animation; positive values keep the camera's spring timing. Other layouts retain their existing animation behavior. `scroll_warp_pointer on` restores the global mouse-follows-focus preference for scrolling columns; an explicit per-window override still takes precedence. `scroll_center_focused_column always` keeps the active column in a centered slot, while the default `never` pans only when needed.

```sh
# Navigation, widths and complete-column movement.
./bin/shoji -m window --focus east
./bin/shoji -m window --focus south
./bin/shoji -m window --column-width abs:700
./bin/shoji -m window --column-width rel:80
./bin/shoji -m window --column-width ratio:0.7
./bin/shoji -m window --cycle-column-width next
./bin/shoji -m window --cycle-column-width prev
./bin/shoji -m window --toggle column-full-width
./bin/shoji -m window --move-column west
./bin/shoji -m window --center

# Row sizing and grouping.
./bin/shoji -m window --row-height abs:300
./bin/shoji -m window --row-height rel:40
./bin/shoji -m window --row-height ratio:0.5
./bin/shoji -m window --row-height weight:2
./bin/shoji -m window --row-height auto
./bin/shoji -m window --cycle-row-height next
./bin/shoji -m window --consume
./bin/shoji -m window --expel
./bin/shoji -m window --consume-or-expel west
./bin/shoji -m window --consume-or-expel east
./bin/shoji -m window --column-display tabbed
./bin/shoji -m window --column-display normal
./bin/shoji -m window --column-display toggle

# Pan without changing keyboard focus; refocusing reveals the active window.
./bin/shoji -m space --scroll rel:250
./bin/shoji -m window --focus
```

Legacy consume appends the next column's first row and keeps focus. Legacy expel moves the last row to a new column on the right; if that row was focused, focus falls to the preceding source row. Directional consume/expel moves the selected row into a neighboring column when it is alone, or into a new adjacent column when it belongs to a multi-row column. A selected background window moves without stealing focus. Missing neighbors and expelling a sole row are no-ops; full destinations return an error before mutation.

Existing Shoji stack/warp/swap commands remain. Legacy swap retains slot widths; use `--move-column` to move the complete column and its width request. Native edge resizing retains the chosen width even when only one scrolling column remains.

## Modifier-assisted horizontal panning

```sh
./bin/shoji -m config scroll_gestures on
```

Hold the configured `mouse_modifier` (currently Fn) while scrolling horizontally. In scroll layout this pans columns. In BSP it switches to the adjacent native Space on the same display after 80 points of horizontal travel. Reaching the last Space wraps to the first; going backward from the first wraps to the last. With only one Space on that display, the gesture does nothing. Each swipe requests at most one switch; its remaining movement and momentum are consumed, including after modifier release or crossing into a scroll-layout Space. Floating layouts and ordinary application scrolling remain available. Phase-less wheel bursts are separated by a 250ms pause.

A captured sequence retains its original Space and operation even after releasing the modifier; unclaimed application momentum is not intercepted. In scroll layout, continuous touchpad deltas are normalized by viewport width / 1200, coalesced before presentation, and followed directly during contact. Release uses the last 150ms of timestamped movement to predict a landing position, chooses a valid column-edge or center snap, focuses the furthest fully visible column toward the projected motion, then settles the shared spring using release velocity. The native momentum tail is consumed without moving the camera again. Existing motion is taken over at its current rendered position. Phase-less wheels settle after a 120ms pause. Turn both layout gestures off with `scroll_gestures off`. The current shojirc enables the setting persistently.

The core release examples and spring timing follow the [pinned interaction reference](NIRI_INTERACTION_REFERENCE.md), with independent tests. This is still modifier-assisted two-finger input, not native three-finger gesture interception. Automatic macOS gestures keep their existing system behavior. The event constants were checked against the installed Apple SDK; [Apple's event guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingTouchEvents/HandlingTouchEvents.html) explains physical versus momentum phases and system gesture precedence.

## Constraints and native presentation

Known width bounds aggregate across column members, with conflicting maxima yielding to the minimum. Known row minima participate in automatic allocation; fixed rows also honor their known maxima. As in the reference, general automatic-height maximum solving is not added. Explicit bounds can be supplied per window:

```sh
# min width : min height : max width : max height; zero means unspecified.
./bin/shoji -m window --size-limits 600:200:0:0
```

Shoji observes accepted native sizes after a request settles and provisionally adapts column and row footprints. The original width/height preference is retained. Changed requests, explicit retries, viewport changes and ownership/context changes invalidate the observation; it is not a permanent inferred minimum or maximum. This is a fallback for asynchronous AX clamping, not a Wayland-style acknowledgment contract. Dimensions refer to the complete native window frame; Shoji does not add Niri decorations or a border/client-size conversion layer. Row membership retains the existing 32-window stack limit.

Tabbed mode gives all members the column frame and orders the active native window above its siblings. It preserves rows and sizing requests when returning to normal mode. It does **not** hide inactive native windows, draw a tab indicator or reproduce compositor input regions; exposed native corners/shadows and other applications' ordering remain backend limitations.

Off-screen windows retain a requested 32-pixel edge rather than being clipped. Multiple parked windows may overlap at that edge, and adjacent displays may expose overflow. Exact foreign clipping, truly hidden off-screen input, synchronized live rendering, overview and logical virtual workspaces remain unimplemented platform work. The scrolling camera positions real native windows, batching each update; AX writes remain asynchronous, and this does not establish compositor-level frame synchronization. Width, height and existing-member position changes use a shared spring timeline with the camera; retargeting preserves current position and velocity. New members start at their target. Interactive native resizing and corrections to already accepted application sizes reflow immediately. Other animation paths can still use captured snapshots. Existing native Space operations retain their scripting-addition requirements.

Queries include target `scroll-offset`, rendered `scroll-position`, spring `scroll-velocity`, `scroll-animating`, `scroll-interacting`, `scroll-resizing` and `scroll-width` on Spaces, plus target logical `layout-frame`, column index/display/active/full-width state, requested width mode, row height and weight on windows. Windows also expose `size-request-pending`, `width-adjusted`, `height-adjusted`, `accepted-width` and `accepted-height`. Logical frames include accepted body sizes and distinguish the layout target from current native presentation and physical edge parking.

The native daemon uses display-paced scrolling by default; `config scroll_frame_pacing off|on` provides an immediate comparison switch. See [timing measurements and limits](DISPLAY_PACING.md).

## Validation and rollback

All 247 deterministic tests pass with warnings as errors, including shared-camera motion, release prediction/snaps/focus, timestamped velocity, gesture takeover, retargeting, stationary pointer policy and rediscovery deferral. The signed candidate builds with warnings as errors and verifies against the existing persistent certificate and identifier. The expanded owned native smoke test passed all 70 WindowServer bounds checks, including six sampled spring positions with preserved visible-column spacing. A separate-process AX fixture also passed minimum/maximum width and minimum row-height adaptation, retained requests and intermediate resize motion with a stationary focused neighbor. See [sizing validation](SCROLL_SIZING_VALIDATION.md) and [earlier validation evidence](SCROLL_FEATURES_VALIDATION.md) for scope and remaining live acceptance.

```sh
# Build candidates without updating the service or Dock.
task build:scroll-preview
task build:scroll-smoke
# Run the owned-window fixture from a terminal in your logged-in macOS session.
./bin/shoji-scroll-smoke scroll-layout
./bin/shoji-scroll-smoke scroll-motion
```

Layout rollback:

```sh
./bin/shoji -m space --layout bsp
```

The pre-feature executable is retained at `bin/scroll-live-20261026/shoji-before-features`. To restore it:

```sh
cp -p bin/scroll-live-20261026/shoji-before-features bin/shoji.next
mv -f bin/shoji.next bin/shoji
launchctl kickstart -k "gui/$(id -u)/tech.shoji.window-manager"
```

The installation did not modify shojirc, replace the Dock payload or restart Dock. Backups live under ignored `bin/`; retain them before running `task clean`.

Existing-window resize presentation now supports [application-colored content fades](RESIZE_CONTENT_FADE.md), controlled by `window_resize_animation fade|off`. This is independent of the camera spring and does not replace the layout model.
