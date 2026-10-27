# Niri-style Shoji on macOS

Investigated 2026-10-25. Current validation target: macOS 15.6 / 24G84, Apple silicon. This is a feasibility assessment and proposed experiment sequence, not a completed implementation or SIP-enabled certification. No desktop state, running service, or security setting was changed.

## Conclusion

Implementation update: an opt-in scrolling-column layout and proxy-animation retargeting are now implemented. See [scroll layout preview](SCROLL_LAYOUT.md) for the separate candidate, commands, tests, limitations and pending live acceptance. This does not resolve foreign clipping or establish compositor parity.

Runtime update: the [first clipping experiment](COMPOSITOR_PROBE_RESULTS.md) passed its owner-issued control but the ordinary controller did not clip the foreign window, despite a zero setter return. That direct path is not a usable backend on the tested host. This narrows the unresolved clipping capability; it does not invalidate scrolling-layout semantics.

Shoji can implement the scrolling-column workspace model while WindowServer continues composing native applications. A full reproduction of Niri's rendering and input behavior remains unproven: clean clipping of foreign windows, synchronized surface transforms and input regions, and reliable concealment outside a viewport are the decisive gaps.

The recommended direction is an optional scrolling layout plus an independently tested presentation backend. Do not make replacement or modification of WindowServer a prerequisite. Existing evidence does not establish a supported way to replace macOS's compositor for the logged-in desktop; patching protected Apple processes would also conflict with the SIP-enabled objective. Apple's [runtime protections](https://developer.apple.com/library/archive/documentation/Security/Conceptual/System_Integrity_Protection_Guide/RuntimeProtections/RuntimeProtections.html) document protected-process attachment restrictions.

See [Niri feature research](NIRI_FEATURE_RESEARCH.md) for the source-side behavior and [external compositor investigation](../EXTERNAL_COMPOSITOR.md) for the prior private-API and ownership findings.

## What can be reproduced

The classifications below are engineering assessments, not claims that these features already exist in Shoji.

| Experience | Feasibility and implementation boundary |
|---|---|
| Horizontal columns, stable widths, focused-window reveal | High confidence as layout logic. Maintain ordered columns and a viewport offset; creating a window need not resize existing columns. Apply positions through AX. |
| Multiple windows in a column, tabbed presentation, width presets, centering, consume/expel and reorder commands | High confidence for the logical model. Tabbed presentation also needs a policy for concealing inactive members. AX app minimum sizes and geometry refusal need reconciliation. |
| Independent strips per display and native Space | Practical first scope. Preserve current native Space identities and navigation; add one scrolling view to each existing user Space. Native Space lifecycle operations retain their existing backend requirements. |
| Dynamic logical workspaces with vertical switching | Feasible as a separate Shoji model. Requires a hiding/restoration strategy, persistence, activation handling and hotplug rules. These would not be native Mission Control desktops; do not silently change existing Space commands. |
| Keyboard navigation and modifier-assisted wheel/trackpad scrolling | Plausible through existing input infrastructure and new gesture handling. Gesture arbitration, inertia and cancellation require testing; current observation of system gestures is not a scrolling-layout implementation. |
| Borders and floating dialogs | Existing machinery can be reused selectively. Dialogs and sheets need explicit transient relationships and visibility policy; arbitrary always-above layering without the addition remains unverified. |
| Overview with selectable thumbnails | Plausible as a separate capture/rendering feature. It requires capture permission and appropriate handling of unavailable content. Selecting a thumbnail should restore/focus the real window. A thumbnail is not a native interactive application surface. |
| Smooth animations | Possible to investigate, with different quality tiers. AX frame writes and current snapshot proxies do not establish Niri's frame-synchronized live surface behavior. |
| Invisible off-screen columns and exact display-edge clipping | Unresolved. Off-screen placement alone has known constraints; private cross-owner clipping must be proved with correct input and restoration behavior. |
| Compositor-level input routing, arbitrary shaders, direct scanout and desktop-wide surface ownership | No equivalent general control established for an ordinary macOS window manager. These require a different level of authority than AX movement or drawing Shoji-owned windows. |

## Evidence from macOS implementations

[Paneru](https://github.com/karinushka/paneru#recommended-system-options) is a working implementation lead for scrolling tiling. Its documentation explicitly retains thin visible slivers because fully off-screen windows may be relocated by macOS, and recommends vertical display arrangements to avoid cross-display problems. Its statement that strips are independent should not be read as proof of compositor clipping.

[PaperWM](https://github.com/mogenson/PaperWM.spoon#limitations) independently documents edge margins, clickable off-screen-window remnants and display-arrangement constraints. These establish a practical approximation, not a seamless bounded viewport.

[AeroSpace's virtual workspace guide](https://nikitabobko.github.io/AeroSpace/guide#emulation-of-virtual-workspaces) describes hiding windows at screen corners and restoring them. It is a concrete model for logical workspaces, with documented Mission Control and display tradeoffs.

[Paneru's experimental decoration documentation](https://github.com/karinushka/paneru/blob/main/CONFIGURATION.md#7-experimental-features) reports limited layering authority and overlay edge cases. This supports treating layering separately from layout.

[Apple's AX setter](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue) provides a route to change exposed window attributes. [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) provides captured content; that API's purpose is capture, not reassignment of native window ownership or input. Using captures for overview/transition visuals is an engineering proposal, not evidence of a fully interactive external compositor.

## Shoji's current implementation boundary

- `src/engine/tree.odin`: `Layout` contains Float, BSP and Stack. `View` owns a binary tree. Scrolling columns and viewport state do not exist. Add a distinct representation rather than forcing columns into split ratios.
- `src/engine/model.odin`: the engine emits actions through a backend procedure. `Space.id` and `Window.space` currently refer to native Spaces. Introduce a separate identifier if logical workspaces are added.
- `src/macos/frame_darwin.odin`: real geometry is applied through AX position/size attributes. A successful write is not evidence that an app accepted the exact off-screen geometry; readback matters.
- `src/macos/animation_darwin.odin`: Shoji captures a window into its own proxy, and currently checks/uses the addition to hide and restore the real window. Reusing this path does not remove injection dependence. The captured image also does not provide a live input surface.
- `src/macos/backend_darwin.odin`: Space operations and effects including opacity, layers, ordering and scale route through the addition. Capability reporting and fallback choices must distinguish those from ordinary frame changes.
- `src/macos/mouse_darwin.odin`: existing gesture observation suspends conflicting work during system transitions; new viewport gestures need explicit routing rather than treating all gestures alike.

Keep logical layout coordinates separate from physical presentation coordinates. Otherwise AX clamping, parking inactive windows and animation feedback can corrupt the stored strip. This is a design recommendation based on the code above.

## Highest-value experiment before committing to visual parity

The first gate was implemented as an isolated Odin clipping probe. That research tool now lives outside Shoji at `~/dev/tools/compositor-probe`; run `task build` or `task test` from that directory. Its build and six deterministic tests pass. The agent session has no WindowServer connection, but the user completed a run from Terminal: owner clipping and sampled input routing pass; ordinary foreign clipping does not. See [results](COMPOSITOR_PROBE_RESULTS.md). Translation, full hiding and multi-display acceptance are not implemented by this first gate.

Implement a standalone Odin diagnostic with an owned positive-control window and a disposable window owned by a separate fixture process. Validate current private signatures before calling them. Do not use Dock's connection or an injected payload for the ordinary-process test.

1. Establish whether a foreign native window can be clipped to a display-sized viewport from an ordinary process. Compare return values, independent state observations, rendered pixels and click behavior. Symbol availability alone is insufficient.
2. Test translation separately: rendered and clickable areas must stay aligned. Then test concealing an entire foreign window without minimizing an application or changing its Space.
3. Cover shadows, titlebars, menus, transient dialogs and restoration. Check behavior at actual display boundaries; use physical multiple displays when available rather than claiming laptop-only validation proves it.
4. Run each operation with a separate restoration watchdog. Restore original state on cancellation, diagnostic exit and fixture exit. Touch only fixture windows.
5. Record the OS build, caller connection and SIP state. Current custom SIP settings cannot certify fully SIP-enabled operation; repeat on a suitably configured test environment before making that claim.

The existing addition can be tested later as a separate privileged capability tier. Its current authority over some effects does not prove clipping, input alignment or multi-window atomic presentation.

## Implementation sequence after the experiment

1. **Pure scrolling model:** ordered columns, rows, widths, focused member and viewport offset. Unit-test layout invariants, minimum-size negotiation, focus reveal, removal and display resize. No live desktop effects required.
2. **Opt-in native-window layout:** one strip per current user Space, keyboard commands, direct AX placement and floating/transient handling. Start with animations disabled. Measure frame-application latency and avoid redundant size writes while merely panning.
3. **Presentation strategy:** use verified clipping if available; otherwise offer an explicitly documented edge-margin approximation. Do not secretly resize window content to fake cropping or assume an overlay fixes native hit-testing.
4. **Gestures and animation:** coalesce viewport updates, apply bounded work, measure AX/event-loop latency, and handle interruptions. Do not assume app-mediated geometry writes will meet compositor frame deadlines.
5. **Optional logical workspaces and overview:** add recovery/persistence and explicit commands. Preserve native fullscreen as a separate OS transition from full-width columns and maximizing inside the tiling area.

Success for the first usable version means stable scrolling columns, predictable focus, visible dialogs, deterministic recovery and honest reporting of presentation limitations. Exact compositor parity is a separate acceptance target requiring the private-capability results above. The macOS 27 runtime port remains deferred independently of this investigation.
