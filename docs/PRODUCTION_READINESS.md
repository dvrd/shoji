# Production readiness

This checklist tracks the work needed before Shoji can be recommended for
reliable daily use by other people. A production release needs a defined set of
supported macOS versions, hardware, and features; it does not mean every Niri or
other window manager feature must be implemented. Items remain open until the
specified evidence exists. Historical test results are not a substitute for
revalidating the release candidate.

The daily-use target is macOS 27.2 (26B123) on Apple Silicon.
Some owned-window and Space checks have passed there; they do not establish
complete production readiness. See [Niri parity](NIRI_PARITY.md) for feature
status. Some historical notes contain stale paths or point to local, untracked
evidence; verify claims against the current source and preserve shareable release
evidence before closing an item.

## Release blockers

### Supported systems and safe defaults

- [ ] Publish a compatibility matrix naming exact macOS builds, architectures,
  supported features, and known limitations. Validate each advertised combination
  on real hardware or an appropriate VM; do not infer Intel support from Rosetta
  tests alone.
- [ ] Finish macOS 27 compatibility for the exact builds to be supported. Validate
  the normal release payload and loader, not only offline pattern matches or a
  diagnostic fixture: handshake, capabilities, each advertised Space operation,
  window effects, restart and recovery. Keep unsupported builds gated with clear
  errors. The existing 27.0.1 guest diagnostic is evidence for a specific
  operation, not full release acceptance.
- [ ] Test a clean SIP-enabled installation without an already-injected payload.
  Document precisely which features work without the payload and make unavailable
  operations report actionable errors. Keep injection and related system security
  changes explicitly optional.
- [ ] Define and verify defaults for layouts, gestures, animations and permissions;
  experimental features must remain opt-in until their acceptance tests pass.

### Installation, permissions and updates

- [ ] Test `task install` from a clean checkout on a fresh supported Mac: document
  and verify the Odin source revision, LLVM/build dependencies, Keychain setup,
  destination permissions, PATH, and failure messages. Test repeat installation
  and recovery from an interrupted or failed install.
- [ ] Test the Accessibility flow end to end with permission initially absent:
  correct executable is listed, settings open, countdown and wait/stop choices
  work, approval starts the service, and denial does not leave a restart loop.
  Include redirected/non-interactive use and an existing service pointing to a
  different binary. Verify update behavior preserves approval with the same
  signing identity and location.
- [ ] Make installation and updates safe for existing users: define how a service
  configured for an older path is migrated or retained, preserve configuration and
  optional payload settings, and verify rollback after a failed update. Test the
  loader and payload as a matching set.
- [ ] Provide a user-friendly release installation path that does not require a
  compiler, plus an uninstall procedure that removes only Shoji-owned files and
  the service. Decide how locally built and distributed releases retain stable
  signing identity across updates.
- [ ] Establish release signing, notarization, artifact integrity checks,
  provenance and a repeatable publishing process. Test a downloaded release on a
  clean Mac, including Gatekeeper, Accessibility, install, upgrade and uninstall.

### Stability and recovery

- [ ] Run long-duration interactive and idle soaks; record memory, CPU, event-loop
  latency, resource counts and recovery across repeated window and Space changes.
  Establish acceptable bounds and investigate growth or stalls rather than relying
  on the existing short memory measurements.
- [ ] Reproduce and resolve focus delays, freezes and rendering glitches under
  CPU/memory pressure and with slow or unresponsive applications. Measure input
  to visible response, and verify one slow AX or payload operation cannot stall
  unrelated window management indefinitely.
- [ ] Validate repeated opening, closing, focusing, resizing, dragging, floating,
  stacking and tab changes with real applications, including browser hover
  popups, system dialogs, native tabs and apps with unusual window behavior.
  Confirm focus rings follow the correct window and disappear promptly.
- [ ] Test sleep/wake, login/logout, daemon crash/restart, Dock restart, display
  connection changes, fullscreen, Mission Control and macOS updates. Verify
  windows remain usable, layouts reconcile correctly, and failures do not leave
  hidden, transparent, misplaced or inaccessible windows.
- [ ] Exercise crash and interrupted-animation recovery on real systems, including
  a missing/restarted Dock payload, permission revocation, failed restore and
  stale window IDs. Document the manual recovery procedure and the limits of
  recovery after WindowServer failure or power loss.
- [ ] Validate multi-display and multi-Space operation, including display hotplug,
  differing resolutions/scales, focus, moving windows, and rollback of partially
  failed Space moves. Preserve the user's existing Spaces during testing.

### Quality and release evidence

- [ ] Run the full CI workflow on GitHub and fix failures; protect releases with
  repeatable checks for builds, tests, memory errors and release artifacts.
  Record the exact revision, OS build and artifact hashes for each candidate.
- [ ] Add automated regressions for bugs found in live testing, then repeat the
  relevant real-window tests. Cover install/update/uninstall and service lifecycle
  without modifying the developer's active service.
- [ ] Define a release acceptance checklist with observable pass/fail criteria,
  including performance and motion quality, supported applications and recovery.
  Retain evidence that reviewers can access without local temporary paths.
- [ ] Review the socket, launchd files, privileged loader and sudo configuration
  for ownership, input validation, failure handling and least privilege. Verify
  third-party license notices and attribution before publishing.
- [ ] Complete user-facing command and configuration reference, troubleshooting,
  compatibility and security documentation; verify all repository links and
  examples from a clean installation. Add demonstration videos when available.
  Settings, daemon defaults, tiling, and rules are in
  [Configuration](CONFIGURATION.md) and locked by
  `config_catalog_matches_daemon_defaults`. Troubleshooting, compatibility,
  security, clean-install link checks, and videos remain open.

## Feature and experience work

These items are not automatic release blockers: decide which belong in the
published product and document any intentionally unsupported behavior.

- [ ] Compare Shoji's scrolling, columns, tabs, focus, gesture and workspace
  behavior against Niri; publish a feature matrix distinguishing implemented,
  partial, unsupported and intentionally different behavior.
- [ ] Improve motion quality and validate with real displayed frames: swipe
  tracking, focus-ring synchronization, gaps, window open/close, and resize
  transitions. Define acceptance criteria rather than claiming exact compositor
  parity on the basis of headless geometry tests.
- [ ] Review the remaining command, selector, rule, signal, application and
  fullscreen gaps; implement the ones required by the chosen compatibility scope
  and update stale notes.
- [ ] Investigate SIP-enabled alternatives for native Space operations and dialog
  layering, then validate each capability separately on supported builds. Do not
  promise full native Space parity without demonstrated behavior.
- [ ] Decide whether experimental WindowServer research has a supported product
  use; keep it isolated from normal startup and release artifacts until it does.
