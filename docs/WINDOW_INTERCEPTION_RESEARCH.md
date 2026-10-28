# Window creation and first-show interception

Investigation: 2026-10-27. Scope: primary documentation, installed SDK headers, and local source inspection. No app injection, security-setting changes, or runtime interception was performed for this note.

## Finding

An in-process interceptor can run before an AppKit window is shown. This is a different capability from Shoji's current post-discovery Accessibility handling. A controlled owned-app prototype is feasible; universal interception of arbitrary applications is not established.

The first useful boundary is **first show**, rather than allocation. A hidden, initialized window provides real geometry and identity that a layout planner can use. Changing initializer dimensions alone cannot guarantee presentation geometry: application code can change the window afterward. This is an architectural inference from the separate initialization and ordering interfaces in Apple's installed `NSWindow.h` (lines 293–294 and 422–427).

Apple describes `makeKeyAndOrderFront:` as showing a window, making it key, and moving it forward within its level. `orderWindow:relativeTo:` separately controls screen-list ordering. Its declarations and other front/back/out entry points are present in the installed header. [Apple makeKeyAndOrderFront documentation](https://developer.apple.com/documentation/appkit/nswindow/makekeyandorderfront(_:)), [Apple ordering documentation](https://developer.apple.com/documentation/appkit/nswindow/order(_:relativeto:)).

## Existing process boundaries

`src/addition/loader/loader_darwin.odin` explicitly discovers `com.apple.dock`, obtains that process's task port, and loads the payload there. It does not load code into Motion Lab, Chrome, or other application processes. Consequently, replacing an AppKit method inside Dock would not replace the same method in those other processes. This conclusion follows from the loader's explicit target and the per-process Objective-C runtime.

The Motion Lab dependency already separates initialization from presentation: `/Users/kakurega/dev/oss/Odin/shared/metalized/platform_macos.odin:16` creates/configures an `NSWindow`; `show_native_window` at line 41 invokes `makeKeyAndOrderFront:` and then activates the app. Motion Lab itself sets a content minimum after `mtl.init` in `src/main.odin`; a placement integration must account for when the app establishes those constraints, rather than assuming the initial creation rectangle is final.

## AppKit interception mechanism and limits

Apple exposes Objective-C runtime method replacement. `method_setImplementation` returns the previous implementation, which allows forwarding the original call. The prototype should use exact selector argument types, save the original implementation, guard recursive calls, and restore only replacements it still owns. [Apple method_setImplementation documentation](https://developer.apple.com/documentation/objectivec/method_setimplementation(_:_:)).

The local Odin Foundation binding declares `method_setImplementation` without a return value (`.toolchain/Odin/core/sys/darwin/Foundation/objc.odin:73`), while Apple's SDK declares an `IMP` result (`usr/include/objc/runtime.h:1071`). Preserve originals with `method_getImplementation` before replacement or add a correctly typed local binding; do not read a result through the existing void declaration.

Replacing the base `NSWindow` implementation cannot guarantee coverage when a subclass implements its own method without forwarding to the superclass. Objective-C dispatch selects the overriding subclass implementation. AppKit methods are also not an established universal entry point for every window-server client. These are coverage limits, not evidence that any particular Chrome window bypasses AppKit. [Apple Objective-C inheritance and overriding](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ObjectiveC/Chapters/ocObjectsClasses.html).

A prototype should trace `orderWindow:relativeTo:`, `makeKeyAndOrderFront:`, `orderFront:`, and `orderFrontRegardless` to establish which paths actually execute. Apple documents the interfaces; the internal forwarding between them must be measured on the target OS rather than assumed. Sheets, modal dialogs, panels, restored windows, tabbed windows and fullscreen transitions need separate classification before their ordering may be delayed.

## Loading code into target apps

Startup injection and remote attachment are separate deployment problems from interception itself:

- Hardened Runtime library validation normally permits Apple libraries or libraries signed with the executable's Team ID. An unrelated Shoji payload does not automatically qualify. [Apple library validation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation).
- `com.apple.security.cs.allow-dyld-environment-variables` allows a target app to honor `DYLD_` variables. Loading a library signed by an unexpected team can additionally require the library-validation exception. The entitlement belongs to the target app; adding it to Shoji does not grant that capability to other apps. [Apple DYLD entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-dyld-environment-variables).
- Apple's SIP guide states that protected processes reject attachment/task-port acquisition and purge dynamic-linker environment variables. It explicitly notes that root does not override protected-process attachment restrictions. The guide is archived; current target eligibility must be checked separately. [Apple SIP runtime protections](https://developer.apple.com/library/archive/documentation/Security/Conceptual/System_Integrity_Protection_Guide/RuntimeProtections/RuntimeProtections.html).

These facts rule out treating the existing Dock injector or `DYLD_INSERT_LIBRARIES` as a universal solution. No target app should be re-signed or have security protections changed as an implicit part of this investigation.

## Recommended first implementation

1. Build a standalone owned AppKit fixture in Shoji. Install the interceptor before any window is presented and verify the original show implementation is reached only after the proposed frame/level is set.
2. Start with a synchronous local policy in the fixture. Test forwarding, recursion, repeat show/hide, ordering out, subclass overrides, and restoration. This proves interception without conflating it with cross-process IPC.
3. Introduce an explicit opt-in app-side agent and a bounded request to Shoji for placement. Keep AppKit operations on the application main thread. Shoji must be able to calculate placement from request data without synchronously querying the blocked application's Accessibility server, which could deadlock.
4. Correlate the approved placement with the existing opening lifecycle so Accessibility discovery does not stage the same window a second time. Preserve focus intent and distinguish parent-associated dialogs from independent windows.
5. If Shoji is unavailable, times out, disconnects, or denies a placement, allow the app's original presentation path rather than leaving an invisible, unusable window indefinitely. Timeouts and cancellation need observable tests.
6. Demonstrate the agent in an owned Motion Lab build before investigating individually permitted third-party apps. Keep existing Accessibility management as fallback for apps that cannot host the agent.

The fixture can establish **before-first-show** geometry and ordering for covered calls. It must not be described as controlling all application initialization or guaranteeing that every macOS window is intercepted. Cross-process launch injection, arbitrary-app compatibility, and first-frame visual verification remain separate work.
