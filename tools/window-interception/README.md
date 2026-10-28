# In-process window interception prototype

This opt-in Odin dynamic library intercepts AppKit calls **inside the creating
process**, before its window is shown. It is separate from the running Shoji
daemon and Dock payload. It currently accepts only the disposable
`shoji-window-interception-fixture` executable and the explicit
`SHOJI_WINDOW_INTERCEPTION_FIXTURE=1` environment setting.

```sh
sh tools/window-interception/build.sh
sh tools/window-interception/run.sh
```

Run the second command in the logged-in macOS desktop session. It creates and
closes five small, owned test windows; it does not attach to existing apps.
The build uses the isolated Odin toolchain and ad-hoc signatures for these test
artifacts only. It does not replace Shoji or its signing identity.

## What it proves

`DYLD_INSERT_LIBRARIES` loads the agent before the fixture's main function.
The agent replaces these `NSWindow` implementations and preserves their original
implementations for forwarding:

- `initWithContentRect:styleMask:backing:defer:`: substitutes 640 × 480 content
  dimensions before calling the real initializer.
- `orderWindow:relativeTo:` and `orderFrontRegardless`: apply a 640 × 480 frame
  at AppKit coordinates (160, 160), with normal window level, before forwarding
  the first show operation. These are fixed demonstration values, not a Shoji
  layout decision.

The fixture uses ordinary AppKit calls, without explicitly calling the agent to
create, size or show its window. It independently reads back the resulting frame,
content size, level and visibility. It checks that the agent observed its frame
and level applied **while hidden, before the original show call**; this is an
ordering check, not a screen recording proving compositor frame timing.

The tests cover opt-out, `orderFront:`, `makeKeyAndOrderFront:`,
`orderFrontRegardless`, and `orderBack:`. They also exercise an app changing the
frame between initialization and showing, `orderOut:` before showing,
later resizing, changing levels, and hiding/reopening. Associated-object markers
avoid applying first-show placement again on recursive or subsequent calls.

On macOS 15.6 (24G84), the first implementation failed the `orderFrontRegardless`
test: it did not reach the replaced `orderWindow:relativeTo:` implementation.
Adding the separate replacement made that same test pass. Do not assume every
show selector or subclass follows the base ordering implementation.

## Current boundary

This is a live-tested interception prototype, not an enabled global Shoji feature.
It does not yet negotiate placement with the daemon, correlate its windows with
the existing opening lifecycle, handle app-specific subclasses or alternate
initializers, or override application size constraints. A hook on this constructor
does not intercept allocation or every possible WindowServer creation call.

The injected library remains loaded until its test process exits. Hot unloading,
coexistence with other swizzlers, arm64e runtime injection, protected apps,
and third-party application coverage have not been validated. It does not
disable protections, re-sign apps, or request other apps' task ports.

Production integration needs an opt-in app agent and a bounded placement
protocol: Shoji must plan from the request/cache without synchronously querying
the same blocked app's Accessibility server. It also needs admission deduplication,
focus/dialog policy, accepted-size feedback and a fail-open path on disconnect or
timeout. See [the research and source references](../../docs/WINDOW_INTERCEPTION_RESEARCH.md).

## Validation

Validated on macOS 15.6 (24G84), Apple Silicon, on 2026-10-27:

- Both Odin packages build with warnings treated as errors.
- Live opt-out plus four first-show variants pass in separate test processes.
- Later frame and layer changes and reopening preserve the application's values.
- Original creation and ordering implementations are forwarded.
- The running Shoji daemon and Dock payload are not replaced by this prototype.
