# External compositor controls on macOS

Research date: 2026-10-25. Target: macOS 15.6 (24G84), Apple Silicon.

Follow-up: [Niri-style Shoji feasibility](docs/NIRI_MACOS_FEASIBILITY.md) maps the user experience to Shoji's layout/backend and the clipping/input experiment. [Niri feature research](docs/NIRI_FEATURE_RESEARCH.md) records upstream behavior. An opt-in [scrolling layout preview](docs/SCROLL_LAYOUT.md) is now implemented, using native positioning and the existing proxy animation backend; it is not an external compositor and still needs live acceptance.

## Finding

Runtime update: [the isolated 15.6 clipping experiment](docs/COMPOSITOR_PROBE_RESULTS.md) now verifies clipping and sampled input routing in the owning process, while the same setter called from a separate ordinary controller leaves the foreign window unchanged. A zero setter return is insufficient. General external clipping remains unresolved; the specific direct call tested is unsuccessful.

SkyLight already exposes functions for clipping, transforming, hiding and ordering windows. That makes a focused experiment worthwhile. It does **not** establish that an ordinary Shoji process can apply them to another application's windows with SIP enabled. We found no primary-source demonstration of a complete external compositor with that authority on macOS 15.6.

The practical direction is a capability-tested window-management backend, not modifying Apple's compositor. Use Accessibility for established operations, and investigate individual private controls against disposable windows before incorporating them. Cross-process clipping is the main unresolved capability for a clean Niri-style viewport.

This investigation changed no window state, Dock state, security settings or installed software. The local probe only loaded the framework and looked up symbols; it called no window-management functions.

## What was established locally

A `dlopen`/`dlsym` probe against `/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight` on the target machine found these exported names:

| Group | Names found |
| --- | --- |
| Shape and effects | `SLSSetWindowClipShape`, `SLSSetWindowShape`, `SLSSetWindowTransform`, `SLSSetWindowTransforms`, `SLSSetWindowWarp`, `SLSSetWindowAlpha` |
| Ordering | `SLSTransactionSetWindowSystemAlpha`, `SLSSetWindowSubLevel`, `SLSOrderWindow` |
| Ownership and workspaces | `SLSGetWindowOwner`, `SLSSetWindowListWorkspace`, `SLSSpaceSetCompatID`, `SLSMoveWindowsToManagedSpace`, `SLSCopyManagedDisplaySpaces` |
| Other candidates | `SLSWindowManagementBridgeSetDelegate`, `SLSNewWindowWithOpaqueShapeAndContext`, `SLSTransactionSetWindowTransform` |

`SLSPerformAsynchronousBridgedWindowManagementOperation` and `SLSGetConnectionPortById` were not found under those plain exported names. This says nothing about local, mangled or hidden implementations.

Following the pinned upstream implementation, a second read-only probe inspected SkyLight's mapped Mach-O symbol table. It **found the exact local function symbol** `__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation` on 15.6 (24G84). `objc_getClass` also found the registered `SLSBridgedMoveWindowsToManagedSpaceOperation` class. No operation was instantiated or invoked. This establishes a concrete target-specific candidate for external Space movement, not working behavior, a validated calling convention, or authorization. Temporary source: `/tmp/shoji-skylight-hidden.c`; compiled with `/usr/bin/clang -Wall -Wextra -Werror … -lobjc`. The probe only traverses dyld image/load-command/symbol metadata and queries the class registry.

The temporary probe source is `/tmp/shoji-skylight-symbols.c`. To reproduce the method, compile a small C program that opens that framework, iterates the names above, prints only whether `dlsym` returns non-null, and closes the handle. Do not invoke the resulting function pointers. A symbol lookup verifies availability only: not its ABI, its semantics, its permissions or successful behavior.

The local `csrutil status` reports a custom configuration with filesystem, debugging, NVRAM and boot-argument restrictions disabled; authenticated root and kernel integrity protections are enabled. Consequently, this machine's current session cannot establish **fully SIP-enabled** behavior.

