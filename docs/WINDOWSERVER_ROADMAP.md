# WindowServer roadmap: Niri capabilities → mechanisms

Mapped 2026-11-06 from the 26A434 VM model; rebased 2026-11-07 on the
supported build, 26B123 (physical M1 Max), where the gate now runs in
production through `shoji --ws-attach`. Gated op numbers match the 26B123 table
(`src/payloads/windowserver/gate_expected.odin`); server-internal addresses
quoted below are from 26A434 and differ on 26B123.

- Niri reference: v26.04, commit `8ed0da44d974c32c6877d2f4630c314da0717ecb`.
  The wiki page list and headings were fetched at that commit.
- WindowServer models: `artifacts/macos_versions/<build>/model/` (local,
  produced by `spelunker-port build`, from the separate spelunker project).

The A–D plan that was carried out covered atomic moves (C1), focus receipts (C2),
Space placement (C3) and an adapter (C4). It did not map the rest of Niri. This
document maps it.

## Evidence labels

- **[live]**: observed on a running system, with an artifact path or commit.
- **[static]**: inferred from the decoded table, a disassembly or a symbol name.
  These are unverified hypotheses about behavior.
- **[doc]**: taken from a Niri wiki page or from Shoji's own docs and code.

## What exists today

### WindowServer gate

- **Gated ops [live]:** the table seam holds 14 ops:
  - Ordering: 0x01, 0x03, 0x06
  - Shape: 0x0b
  - Spaces: 0x18, 0x19, 0x21, 0x22, 0x2a
  - Surfaces: 0x33–0x36
  - Geometry: 0x41

  Source: `GATED_OPS` in `src/payloads/windowserver/payload.odin`.
  Install-time checks cover all 139 handlers (`gate_expected.odin`).
- **What "gated" means:** the op can be *held and released*. Shoji cannot
  *issue* any of these ops through the gate.
- **The only effect Shoji can issue is moving a window.** It does this through
  server-internal helpers: lookup, bounds and move at `0x1873e91c8`,
  `0x18732e534` and `0x187333594` (`src/payloads/windowserver/placement.odin`).
- **Gate commands:**
  - `Hello`, `Arm`, `Release`, `Status`, `Dump`
  - `ArmPlace`, `PlacementStatus`
  - `LayoutBegin`, `LayoutAdd`, `LayoutArm`, `LayoutStatus`
  - `Watch`, `WatchStatus`
  - `SpacePlace`, `SpaceApply`

  Source: `Gate_Command` in `src/windowserver/gate/mach.odin`.
- **Batch limits:** a layout batch holds at most 8 moves (`LAYOUT_LIMIT` in
  `src/windowserver/gate/layout.odin`). Shoji uses it only for unanimated,
  move-only relayouts (`layout_batch_eligible` in `src/manager.odin`).
- **Holds serialize all of WindowServer [live]:** every client's transactions
  wait while one op is held. Holds must therefore last about one frame
  (B2, `f2533af`).

### Dock payload

The Dock payload can act on foreign windows from Dock's connection. Its opcodes
are:

- **Windows:** `Window_Opacity`, `Window_Opacity_Fade`, `Window_Layer`,
  `Window_Sticky`, `Window_Shadow`, `Window_Focus`, `Window_Scale`,
  `Window_Order`, `Window_Order_In`
- **Proxies:** `Proxy_In`, `Proxy_Out`
- **Spaces:** focus, create, destroy and move, plus
  `Window_To_Space_Transaction`

Source: `src/dock/protocol.odin:6`.

### Connection ownership [live]

Shoji's own connection cannot change foreign windows. Anything aimed at a
foreign window must be issued from Dock's connection or by payload code inside
WindowServer. Evidence: a managed-space move probe (26A434 VM, 2026-11-05) and
`~/dev/tools/compositor-probe` (24G84: an ordinary controller's foreign clip had
no effect).

## Non-transaction paths

