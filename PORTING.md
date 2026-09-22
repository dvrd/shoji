# Port status

The request to port **all** yabai logic is not complete. This file is an explicit
inventory of what is implemented and what remains. A successful build or test
run must not be interpreted as feature parity.

Reference: asmvik/yabai `dd845723416f5fe92af49fad5ebab00369e07edd`.
Upstream contains 16,201 lines in its top-level source modules, plus approximately
3,964 lines in `src/misc/` and `src/osax/`. Its source was inspected from a temporary
checkout; no upstream C or Objective-C source is compiled or vendored here.

## Implemented

| Area | Implementation | Remaining differences |
| --- | --- | --- |
| Project structure | Odin source under `src/`, tests under `tests/`, Taskfile, `bin/`, OLS/odinfmt configuration | No release packaging, installer, CI or universal-binary target |
| BSP and stack | Add/remove, 32-window stack limit, MRU ordering, splitting, traversal, swap, rotate, mirror, balance, equalize, padding/gaps, zoom | No zoom persistence across structural edits; directional selection lacks WindowServer z-order tie-breaking; precision uses f64 rather than upstream f32 |
| Configuration | Layout, gap, four padding values, split ratio/type, placement, auto-balance on/off, per-space selection | Many settings absent; global writes overwrite per-space values rather than preserving upstream override flags; directional auto-balance absent |
| Window commands | Focus, close, minimize/deminimize, native fullscreen, float/split/zoom toggles, same-space swap/warp/stack, ratio, directional/stack insertion, floating move/grid, full resize handles and BSP fences, raise/lower, PiP/shadow toggles, area/family/indexed-stack selectors | Cross-space swap/warp, scratchpads, mouse warp, and some selector edge cases remain |
| Space commands | Layout, rotate, mirror, balance/equalize, padding/gap, label; Dock focus/create/destroy/move transport | Move uses the payload’s insert-after primitive; full upstream reorder/swap semantics remain |
| Display commands | Discovery, numeric/first/last/next/prev selection, labels | Directional display selection and actual display focus absent |
| Queries | Window/space/display JSON with window/space/display filters and escaped text | Property projection and complete metadata absent; level and sub-level fields are defaults rather than measured state; shadow/sticky/opacity and AX move/resize capabilities are read from macOS |
| Rules | POSIX extended regex for app/title/role/subrole, exclusions, labels, one-shot, manage, add/remove/list/apply | Space effects require the loaded payload; selective reapply and other effects absent; listing schema differs from upstream |
| Signals | Add/remove/list, labels, app/title regex, active filter, shell actions with `YABAI_*` environment values | Only events listed below are emitted; application visibility, Mission Control, Dock, menu-bar and wake notifications remain |
| Applications/windows | NSWorkspace enumeration via `objc_send`; AX observer callbacks; reconciliation; references retained/released; AX focus/frame/minimize/close/fullscreen backend | Regular applications only, no enhanced-UI workaround, native-tab handling or upstream retry/suppression logic |
| Spaces/displays | SkyLight space enumeration, display UUIDs, current space, screen usable frame, reconciliation | Fullscreen/Mission Control transitions and OS-specific workarounds not fully ported |
| IPC | Unix-domain socket, exact reads/writes, framing validation, peer UID check, socket mode, timeout, process lock, client failure status | A slow client can hold the main loop for up to its socket timeout |
| Startup | CLI, foreground daemon, config discovery/execution, SIGINT/SIGTERM cleanup, child reaping | launchd service management, code-signing tasks and other upstream startup options absent |

Signal events currently emitted by reconciliation:

- `application_launched`, `application_terminated`, `application_front_switched`,
  `application_activated`, `application_deactivated`.
- `window_created`, `window_destroyed`, `window_focused`, `window_moved`,
  `window_resized`, `window_minimized`, `window_deminimized`, `window_title_changed`.
- `space_created`, `space_destroyed`, `space_changed`.
- `display_added`, `display_removed`, `display_moved`, `display_resized`.

The other upstream event names are recognized by the parser but are not yet
produced. Event detection uses AX callbacks to trigger reconciliation plus a
one-second fallback; intermediate transitions can be coalesced. This differs
from yabai's event queue and notification processing.

## Unported upstream modules and paths

1. Scripting-addition packaging/installation and automatic reload after Dock restart.
   The Odin implementation loads a dylib directly through `--load-sa`.
2. Live validation of the private Dock ABI and arm64e interoperability. Signature
   coverage follows upstream tables, but no macOS release is certified yet.
3. Daemon-side animation rendering and additional commands using the payload's
   fade and proxy handlers. Ordering, autofocus and scaling now have callers.
4. Mouse cross-Space drops, drag previews, gesture suppression and Mission Control
   handling. Session event taps, focus follows mouse, mouse follows focus,
   floating drags, BSP resizing and same-Space drop actions are implemented.
5. Window proxy rendering, easing, capture/animation, insert feedback and shadow
   handling in `view.c`, `window.c`, and `window_manager.c`.
6. `mission_control.c` and workspace notifications: Mission Control suspension,
   Dock restart/preference changes, system wake, menu-bar changes.
7. Remaining `message.c`, manager, query, rule, signal, service, and platform
   compatibility behavior described in the table above.

## Mouse implementation

`src/engine/mouse.odin` handles global settings, anchored resize geometry, ancestor
split selection and same-Space drop mutations. `src/macos/mouse_darwin.odin` owns
the session event tap and click replay; it coalesces drag points for processing
outside the callback. `autoraise` uses Accessibility; `autofocus` uses the Dock
focus handler. Mouse follows focus avoids warping after a hover-driven focus.

Live input behavior is unverified. Tests cover configuration rejection, every
resize handle, opposite-edge preservation, BSP resizing, drop geometry/stacking,
backend failure propagation and synthetic callback capture/release without
posting events to macOS.

## Dock implementation

`src/addition/loader` implements Mach allocation/protection, remote thread creation,
arm64 thread-state conversion, pointer signing, pthread bootstrap and completion
tracking. Remote buffers are reclaimed only after the worker joins and the entry
thread terminates; uncertain timeout/failure paths retain memory to prevent use-after-free.
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

The live loader failed with `cannot start remote thread (2)` on macOS 15.6.
The failure occurs after thread-state conversion; diagnosis remains open while
the user handles live injection testing. No loader change was made during the
mouse/window-command port.

Live Accessibility behavior has not been verified: `bin/shoji --inspect` returned
an explicit missing-permission error. No Dock injection, permission changes,
launchd installation, or desktop window mutation was performed during validation.
