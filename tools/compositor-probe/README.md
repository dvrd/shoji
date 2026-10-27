# Isolated native-window clipping experiment

Build with `task compositor:probe`. Run from Terminal on the laptop:

```sh
./bin/shoji-compositor-probe --run
```

This native Odin diagnostic is pinned to macOS 15.6 / 24G84. It creates two disposable, non-resizable accessory-app windows: a green target over a blue background. It accepts no existing window ID, uses the controller's own WindowServer connection, and does not load a Dock addition, restart a service, change Spaces, or change SIP. Existing Shoji remains running.

## What to observe

The terminal announces two ten-second phases:

1. **OWNED control:** the fixture's own process clips its green window to its left half. The right half should reveal the blue background. Click once in the green left interior and once in the blue right interior, away from the titlebar.
2. The green window is restored. **FOREIGN test:** the controller attempts the same clip on the fixture's window using a different connection. Observe whether the right half turns blue again, and repeat the two interior clicks.

The fixture restores its explicit rectangular baseline after each phase and closes both windows afterward. If the owner-issued control cannot be verified, the foreign mutation is skipped. Do not move the fixture or open menus during the experiment: unrelated occlusion, dragging or changed geometry can invalidate point queries. The experiment lasts roughly 25 seconds. Ctrl-C disposes the processes; an independent fixture lifetime limit also bounds recovery.

Copy the terminal summary and report whether **both phases** visibly revealed blue on the right, whether the boundary/shadows looked correct, and whether both windows disappeared afterward. If the program stops early, include the error and evidence path.

## Evidence and interpretation

Each run prints a temporary evidence directory containing:

- `observations.jsonl`: fixture identity, caller/owner connections, setter return codes, clip-region bounds, WindowServer point queries, actual received mouse-down records and restoration readback.
- `host-0.txt`: OS version/build; `host-1.txt`: architecture; `host-2.txt`: SIP state. Corresponding `.err.txt` files contain command errors.

The fixture reads its clip region independently of the controller. Setter success alone is never a pass. Point queries sample the left and right interior; actual mouse-down events include the receiving window ID and local position. A point-query result is distinct from rendered clipping and real event delivery. The terminal stays concise; raw observations go to the evidence file.

Exit 0 means foreign half-region readback and the sampled point-query routing matched at least in the observed phase; rendering, actual clicks, shadows and user confirmation remain required. Exit 2 means the control or foreign checks did not establish the expected result. Exit 3 is a preflight, protocol, ownership, restoration or timeout failure; exit 64 is invalid invocation. Do not translate a diagnostic failure into proof that every private approach is impossible.

The fixture explicitly initializes a rectangular clip on its own newly created target before announcing readiness. That is a controlled test baseline, not an exact reconstruction of the original AppKit clip. It never guesses nil-reset semantics. Restoration compares rectangular bounds, not arbitrary region equivalence. Closing these disposable windows is the final cleanup mechanism; this tool must not be extended to arbitrary app windows without a separate exact-restoration design.

The fixture is a separate process, restores after ten seconds even if the controller stops making progress, watches its parent/command pipe, and has an OS-enforced 45-second SIGALRM lifetime. The controller also has bounded waits and terminates only its own child if cleanup times out. Fixture termination removes both surfaces even if AppKit is blocked. Abnormal-path cleanup still needs live acceptance; unit tests do not certify it.

## Current validation

- Build with warnings as errors: passed.
- Strict ad-hoc signature verification: passed.
- Six deterministic tests covering ownership rejection, clip-vs-setter distinctions, point-query routing, fragmented/malformed IPC, actionable baseline-failure output, and delayed initial geometry: passed with memory tracking.
- Agent-session live attempt: stopped at “No WindowServer connection”; no clipping capability established. Evidence: `/var/folders/dr/rhcpqcds1wqd3824tvjn0f940000gn/T/shoji-compositor-5168545866`. This attempt preceded adding point-query observations; it is a session preflight result, not a runtime check of the completed probe.
- First user Terminal run: `/var/folders/dr/rhcpqcds1wqd3824tvjn0f940000gn/T/shoji-compositor-5411511287`. Window creation and clip readback succeeded; setup stopped with `baseline_unverified` before either clipping phase. The final clip and window bounds were both 520 × 328, and actual baseline clicks reached the target. The initial requested rectangle was not recorded, so this does not establish why the baseline comparison failed. No foreign clipping attempt occurred.
- The silent terminal exit on that setup failure is corrected. A subsequent run records `baseline_requested` and includes expected clip geometry in success/failure observations; setup errors print requested/observed geometry and readback codes. The next user Terminal run is needed to distinguish startup geometry changes from other causes rather than weakening the baseline assertion.
- Second user Terminal run: `/var/folders/dr/rhcpqcds1wqd3824tvjn0f940000gn/T/shoji-compositor-8625408019`. `baseline_requested` proves the initial successful bounds query returned an all-zero rectangle. Subsequent observations show the real 520 × 328 frame and clip. The setup failure was therefore caused by constructing the baseline before usable geometry was available. The fixture now pumps events and polls for positive bounded dimensions before allocating any clip, with a bounded polling budget and an explicit `geometry_unavailable` failure. A regression replay covers successful-but-empty queries followed by real geometry, as well as exhaustion without any valid dimensions. Live acceptance of this correction is pending.
- Visual clipping, actual clicks during clipping and abnormal-exit recovery remain pending.

Update: the completed user run `shoji-compositor-9442920632` verifies owner-issued half-width clip readback, point-query routing and real clicks to both target/background. The ordinary controller's foreign call returned zero but did not change clipping or point routing. Both rectangular restoration readbacks passed. See [preserved results and remaining limits](../../docs/COMPOSITOR_PROBE_RESULTS.md); the earlier pending entries above describe the initial failed runs, not the completed control. Visual/shadow and abnormal-exit acceptance are still outstanding.

Current host SIP is a custom configuration. Even a successful ordinary-controller test here would need repetition with fully enabled SIP before claiming SIP-compatible behavior. Native multi-monitor clipping, transform/input alignment, complete hiding, child dialogs and normal third-party app windows remain separate experiments after this first gate.

ABI evidence and known unknowns: [COMPOSITOR_PROBE_ABI.md](../../docs/COMPOSITOR_PROBE_ABI.md). Motivation and follow-up sequence: [Niri feasibility](../../docs/NIRI_MACOS_FEASIBILITY.md).