| Channel | Path | Status |
| --- | --- | --- |
| Ordering | `__XOrderWindow` → `CGXOrderWindowListSpaceSwitchOptions`, held by the inline hook | [live] gated |
| Geometry (move) | Server move helper `0x187333594`. There is no `SetWindowBounds` op. | [live] used by placement and layout |
| Geometry (size) | No WindowServer op found. Size comes from the client's buffer. 0x12/0x13 `LockedBounds` only constrain it. | [static] |
| Spaces | `SLSMoveWindowsToManagedSpace` skips the table | [live, 26A434] |
| Input shape | Event-shape ops 0x45/0x46, resize shape 0x64, touch shapes 0x43/0x44/0x65 | [static] ops exist |
| Hit-testing and event dispatch | Not mapped. 0x2c `SetEventCapture` and 0x2d `DeferWindowMoveEvents` exist. | [static] unknown |
| Transform | Op 0x0f, op 0x10 (3D), op 0x11 (warp). Also direct `SLSSetWindowTransform`: Dock payload (`src/payloads/dock/payload.odin`) and owned surfaces (`src/surfaces.odin`). | [live] owned and Dock 
| Shadow | 0x48, 0x71, 0x49, 0x53 | [static] |
| Corner mask and radius | 0x4a; 0x69–0x6f | [static] |
| Frame sync | `SLSDisableUpdate`/`SLSReenableUpdate` on Shoji's connection only (`src/display_clock.odin`). The four commit endpoints include `sls_transaction_commit_ca`. No vsync or frame-cl
| Capture | `SLSHWCaptureWindowList` (`src/animation.odin`, `src/resize_transition.odin`) | [live] |

## Classification

| Code | Meaning |
| --- | --- |
| **COV** | Covered now: Shoji has a working route. It may be partial, as noted. |
| **GATE** | The op exists in the decoded table, but there is no Shoji command that issues it. To issue it for a foreign window, Shoji needs a Dock-connection transaction or a payload-side helper. Some rows need a new ga
| **NEW** | Needs a new hook or op family: no table op covers it, or the path has not been mapped. |
| **ALT** | Needs a route other than WindowServer: AX, event tap, ScreenCaptureKit, Shoji-owned windows, or the Dock process. |
| **NF** | Not feasible on macOS as far as current evidence shows. |
| **OOS** | Intentionally out of scope. |

Niri mechanisms used in the table: clip, transform, alpha, input region, frame
sync, offscreen render, capture, protocol. "Protocol" means Wayland client state.

## Capability map

### Layout and interaction ([NIRI_PARITY.md](NIRI_PARITY.md))

