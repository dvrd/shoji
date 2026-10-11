# Port status

The request to port **all** yabai logic is not complete. This file is an explicit
inventory of what is implemented and what remains. A successful build or test
run must not be interpreted as feature parity.

Reference: asmvik/yabai `dd845723416f5fe92af49fad5ebab00369e07edd`.
Dock injection is all-Odin. On arm64, `shoji --load-sa` spawns `bin/shoji-loader`, an Odin arm64e companion built with the compiler patch in `tools/odin-arm64e.patch` (header normalized to arm64e ABI v0 before ad-hoc signing); the kernel refuses remote thread creation in the arm64e Dock from a plain arm64 process, so the companion is required — upstream yabai likewise uses a separate arm64e loader. Intel Shoji injects in-process. The former MIT-licensed Objective-C loader (`loader_arm64e.m`) was removed after the Odin loader passed live Dock injection on 2026-10-05 on macOS 15.6 / Apple M1 Max. See [the arm64e notes](tools/ARM64E.md).

## Implemented

| Area | Implementation | Remaining differences |
| --- | --- | --- |
| Project structure | Odin source, Taskfile, universal app/payload builds, checksum release archives, launchd management tool, CI workflow | Universal assembly requires Apple Silicon; CI has not been run remotely; no notarization or system-wide installer |
| BSP and stack | Add/remove, stack limits/MRU, transforms, balance/equalize, padding/gaps, zoom persistence through add/remove and BSP/stack rebuilds | Zoom is not retained through float layouts; directional selection lacks WindowServer z-order tie-breaking; precision uses f64 rather than upstream f32 |
| Configuration | Per-space override inheritance, layout/padding/gap/splits, axis auto-balance, placement/insertion, zoom, opacity/fades, animation/easing, external bars, display order/origin, shadows, feedback color and mouse settings | Menubar opacity, debug output and skip-window-focus-animation settings absent; upstream platform-specific defaults differ |
| Window commands | Cross-space swap/warp with compensating rollback, stack, scratchpad assignment/toggle/recover, explicit-opacity reset, automatic/manual sub-layers, focus, frame/grid/resize, native/windowed fullscreen, Expose, float/zoom, raise/lower, PiP/shadow, expanded selectors | Some selector edge cases remain; associated child-window layer propagation absent; windowed-fullscreen state is daemon-local |
| Space commands | Position-based move, same-display swap, cross-display window swap with compensation, switch/display, focus/create/destroy, layouts/transforms/labels | Multi-operation reorder failures can leave a partially reordered model; cross-display tree arrangements are rebuilt rather than exchanged; OS fullscreen workarounds remain |
| Display commands | Discovery, ordering, numeric/relative/recent/mouse/directional selectors, labels, focus through active-Space transport | Directional scoring differs from upstream; focus requires the payload rather than upstream fallback paths |
| Queries | Filtered/projected window/space/display JSON, escaped text, measured levels/sub-levels, shadow/sticky/opacity and AX capabilities | Full upstream metadata/schema compatibility is not certified |
| Rules | Regex/exclusions, labels/one-shot/manage, selective and inline reapply, display/space/follow, grid, opacity, sticky, fullscreen, sub-layer, scratchpad and mouse-follow effects | Listing selectors remain strings rather than upstream numeric indices/flags; manage/dialog matching and deferred rule retry differ; privileged effects require the payload |
| Signals | All accepted event names have producers, including workspace visibility, Mission Control, Dock, menu-bar, wake and display changes | Reconciliation and notification coalescing can omit intermediate transitions; live notification delivery is unverified |
| Applications/windows | NSWorkspace enumeration via `objc_send`; AX observer callbacks; reconciliation; references retained/released; AX focus/frame/minimize/close/fullscreen backend | Regular applications only, no enhanced-UI workaround, native-tab handling or upstream retry/suppression logic |
| Spaces/displays | SkyLight space enumeration, display UUIDs, current space, screen usable frame, reconciliation | Fullscreen/Mission Control transitions and OS-specific workarounds not fully ported |
| IPC | Unix-domain socket, exact reads/writes, framing validation, peer UID check, socket mode, timeout, process lock, client failure status | A slow client can hold the main loop for up to its socket timeout |
| Startup | CLI/foreground daemon, config discovery, signal cleanup, child reaping, signed builds, separate launchd lifecycle tool | No native upstream service CLI flags or automatic privileged payload reload after Dock restart |

Signal events currently emitted by reconciliation:

- `application_launched`, `application_terminated`, `application_front_switched`,
  `application_activated`, `application_deactivated`, `application_hidden`, `application_visible`.
- `window_created`, `window_destroyed`, `window_focused`, `window_moved`,
  `window_resized`, `window_minimized`, `window_deminimized`, `window_title_changed`.
- `space_created`, `space_destroyed`, `space_changed`.
- `display_added`, `display_removed`, `display_moved`, `display_resized`.
- `display_changed`, `mission_control_enter`, `mission_control_exit`,
  `dock_did_restart`, `dock_did_change_pref`, `menu_bar_hidden_changed`, `system_woke`
  through notification/Dock observation.

Event detection uses AX callbacks to trigger reconciliation plus a
one-second fallback; intermediate transitions can be coalesced. This differs
from yabai's event queue and notification processing.

## Unported upstream modules and paths

1. Scripting-addition packaging/installation and automatic reload after Dock restart.
   The Odin implementation loads a dylib directly through `--load-sa`.