## Why ownership matters

The historical reverse-engineered CGS headers document window ownership restrictions and a privileged “universal owner” connection associated with Dock. They also list shape, clip, transform, alpha and ordering operations. This is useful evidence of the architecture, but those headers date from older OS releases and are not Apple's API contract for Sequoia. Their `CGSSetWindowClipShape` declaration takes a window ID and region, without the connection argument used by many neighboring APIs: do not guess the current SLS signature from its name. [CGSWindow.h](https://github.com/NUIKit/CGSInternal/blob/master/CGSWindow.h), [CGSConnection.h](https://github.com/NUIKit/CGSInternal/blob/master/CGSConnection.h)

Current yabai source separates ordinary window movement and resizing through Accessibility from effects performed inside its injected Dock payload. Its payload applies transforms, alpha, sublevels and ordering to target windows using Dock's main connection. That is concrete evidence that calling the same function from an ordinary client is not an equivalent execution context; it is not proof that every alternative external route is impossible. [Accessibility movement and resizing](https://github.com/asmvik/yabai/blob/master/src/window_manager.c), [Dock payload](https://github.com/asmvik/yabai/blob/master/src/osax/payload.m)

Shoji has the same relevant split: its animation code creates and transforms its own proxy windows, while the addition applies effects to other applications' real windows. Transforming a Shoji-owned image does not demonstrate control of Chrome or Ghostty's native surface. See [motion.odin](src/motion.odin) and [addition windows implementation](src/addition/payload/payload_darwin.odin).

A window ID or another process's connection number is an identifier, not evidence of an authorized connection. Accessibility trust, Screen Recording consent, root privileges and private WindowServer authority must be tested separately rather than treated as interchangeable. Apple documents that SIP blocks attaching to protected processes even as root, so injection or patching is not a SIP-compatible workaround. [Apple runtime protections](https://developer.apple.com/library/archive/documentation/Security/Conceptual/System_Integrity_Protection_Guide/RuntimeProtections/RuntimeProtections.html)

## Capability assessment

“Unproven” below means neither this research nor the local symbol probe established successful cross-process behavior on 15.6 with SIP fully enabled.