| # | Niri capability | Niri mechanism | macOS route | Class |
| --- | --- | --- | --- | --- |
| 1 | C01–C07: columns, camera, focus controls, gesture release, sizing, membership, pointer policy | Layout and protocol | AX plus layout logic [doc] | COV |
| 2 | P01: native sizing constraints | Protocol (configure/ack) | AX size negotiation [doc]. Op 0x12 `SetWindowLockedBounds` might stop apps fighting the layout [static]. | ALT |
| 3 | P02: coordinated resize and neighbor motion | Transform plus frame sync | Op 0x0f scales in-flight windows. Surface ops 0x33/0x35 (already gated) could hold the new size until the client binds it. Needs a per-frame
| 4 | P03: focus and camera edge cases | Layout | Logic, plus C2 receipts [live `receipt-20261105`] | COV (partial) |
| 5 | P04: focus ring | Compositor-drawn | Shoji-owned surfaces [live]. Staying aligned during motion depends on E2. | COV (partial) |
| 6 | P05: parent-aware dialogs and floating layer | Z-order and transient parent | 0x06 level (gated); 0x0c/0x0d sublevel; 0x59–0x5b ordering groups; 0x55–0x57 movement groups so children follow the parent [static]. Doc
| 7 | P06: fullscreen and maximize semantics | Protocol | AX `AXFullScreen` and zoom, plus layout [doc] | ALT |
| 8 | P07: measured responsiveness | Capture | ScreenCaptureKit and a frame analyzer [live `layout-frame-20261104`, harness removed; see Git history] | ALT |
| 9 | B01: viewport clipping and off-screen input exclusion | Clip plus input region | 0x2f `SetWindowClipShape`, 0x05 `GlobalClipShape`, 0x0b (gated), 0x45/0x46 `EventShape` [static]. An ordinary-controller clip failed 
| 10 | B02: inactive-tab concealment | Alpha plus input region | 0x03 alpha (gated), 0x0e system alpha, 0x45 empty event shape, or 0x01 order-out [static] | GATE |
| 11 | B03: coherent presentation and frame clock | Frame sync (redraw loop) | No frame-clock or vsync hook. The batch skips animation. The `sls_transaction_commit_ca` link has not been mapped. [static] | NEW |
| 12 | W01: drag to pan and drag to switch | Input | Event tap on modifier plus middle button | ALT |
| 13 | W02: interactive rearrangement with insertion hints | Input plus owned overlay | Event tap and owned hint [doc]. 0x67 `MoveWindowForServerSideDrag` and 0x7f `DragWindowRelativeToMouse` could intercept native drags
| 14 | W03: drag-and-drop edge scroll and hold-to-activate (also `dnd-edge-*` gestures) | Input | Observe pasteboard drags with an event tap | ALT |
| 15 | W04: tab controls | Owned UI | Indicators exist [doc]. Full concealment depends on #10. | COV (partial) |
| 16 | W05: dynamic workspaces, named workspaces, `empty-workspace-above-first` | Offscreen and hide | Native route: 0x18/0x19/0x21/0x22/0x2a (gated), 0x27, 0x28, 0x79 [static]; Dock create and destroy [doc]. Logical rou
| 17 | W06: workspace navigation and vertical switch animation | Transform | 0x1c `SetSpaceTransform`, 0x20 `SetSpaceAlpha`, 0x2b `SetManagedDisplayIsAnimating`. None are gated or issued. [static] | GATE |
| 18 | W07: overview (zoom, backdrop, workspace shadow) | Transform, offscreen render, input mapping | 0x0f per window or 0x1c per Space [static]. Dock `Window_Scale` (direct SLS call) [doc]. Capture fallback via SCK or 
| 19 | W08: overview rearrangement | Same as #18 plus Spaces | Depends on #16 and #18 | GATE |
| 20 | W09: unmodified 3- and 4-finger gestures | Input (libinput) | Dock gesture handlers or MultitouchSupport. 0x2c `SetEventCapture` has unknown semantics [static]. | ALT |
| 21 | W10: per-monitor ownership and hotplug | Output management | 0x89–0x8b `SynchronousDisplayReconfig` could hold a reconfiguration until Shoji has re-laid out; 0x42; 0x85 [static] | GATE |
| 22 | V01: double-click edge resize shortcuts | Input | Event tap | ALT |
| 23 | V02: border, gradients, insert hint, tab indicator styling | Compositor-drawn | Shoji-owned surfaces. Gradients and draw-border-with-background are missing. | ALT |
| 24 | V03: rules, IPC event stream, automation | Config and IPC | Shoji rules, signals and IPC [doc]. Expressiveness not yet audited. | COV (partial) |
| 25 | V04: overview touchscreen interaction | Touch | No touchscreen on Mac | OOS |

### Animations (Configuration: Animations)

