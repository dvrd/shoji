# Spaces with System Integrity Protection enabled

Research date: 2026-10-25. Validation target: macOS 15.6 (24G84), Apple Silicon. This is source research and a proposed implementation direction, not a SIP-enabled runtime certification. No GUI actions, Dock restart, service changes, or security-setting changes were performed.

## Finding

Follow-up research narrowed the window-movement claim below: Hammerspoon has reports of returning success without moving windows on Sequoia 15, while upstream's newer SIP-enabled bridged movement is confirmed on Tahoe 26.4, not this project's 15.6 target. Treat direct window-to-Space movement on 15.6 as unresolved. See [external compositor investigation](EXTERNAL_COMPOSITOR.md), [Hammerspoon issue #3698](https://github.com/Hammerspoon/hammerspoon/issues/3698), and [upstream issue #2788](https://github.com/asmvik/yabai/issues/2788).

A subsequent read-only scan found the newer bridged operation's exact hidden function symbol and Objective-C class on this 15.6 build. This is a concrete implementation lead; no movement operation was invoked, so its behavior and SIP-enabled compatibility remain unverified.

Shoji can plausibly retain ordinary **native macOS Spaces** navigation and window movement without Dock injection or disabling SIP. It needs another backend: UI automation for some operations and version-sensitive private WindowServer calls for others. This cannot promise the same immediacy, completeness, or stability as the existing injected backend. Hammerspoon explicitly documents this mixed approach as experimental. [Hammerspoon Spaces documentation](https://www.hammerspoon.org/docs/hs.spaces.html)

Alternatively, Shoji could implement its own virtual workspaces without manipulating native Spaces. AeroSpace demonstrates that SIP-compatible product model, but those workspaces are not Mission Control desktops. [AeroSpace README](https://github.com/nikitabobko/AeroSpace/blob/main/README.md)

## What SIP actually blocks

SIP restricts even root access to protected operating-system components. Its runtime protections deny attaching to protected processes and obtaining their Mach task ports. Signing Shoji with a stable certificate or granting Accessibility access does not remove that protection. [Apple SIP overview](https://support.apple.com/en-us/102149), [Apple runtime protections](https://developer.apple.com/library/archive/documentation/Security/Conceptual/System_Integrity_Protection_Guide/RuntimeProtections/RuntimeProtections.html)

Upstream documents partial SIP disablement specifically for injecting its scripting addition into Dock; native Space creation, destruction, reordering/movement and several window effects use it. This does not establish that every third-party interaction with Spaces requires SIP changes. [Upstream scripting-addition requirements](https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection)

## Public interfaces versus private mechanisms

Apple documents native user operations: Control–Left/Right, Mission Control thumbnails, adding/deleting desktops, and dragging windows between them. Those are available with normal system protections. Apple also documents Accessibility properties, actions, and notifications as a way to operate an app's exposed interface. [Apple macOS 15 Spaces guide](https://support.apple.com/guide/mac-help/work-in-multiple-spaces-mh14112/15.0/mac/15.0), [Apple Accessibility model](https://developer.apple.com/library/archive/documentation/Accessibility/Conceptual/AccessibilityMacOSX/OSXAXmodel.html)

**Research conclusion:** no documented public API offering the full native Space lifecycle was found. Public AX machinery is distinct from relying on Dock's particular Mission Control element hierarchy. Hammerspoon also uses undocumented `SLS*` functions; being callable without injection does not make those functions public or supported. [Hammerspoon implementation](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/spaces/libspaces.m), [Mission Control AX implementation](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/spaces/spaces.lua)

## Capability matrix

The middle column describes researched approaches, not features already implemented in Shoji.

| Operation | Possible SIP-enabled approach | Limits / evidence |
| --- | --- | --- |
| Previous/next native Space | Synthesize configured macOS shortcuts; observe completion | Ordinary OS transitions; shortcut/display targeting needs validation. Apple documents Control–Left/Right. |
| Focus a Space by ID/index | Resolve current display/order, then press its Mission Control AX thumbnail | Hammerspoon `gotoSpace`; visible UI and stabilization delay. |
| Faster native focus | Experimental synthetic Dock swipe gestures | Upstream has a fallback without the addition, using undocumented event fields. Target behavior unverified. |
| Query native IDs, order, display, membership | Existing-style private `SLS*` read calls | Hammerspoon uses these outside Dock; no supported API guarantee. |
| Move ordinary windows between user Spaces | Candidate private WindowServer compatibility-workspace calls | Unresolved on 15.6: Hammerspoon's branch has Sequoia failure reports. Newer bridged movement is confirmed upstream on 26.4 only. |
| Create a native desktop | Press Mission Control's add button for the selected display | Hammerspoon `addSpaceToScreen`; observe the new ID before recording ownership. |
| Destroy a native desktop | Press the thumbnail's removal action after switching away | Hammerspoon `removeSpace`; rejects the last user Space and active Space. Destruction moves its windows elsewhere. |
| Reorder native desktops / move whole desktop across displays | Potential Mission Control drag automation | No completed SIP-on implementation established by this research; do not advertise parity. Existing injection remains a separate optional capability. |
| Focus another display / move a window geometrically | Existing AX/window/display approach, potentially combined with Space membership change | Validate separately with multiple displays and “Displays have separate Spaces.” |
| Native fullscreen and Split View | Preserve OS behavior; app/window AX support where present | Fullscreen Spaces are not ordinary user desktops. Do not reuse ordinary-window movement blindly. |

Matrix evidence: [Apple macOS 15 interactions](https://support.apple.com/guide/mac-help/work-in-multiple-spaces-mh14112/15.0/mac/15.0), [Hammerspoon APIs](https://www.hammerspoon.org/docs/hs.spaces.html), [Hammerspoon AX operations](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/spaces/spaces.lua), [Hammerspoon private calls](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/spaces/libspaces.m), [upstream fallback and Space operations](https://github.com/asmvik/yabai/blob/master/src/space_manager.c).

### Details that matter for this target

Hammerspoon's source checks for macOS 14.5 or later. For window movement that branch sets a temporary Space compatibility ID, calls `SLSSetWindowListWorkspace`, then resets the compatibility ID. Older systems call `SLSMoveWindowsToManagedSpace`. It restricts ordinary movement to user Spaces; forcing movement into fullscreen is limited. Its success return does not independently prove the resulting membership. Shoji must verify rather than copying that assumption. [Hammerspoon native implementation](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/spaces/libspaces.m#L130-L184)

Hammerspoon opens Mission Control and addresses display-specific AX elements. Its default stabilization delay is 0.3 seconds, configurable upward; navigation/create/delete can visibly expose Mission Control. This matters given the recent latency regression: an Odin port should use a bounded asynchronous state machine rather than sleep or busy-wait on Shoji's event loop. [Hammerspoon AX implementation](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/spaces/spaces.lua)

Current upstream also contains a gesture fallback for focus: it calculates index distance and posts synthetic Dock swipe events, including a high velocity. Window movement has a newer dynamically available bridged-operation path plus older fallback paths. These are implementation leads, not evidence all those mechanisms exist on macOS 15.6. [Upstream Space manager source](https://github.com/asmvik/yabai/blob/master/src/space_manager.c)

## Local Shoji gap

The current source routes `.Space_Focus`, creation/destruction/movement, and window-to-Space `.Space` actions through `addition_action`. Private Space queries already run in Shoji itself. Fullscreen uses the window's `AXFullScreen` attribute separately. Sources: [backend](src/macos/backend_darwin.odin), [protocol client](src/macos/addition_darwin.odin).

The payload performs focus inside Dock using `SLSShowSpaces`, `SLSHideSpaces`, `SLSManagedDisplaySetCurrentSpace` and Dock object state. Creation/removal/reordering use discovered Dock functions. The loader obtains Dock's task port with `task_for_pid` and explicitly reports the SIP/debugging requirement on failure. Sources: [payload Spaces](src/addition/payload/spaces_darwin.odin), [loader](src/addition/loader/inject_darwin.odin).

Consequently, removing `--sa` alone will not preserve current Space commands. Copying payload calls into the daemon is not a demonstrated solution: those calls currently run with Dock's connection and internal objects. This is an inference from the local routing and payload above.

The dialog visibility fix also uses window layering through the addition. A SIP-on migration needs a separate review of that behavior; passing Space operations alone would not certify the complete everyday configuration. Sources: [backend](src/macos/backend_darwin.odin), [addition actions](src/macos/addition_darwin.odin).

## Alternative: virtual workspaces

AeroSpace keeps inactive-workspace windows at the screen's bottom corners and restores their positions when activated. Its intended setup uses one native desktop per display, rather than native Spaces as the workspace system. This enables its own immediate switching and ordering without injection, but changes Mission Control/gesture integration. Its guide documents visible edge pixels, monitor-arrangement constraints, and fullscreen/multi-display caveats. [AeroSpace virtual workspace design](https://nikitabobko.github.io/AeroSpace/guide#emulation-of-virtual-workspaces)

For Shoji this would require durable hidden-window bookkeeping, restoration after crashes, application activation handling, and fullscreen/hotplug policies. Those are proposed engineering requirements inferred from that design, not work already implemented.

## Recommendation and acceptance criteria

Implement an optional **native Spaces backend without injection** first, preserving the user's current workflow. Use normal shortcut transitions or a validated gesture path for common navigation, private membership moves for normal windows, and AX Mission Control actions for create/delete and fallback direct selection. Keep reorder/whole-Space cross-display movement explicitly unavailable until proven. Keep the existing injected mode independently optional. Do not silently reinterpret native Space commands as virtual workspaces.

Before recommending that the user re-enable SIP:

1. Add backend capability reporting; ensure ordinary startup cannot hang waiting for a payload when none is requested.
2. Verify operation completion from fresh OS observations, with timeouts and honest errors. Preserve original focus/order and never guess which newly observed desktop is disposable.
3. On the exact target, test rapid prev/next, direct selection, user-Space window moves, tracked creation/destruction, restart and permission behavior. Measure event-loop latency during Mission Control transitions.
4. Separately cover native fullscreen, multiple displays/hotplug, and floating dialogs. Declare unsupported effects such as arbitrary layering instead of claiming complete parity.
5. Repeat final acceptance with SIP fully enabled and no previously injected payload. A successful run on a system with protections disabled cannot prove SIP-enabled compatibility.

This recommendation is an engineering judgment from the primary sources and current backend structure. No implementation or live SIP-on validation was performed as part of this investigation.