2. Live validation of the private Dock ABI and arm64e interoperability. Signature
   coverage follows upstream tables, but no macOS release is certified yet.
3. Live validation of the new capture/proxy animation and insertion/drag feedback
   renderer. The animation scheduler/easing/restore retries and overlay lifecycle
   are implemented with injected backends tested locally; private rendering remains
   experimental. Animations default off and require Screen Recording plus the payload.
4. Upstream animation batching, captured-image alpha correction and crash recovery
   if Dock becomes unreachable while a real window is hidden behind a proxy. Failed
   restores are retried while the daemon runs and reported on shutdown; a forceful
   termination cannot guarantee restoration. Feedback uses square, not rounded, outlines.
5. Full upstream Mission Control/fullscreen transition handling and native-tab,
   enhanced-UI, retry/suppression and associated-window workarounds.
6. Remaining `message.c`, manager, query, rule, signal, service, and platform
   compatibility behavior described in the table above.

## Mouse implementation

`src/engine/mouse.odin` handles global settings, anchored resize geometry, ancestor
split selection and cross-Space drop mutations. `src/macos/mouse_darwin.odin` owns
the session event tap and click replay; it coalesces drag points for processing
outside the callback. `autoraise` uses Accessibility; `autofocus` uses the Dock
focus handler. Mouse follows focus avoids warping after a hover-driven focus.
Insertion and drag feedback plans are rendered using daemon-owned click-through
windows. Mission Control suspends layout/input updates. Horizontal Dock swipe
events suppress tiling, focus-following and previews until 250 ms after the gesture
ends; this fixed settling interval is not upstream's complete suppression logic.

Live input behavior is unverified. Tests cover configuration rejection, every
resize handle, opposite-edge preservation, BSP resizing, drop geometry/stacking,
backend failure propagation, cross-Space drops, preview geometry/ownership,
gesture settling and synthetic callback capture/release without
posting events to macOS.

## Dock implementation

`src/addition/loader` implements Mach allocation/protection, remote thread creation,
arm64 thread-state conversion, pointer signing, pthread bootstrap and completion
tracking. The worker detaches itself and publishes completion; after the entry thread
terminates, data and its stack are reclaimed. The copied code stays mapped because
the worker may still be returning through it. Uncertain timeout/failure paths
retain all buffers to prevent use-after-free.
`__shoji_boot` contains compiler-generated Odin code, not copied assembly blobs.

`src/addition/payload` implements all 19 upstream operation families with a
Shoji-specific versioned protocol, bounded reads, statuses and main-thread Dock
operations. Fades run on the main queue rather than using upstream's worker/barrier
scheme. `patterns` preserves architecture/version tables; `bridge` uses native Odin
assembly templates for x20/r13 Swift context and arm64 PAC instructions.

The existing backend routes supported privileged commands to this payload.
Unsupported private signatures produce errors. There is no claim of complete
upstream command or animation parity.

## Validation

Tests cover tree invariants after 1,000 deterministic mutations, upstream split
rounding, reversible transforms, mirror ratio semantics, stack MRU insertion,
zoom-reference cleanup, configuration, layout transitions, backend failure
propagation, JSON escaping, selectors, rule exclusions/one-shot behavior, POSIX
character classes, malformed messages, native Objective-C/CoreFoundation calls,
fragmented socket writes, daemon error framing and successful query transport.
Dock tests cover truncated/oversized protocol messages, handshake versions,
wildcard scans, ADRP decoding, upstream pattern syntax, x20/r13 receiver passing,
bootstrap section placement and executing its worker after relocation. A separate
build test checks both bootstrap disassemblies for external PC-relative references.

Odin's test allocator tracks allocations and reports leaks/bad frees. Native
framework/libSystem allocations are outside that allocator's accounting.

The expanded suite also covers per-Space override inheritance, Space position
moves/swaps, compensating rollback, property projection, scratchpad recovery,
expanded rule effects, explicit-opacity/layer reset, zoom persistence, external
bar/display-origin settings, workspace event emission, Mission Control and gesture
suppression, all 22 easing curves, animation restore retries, and feedback geometry
and resource ownership. Python tests exercise service lifecycle with an injected
launchctl and release archive contents/checksums. They do not install a service.

The original in-process Odin loader failed with `cannot start remote thread (2)`
on macOS 15.6 because its thread state was unsigned. Signing the PC/SP with
Darwin's thread-state discriminators and converting the state through
`thread_convert_thread_state` fixed that for an arm64e caller, and the arm64e
Odin loader passed live Dock injection on 2026-10-05; the Objective-C loader used
while it matured was then removed and the Odin loader became the default
companion. A 2026-10-10 attempt to drop the companion and inject in-process from
the plain arm64 executable reproduced the kernel rejection
(`KERN_PROTECTION_FAILURE` from `thread_create_running` even with a signed,
converted state), so the arm64e companion is architecturally required on arm64;
the same-day live run through the spawned Odin loader confirmed the final
architecture. The injector self-test in `task test` performs the full
remote-thread/pthread/`dlopen` sequence against the test process on both
architectures (amd64 under Rosetta); it also exposed and led to removal of an
invalid `pthread_join` call from a raw Mach thread.

Accessibility permission was granted on the test machine after the initial
validation: `bin/shoji --inspect`, daemon startup, and payload-backed Space and
window operations were verified live on 2026-10-05. Launchd installation and
live mouse event-tap behavior remain unverified.