| # | Niri capability | Niri mechanism | macOS route | Class |
| --- | --- | --- | --- | --- |
| 26 | `window-open` | Transform plus alpha on the first frame | The ordering hook already holds a window's first show [live]. Add 0x0f and 0x03 from the Dock connection in the same held commit. [static] | GATE |
| 27 | `window-close` | Keep the last buffer as a snapshot | Needs a hold point before the backing is released. Window destroy is not hooked. 0x09 `ReleasesBackingOnOrderOut` is related [static]. | NEW |
| 28 | `horizontal-view-movement`, `window-movement` | Frame-synced transforms | `LayoutBegin`/`Add`/`Arm` exist, but Shoji excludes animated frames (`layout_batch_eligible`) and caps the batch at 8 | GATE |
| 29 | `window-resize` | Snapshot crossfade plus shader | Owned proxy and resize-fade content blend [doc] | COV (approximation) |
| 30 | Synchronized animations (wait for the client's commit) | Wayland transactions | Hold geometry until surface bind 0x33/0x35 (both gated). Needs a window↔surface link and a command. [static] | GATE |
| 31 | `custom-shader` (open, close, resize) | GLSL on live buffers | Live: none. Proxy-only with Metal. 0x11 `SetWindowWarp` gives mesh distortion only [static]. | NF |
| 32 | Config notification, exit confirmation, screenshot UI, hotkey overlay, recent-windows close | Compositor UI | Shoji-owned windows | ALT |

### Layout config (Configuration: Layout)

| # | Niri capability | Niri mechanism | macOS route | Class |
| --- | --- | --- | --- | --- |
| 33 | Gaps, struts, centering, presets, default column display, fractional layout | Layout | Logic [doc] | COV |
| 34 | `background-color` and `backdrop-color` (workspace and output) | Compositor-drawn | Owned desktop-level window | ALT |
| 35 | `shadow` (layout and per-rule) | Compositor-drawn | 0x48 `SetWindowShadowProperties`, 0x71 system shadow, 0x49, 0x53 [static]. Dock `Window_Shadow` is on/off only [doc]. | GATE |

### Window rules (Configuration: Window Rules)

| # | Niri capability | Niri mechanism | macOS route | Class |
| --- | --- | --- | --- | --- |
| 36 | Matching: title, app-id, is-active, is-focused, is-active-in-column, is-floating, at-startup | Protocol | AX and NSWorkspace [doc] | COV |
| 37 | `is-urgent` | Protocol (xdg-activation) | Dock tile attention state, through the Dock payload or AX. Unverified. | ALT |
| 38 | `is-window-cast-target` and indicating screencast windows | Capture-session state | No capture-session observer. Semantics of 0x7c/0x7d `CaptureGroup` unknown [static]. | NEW |
| 39 | Opening properties: open-on-output/workspace, open-maximized(-to-edges), open-fullscreen, open-floating, open-focused, default width and height, size overrides, `default-floating-position` | Layout and protocol | 
| 40 | `opacity` | Alpha | Dock `Window_Opacity`; `active_window_opacity` and `normal_window_opacity` settings [doc] | COV |
| 41 | `geometry-corner-radius` | Clip | 0x69–0x6f corner radius and radii, 0x6b system radius, 0x4a corner mask [static] | GATE |
| 42 | `clip-to-geometry` | Clip | 0x2f plus the radius ops; shares #9 | GATE |
| 43 | `block-out-from` (screencast and screen-capture) | Capture | Candidates: 0x08 `SetWindowProperty` and 0x76 `SetWindowTags` for a sharing bit [static]. Unverified. | GATE |
| 44 | `background-effect` (blur and xray) and global `blur` | Offscreen render | Owned backdrop window. 0x86 `ContentBlurRadius` blurs the window's own content, not what is behind it [static]. | ALT |
| 45 | `variable-refresh-rate` | Output | ProMotion is system-managed. No per-window control is known. | NF |
| 46 | `scroll-factor` | Input | Event-tap scaling | ALT |
| 47 | `tiled-state` | Protocol | AppKit has no "tiled" state. Radius and shadow could approximate it (#35, #41). | NF |
| 48 | `baba-is-float` | Transform | Novelty | OOS |
| 49 | `popups` (apply rules to popups) | Surface tree | Find child windows, then apply 0x03 or 0x69; 0x59 ordering groups [static] | GATE |
| 50 | `draw-border-with-background` | Compositor-drawn | Owned surfaces | ALT |

### Other pages

| # | Niri capability | Niri mechanism | macOS route | Class |
| --- | --- | --- | --- | --- |
| 51 | Layer-shell components and layer rules | Layer-shell | Third-party macOS apps; `external_bar` reserves space for a bar [doc] | OOS |
| 52 | Outputs: mode, modeline, scale, transform, position, off | DRM | Handled by System Settings | OOS |
| 53 | `hot-corners` (outputs and gestures) | Input | Event tap. Conflicts with macOS hot corners. | ALT |
| 54 | Per-output layout overrides, `focus-at-startup` | Layout | Logic | ALT |
| 55 | `focus-follows-mouse`, `warp-mouse-to-focus`, `workspace-auto-back-and-forth`, mod key | Input | `focus_follows_mouse` and `mouse_follows_focus` exist [doc]. Back-and-forth not audited. | COV (partial) |
| 56 | Key bindings and hotkey overlay | Input | Hammerspoon, by design | OOS |
| 57 | Cursor `hide-when-typing` and `hide-after-inactive-ms` | Cursor plane | A private SLS connection property, not the payload [static] | ALT |
| 58 | Screenshots (UI, window, screen, path) | Capture | ScreenCaptureKit | ALT |
| 59 | Dynamic screencast target | Capture | ScreenCaptureKit plus a virtual camera or display extension | ALT |
| 60 | Windowed (fake) fullscreen | Protocol | No way to tell an app it is fullscreen while tiled | NF |
| 61 | Screen mirroring | Output | Native macOS feature | OOS |
| 62 | Recent-windows switcher with previews | Capture plus owned UI | Owned window plus `SLSHWCaptureWindowList` or ScreenCaptureKit | ALT |
| 63 | IPC event stream | IPC | Shoji IPC and signals [doc] | COV (partial) |
| 64 | Switch events (lid, tablet mode) | libinput | IOKit notifications | ALT |
| 65 | Keyboard layout and repeat, Num Lock, clipboard primary, `prefer-no-csd`, Xwayland, Nvidia, systemd, power key | System | Belongs to the system | OOS |
| 66 | Accessibility of compositor UI | AT-SPI | AX on Shoji-owned UI | ALT |

**Counts (66 rows):** COV 12, GATE 17, NEW 3, ALT 23, NF 4, OOS 7.

## Top gaps by Niri-experience value

1. **Per-frame motion batch (#3, #28, #11).** Smoothness is the main complaint
   in user acceptance. The gate can already apply moves atomically, but Shoji
   never uses it during animation.
2. **Foreign clip, alpha and event shape (#9, #10, #42).** These decide whether
   a viewport strip is clean, whether tabs are truly hidden, and whether
   off-screen windows can receive clicks. The ops are in the table, but none can
   be issued.
3. **Transform op (#17, #18, #26).** Unlocks the overview, vertical workspace
   slides and the open animation. Whether input maps through a transform is
   unknown.
4. **Frame clock and synchronized resize (#11, #30).** Niri commits frames on
   vsync and waits for clients. Shoji has no frame-clock hook, and its
   surface-bind correlation is unused.
5. **Window-close snapshot (#27).** No hold point before teardown has been
   mapped.

## Proposed phases

The tables follow the style of `PLAN.md` (in git history). Phases are ordered by
Niri-experience value. Each command must:
- be exact-build gated;
- fail open on its deadline;
- be journaled for restoration;
- degrade per feature, as C4 does.

**Prerequisite:** port and verify each target build with
`spelunker-port build`. Ops and offsets must not be carried across
builds.

### Phase E: presentation primitives

| # | Task | Acceptance |
| --- | --- | --- |
| E1 | **Partly done 2026-11-07:** `Capabilities` reports features and the layout item limit; build UUID and gated ops are not reported yet. **Capabilities handshake.** The WindowServer payload reports build UUID, gated ops, supported commands and limits. This replaces `Load_Probe`-only (`protocol.odin:12`). Merge it with Dock capabilities and enable o
| E2 | **In progress 2026-11-07:** scroll-camera frames batch through `LayoutSubmit` (32 moves, one message); window and ring animations still use per-window writes. **Per-frame motion batch.** The motion tick sends camera, window and owned-ring moves through one `LayoutArm` per display frame. Raise `LAYOUT_LIMIT` with a bounded plan. Keep the hold at or under one frame. | The
| E3 | **Foreign-op commands.** Add alpha (0x03/0x0e), clip (0x2f/0x05), shape (0x0b), event shape (0x45) and transform (0x0f). They are issued as Dock-connection transactions, staged inside the gated commit, with a rest
| E4 | **Viewport clipping (B01)** using E3 | Checklist B01 passes on one display and on two physical displays. |
| E5 | **In progress 2026-11-07:** `tab_conceal on` conceals inactive tabs through the Dock payload (`Window_Conceal`); the payload reveals them if the concealing daemon exits. Not yet journaled across a Dock restart. **True tab concealment (B02)** using E3 | Checklist B02 passes, including restoration after interruption. |
| E6 | **Dialog and floating relationships (P05)**: level, sublevel, ordering groups (0x59–0x5b) and movement groups (0x55–0x57) | Sheets, modals and popovers follow their owner during E2 motion and are never hidden behi

### Phase F: synchronization

| # | Task | Acceptance |
| --- | --- | --- |
| F1 | **Locate the frame clock**: vsync or display-link handling, and the `sls_transaction_commit_ca` path. Align E2 commits with it. This is a new hook family. | Commit-to-present latency is measured and stays at or un
| F2 | **Synchronized resize.** Link each window to its surface. Hold the geometry ops until 0x33/0x35 binds the new size, with a bounded timeout. | During a resize spring, no captured frame shows content mismatched with
| F3 | **Open and close animations.** Open: hold the first show, then apply transform and alpha. Close: find a hold point before backing release, which is new, and snapshot into a proxy there. | No first-frame flash on o

### Phase G: workspaces and overview

| # | Task | Acceptance |
| --- | --- | --- |
| G1 | **Dynamic workspaces.** Choose logical workspaces (hidden via E5) or native Spaces (0x18/0x19/0x21/0x22/0x2a). Animate vertical switches with 0x1c/0x20. | Checklist W05 and W06 pass. Native Spaces state survives a
| G2 | **Overview.** Live transforms via 0x0f or 0x1c, with a capture-thumbnail fallback. Input either maps through the transform or goes through an owned proxy. | Checklist W07 and W08 pass. Whether input lines up with 
| G3 | **Display reconfiguration.** Use 0x89–0x8b so Shoji re-lays out before the change is presented. | Checklist W10 passes with physical hotplug. |

### Phase H: polish and privacy

| # | Task | Acceptance |
| --- | --- | --- |
| H1 | Corner radius, `clip-to-geometry` and shadow parameters (0x69–0x6f, 0x4a, 0x48, 0x71) | Rule changes apply live and restore on exit. |
| H2 | Block-out-from-capture (investigate 0x08/0x76). Detect cast targets (new). | A capture shows the blocked window as black or excluded. Otherwise record a negative result. |
| H3 | Recent-windows switcher and screenshot UI with owned windows and capture | Feature parity checks are documented. |

## Open questions that need live tests

1. Do Dock-connection *transactions* that set alpha, clip, event shape,
   transform or corner radius take effect on foreign windows on 26B123?
   **Partly answered 2026-11-07 (live, Mail):** system alpha 0 plus an empty
   event shape in one Dock transaction hides the window and lets clicks
   through; alpha alone leaves it catching clicks. Reveal (alpha 1, event
   shape = window rectangle) restores drawing and input in place. Clip,
   transform and corner radius are still open.
2. Does a 0x0f window transform also transform hit-testing?
3. Can holds of 2 ms or less at 120 Hz run continuously without visibly
   stalling other clients? WindowServer serializes globally while holding (B2).
4. Do apps reassert their own event shape or clip shape when they redraw?
5. Does the order-out path through the inline hook happen before the backing is
   released? This decides whether close snapshots are possible.
6. Do 0x33/0x35 surface binds line up with resize commits for apps backed by
   CoreAnimation (AppKit, Chrome, Ghostty)?
7. Do 0x08/0x76 control screen-capture exclusion?
8. Does 0x1c on the current Space animate a whole workspace without corrupting
   Mission Control or Dock state?
9. Does 0x7a `SetWindowIsActiveOffscreen` keep off-screen windows live for
   overview thumbnails?
10. Do op numbers and handlers survive the next macOS build? Check with
    `spelunker-port diff` before reusing anything.

## Presentation signals

Research from 2026-10-28 (24G84), before the gate existed. It still bounds what
public APIs can confirm.

| Signal | What it means | Limit for Shoji |
| --- | --- | --- |
| `CADisplayLink.targetTimestamp` | Predicted time of the next display frame, for scheduling. | A deadline, not confirmation that a foreign app's AX move appeared. Shoji already paces to the display. |
| AX moved/resized notifications | An element's position changed; `kAXWindowMovedNotification` fires at the end of a move. | Not per-frame compositing acknowledgments; coalescing and latency vary per app. |
| `SLSGetWindowBounds` | Private bounds readback. | Can lag the model by a motion step; not displayed pixels. |
| `SCStreamFrameInfo.displayTime` | WindowServer display time of a captured frame (Mach time). | After-the-fact capture metadata; filtered capture can omit frames. Record raw value, frame status and timebase, and correlate clocks before computing latency. |
| `MTLDrawable.presentedTime` | Presentation time of a drawable the caller owns. | Only for Shoji-owned Metal drawables, not foreign windows. |

Yabai batches `SLSTransactionSetWindowTransform` on its own proxy windows and
commits them together. That shows coordinated proxy presentation, not a
verified ABI for transforming foreign windows or proof that input follows the
transform. Transaction grouping is not scanout atomicity without frame
evidence; the gate's ScreenCaptureKit measurements are that evidence for the
ordering channel.
