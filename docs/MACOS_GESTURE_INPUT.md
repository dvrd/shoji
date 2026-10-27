# macOS gesture input investigation

Investigated 2026-10-26. This is read-only research and an implementation recommendation, not evidence that Shoji has received a physical swipe on this laptop. No input capture, event injection, system preference changes or engine edits were performed for this note.

## Two different input paths

Apple distinguishes three-finger swipes from two-finger scrolling. Application gesture delivery follows the view/responder path; system gestures can take precedence. Public application touch handling therefore does not establish a global raw-three-finger input feed. [Apple trackpad event guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingTouchEvents/HandlingTouchEvents.html).

In Shoji's inspected code, modified scrolling is handled as CG event type 22, while the existing type-30 system-swipe handler only suspends layout work. The latter currently reads kind 23 from field 110, horizontal motion 1 from field 123 and phase from field 132. Consequently, enabling the modified-scroll path does not also implement unmodified system-swipe panning. See `src/macos/scroll_darwin.odin`, `src/macos/mouse_darwin.odin` and `src/engine/scroll_gesture.odin`; these references describe the inspected state and may change during implementation.

## Fn and two-finger scroll: verified public API

The installed SDK defines `kCGEventFlagMaskSecondaryFn` through `NX_SECONDARYFNMASK = 0x00800000`, matching `NSEventModifierFlagFunction = 1 << 23`. It also provides `CGEventSourceFlagsState`, whose combined-session state ID is zero and reflects the session's current modifier state. This gives a useful independent diagnostic alongside flags attached to an individual event. There is no evidence here that Fn is universally absent from scroll events, nor that missing Fn flags caused the user's failure. [Apple flags-state API](https://developer.apple.com/documentation/coregraphics/cgeventsource/flagsstate(_:)). Local primary references: `CoreGraphics/CGEventTypes.h:92,482`, `CoreGraphics/CGEventSource.h:23–39,133`, `IOKit/hidsystem/IOLLEvent.h:248` and `AppKit/NSEvent.h:171`, under `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks`.

`NSEvent.h:345–356` identifies `scrollingDeltaX/Y` as the preferred API: precise events are in points, otherwise multiply by line/row height. It also documents that the reported direction already incorporates the user's natural-scrolling preference. Bridging an incoming CG event to NSEvent can preserve fractional deltas. Integer CG pixel fields can round tiny updates, but that is a hypothesis requiring physical-event evidence, not an established root cause.

## Global system-swipe interception: concrete primary implementation

The MIT-licensed InstantSpaceSwitcher source at commit **`f7616e42651b1ed8d81625e3640eceed6efa8018`** intercepts native horizontal Dock swipes through a session event tap. Its declarations and callback establish this private decoding map:

| Field | Getter / interpretation |
| --- | --- |
| 55 | integer private CGS event type; Dock control 30, companion gesture 29 |
| 110 | integer HID gesture kind; Dock swipe 23 |
| 123 | integer motion axis; horizontal 1 |
| 124 | **double** swipe progress |
| 125 | **double** swipe position X; declared/used by its synthesis path, not its classifier |
| 129, 130 | **double** velocity X/Y |
| 132 | integer phase: began 1, changed 2, ended 4, cancelled 8, may-begin 128 |

Its callback latches at began, reads progress on changed and velocity on ended, and suppresses the claimed sequence plus companion type-29 events. Its tap uses session/head/default options and masks 29 and 30. This is evidence of a viable interception technique, not an Apple-supported contract or a current-host validation. [Pinned field declarations](https://github.com/jurplel/InstantSpaceSwitcher/blob/f7616e42651b1ed8d81625e3640eceed6efa8018/Sources/ISS/ISS.c#L16), [callback](https://github.com/jurplel/InstantSpaceSwitcher/blob/f7616e42651b1ed8d81625e3640eceed6efa8018/Sources/ISS/ISS.c#L161), [tap setup](https://github.com/jurplel/InstantSpaceSwitcher/blob/f7616e42651b1ed8d81625e3640eceed6efa8018/Sources/ISS/ISS.c#L695).

The classifier does **not** reveal physical finger count. It recognizes the system's configured horizontal Dock swipe, which may be mapped to three or four fingers. Hammerspoon likewise distinguishes generic CG gesture observation from a more specific NSEvent type via `eventWithCGEvent:`; numeric NSEvent types must not be blindly reused as private CGS types. [Pinned Hammerspoon event bridge](https://github.com/Hammerspoon/hammerspoon/blob/23e387e2805a9890066366e0ac96c71b27f0cfd5/extensions/eventtap/libeventtap_event.m), [Hammerspoon gesture documentation](https://www.hammerspoon.org/docs/hs.eventtap.event.html#getType).

## Scoped ownership recommendation

This is a proposed Shoji policy, independently authored from the evidence above:

1. At horizontal Dock-swipe **began**, claim only if scrolling gestures are enabled, the pointer's active Space has scroll layout, the normal desktop is active, and no conflicting interaction is running. Latch the display and Space.
2. Feed double-valued progress into one viewport-motion model. Do not use it to send native Space-switch commands. Determine progress scale and sign from a bounded physical trace before treating it as pixels or a fraction of screen width.
3. Once claimed, retain ownership through changed/ended/cancelled and suppress only its associated companion events. Never start ownership halfway through an already-running system gesture. Leave unclaimed BSP, vertical, fullscreen and unknown gestures to macOS.
4. Keep tap callbacks short; record motion and drive rendering from the normal timer. Fail open when fields/version are unsupported or the tap is disabled. Disabling this optional feature should restore ordinary system behavior without editing preferences.

There is a **macOS 27-specific warning in the primary source**: ISS lets the real ended event pass after zeroing progress/velocity so Dock can close its internal gesture state. Its separate synthesis implementation also augments serialized events on that OS. Do not copy its synthesis path or infer that suppress-all on macOS 15.6 is safe on 27. The present Shoji host target is 15.6 / 24G84; later versions need their own capture and end-state validation. [Pinned ended-event handling](https://github.com/jurplel/InstantSpaceSwitcher/blob/f7616e42651b1ed8d81625e3640eceed6efa8018/Sources/ISS/ISS.c#L244), [separate serialization implementation](https://github.com/jurplel/InstantSpaceSwitcher/blob/f7616e42651b1ed8d81625e3640eceed6efa8018/Sources/ISS/event_serialize.c).

## Raw finger-count alternative

If exact three-finger recognition independent of the user's configured system gesture is required, private MultitouchSupport is a separate possible backend. The pinned `hs._asm.undocumented.touchdevice` header describes contact-frame callbacks containing a touch count, identities, stages and normalized positions. It declares device enumeration, start/stop, register/unregister callbacks. Its source marshals contact frames onto the main queue. These community ABI declarations were originally tested against macOS 10.12.6; they are not proof of the current ABI. Raw contact observation alone does not stop Dock from reacting, so system-gesture arbitration is still required. [Pinned header](https://github.com/asmagill/hs._asm.undocumented.touchdevice/blob/856f98dd700e5c0263fbf74ed9ac9b6d13fac84c/MultitouchSupport.h), [implementation](https://github.com/asmagill/hs._asm.undocumented.touchdevice/blob/856f98dd700e5c0263fbf74ed9ac9b6d13fac84c/internal.m).

Start with the scoped existing Dock-swipe stream rather than adding a raw-device reader, provided its physical trace confirms usable progress on this target. That reduces ABI surface and avoids requiring a new device lifecycle/threading subsystem solely to duplicate an already recognized system swipe.

## Required physical evidence before claiming a fix

Record a bounded ring buffer containing only event family, phase, horizontal/vertical delta or progress, event flags, current session flags, enabled/tap status, selected display/Space/layout, ownership decision and reason. Exclude keycodes, characters and application text. It should distinguish:

- No events arriving or tap unavailable/disabled.
- System swipe arriving through type 30 while modified-wheel code is idle.
- Fn visible in event flags versus only in session state.
- A valid event rejected because layout is BSP, modifiers differ, or vertical intent won.
- Accepted deltas reaching the viewport but being undone by refresh/focus or hidden by animation.

Synthetic callback tests establish routing only. They do not prove physical Fn delivery, system-swipe suppression, release/cleanup behavior or ergonomic motion. Capture the user's actual Fn-plus-two-finger and system swipe once the recording seam is installed, then turn those minimal traces into replayable tests.