| Required capability | Evidence and feasibility for Shoji |
| --- | --- |
| Move and resize real application windows | Established Accessibility route, subject to the app supporting the relevant attributes. Apple exposes attribute-settable queries and explicit failure results. [Set attribute](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue), [Query support](https://developer.apple.com/documentation/applicationservices/1459972-axuielementisattributesettable) |
| Scroll a strip by moving real windows | Existing implementations establish feasibility with compromises. PaperWM documents visible edge margins and advises vertical monitor arrangement. [PaperWM limitations](https://github.com/mogenson/PaperWM.spoon#limitations) |
| Keep windows entirely outside the viewport | Paneru documents retaining thin visible slivers to avoid macOS relocating fully off-screen windows. Adjacent horizontal displays cause additional problems. This is direct evidence against assuming unrestricted off-screen placement through ordinary movement. [Paneru](https://github.com/karinushka/paneru#recommended-system-options) |
| Clip another app's native window to a viewport | Private symbol exists locally; cross-owner permission, current ABI, interaction shape, shadow clipping and restoration remain unproven. Highest-value narrow research candidate. |
| Transform another app's native window | Symbol exists locally; injected implementation exists, ordinary-process authority remains unproven. Test rendering and input alignment separately. |
| Set arbitrary layer/sublevel or order out another app's window | Symbols exist locally; Shoji currently uses privileged addition for these effects. Ordinary AX raise is a separate operation and does not prove arbitrary persistent layering. |
| Draw custom clipped/animated copies | Feasible as a separate rendering path. Apple's ScreenCaptureKit captures window content; it does not transfer native input, focus or ownership into Shoji. [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) |
| Expose new compositor commands by injecting or patching protected Apple code | Conflicts with the SIP-enabled objective; unsupported system modification adds a separate maintenance and recovery problem. |

Paneru's configuration documentation explicitly describes limited layering control and resulting visual issues while SIP remains enabled. Its overlays and borders do not demonstrate unrestricted composition of other apps' native windows. [Paneru experimental features](https://github.com/karinushka/paneru/blob/main/CONFIGURATION.md#7-experimental-features)

## Spaces: an important version-specific correction

Hammerspoon's source contains a post-Sonoma-14.5 compatibility-ID path using `SLSSpaceSetCompatID` and `SLSSetWindowListWorkspace`. Its wrapper returns true without verifying subsequent Space membership. The source alone therefore cannot establish that the move occurred. [Hammerspoon implementation](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/spaces/libspaces.m)

More directly, the upstream Sequoia issue reports true being returned while the window stays in place; this includes macOS 15.0.1 reports. An earlier report describes only Hammerspoon's own console moving. These are first-hand failure reports, not a controlled 15.6 test, but they rule out presenting this path as already reliable on the user's target. [Sequoia issue #3698](https://github.com/Hammerspoon/hammerspoon/issues/3698), [Earlier issue #3666](https://github.com/Hammerspoon/hammerspoon/issues/3666)

There is a newer, promising external route. Yabai's maintainer confirms SIP-enabled window-to-Space movement on **Tahoe 26.4**, and the issue also cites validation on 26.4.1. That evidence is for a different OS, not Sequoia 15.6. [Upstream issue #2788](https://github.com/asmvik/yabai/issues/2788)

The corresponding commit constructs `SLSBridgedMoveWindowsToManagedSpaceOperation`, initializes it with window IDs and a Space ID, then invokes `SLSPerformAsynchronousBridgedWindowManagementOperation`. It resolves the latter through its mangled Mach-O symbol rather than a plain exported symbol. This explains why the target's negative `dlsym` result is inconclusive. It is a narrow Space-move operation, not evidence of general clipping or compositor authority. [Implementation commit ce798b7](https://github.com/asmvik/yabai/commit/ce798b7)

## Recommended next validation

Build a separate, explicitly invoked Odin diagnostic fixture before changing Shoji's backend. It should create one window owned by the diagnostic process and another owned by a separate disposable fixture process, with all effects limited to those IDs. Do not use Dock's connection or Shoji's scripting addition; otherwise a passing result would not answer the question.

1. Record the exact OS build, architecture, SIP state and caller identity. Run from the logged-in GUI session. Capture baseline bounds, ordering, transform, visibility and ownership, using only signatures established for the target.
2. Establish an owned-window positive control, then test the separately owned fixture window from the ordinary diagnostic process. Use one bounded operation at a time: clipping first, then transform, alpha and ordering. Log return values and independent state readback.
3. Check rendered output and hit-testing, not just return codes. Confirm that clipped portions stop receiving clicks, dialogs remain visible, shadows do not escape the viewport, and no adjacent display receives the hidden portion.
4. Use a separate restoration watchdog and fixture-process cleanup. Restore each operation immediately. Do not touch the user's Chrome/Ghostty windows, restart Dock, inject into a system process, modify Apple binaries or change security settings.
5. Any success on this machine's current custom SIP configuration is preliminary. Repeat on the same macOS build with SIP fully enabled in a separate test environment before claiming that capability. Report unsupported operations explicitly and retain AX fallbacks.

For Space movement, presence of the exact bridged-operation symbol and class is now established on 15.6; independently validate its ABI and behavior with two existing disposable user Spaces and a fixture window. Confirm actual membership afterward and allow for asynchronous completion. Do not infer success from symbol presence, a returned boolean, or behavior on Tahoe.

The implementation decision should follow those results: native clipping if cross-owner permission actually works; otherwise a scrolling layout with documented edge constraints, with capture-based rendering reserved for overviews or transitions. There is currently insufficient evidence to promise a fully native Niri compositor experience on Sequoia while preserving SIP.
