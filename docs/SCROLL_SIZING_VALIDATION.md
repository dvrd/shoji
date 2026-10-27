# Native sizing and coordinated resize validation

Validated 2026-10-26 on macOS 15.6 (24G84), Apple Silicon. The deterministic suite passes 232 tests with warnings treated as errors. The optimized candidate also builds with warnings treated as errors and uses Shoji's existing persistent signing identity.

## Native experiment

An independent AppKit fixture owned two disposable windows. A separate trusted Shoji controller used the real foreign-process AX resize path, limited to that fixture PID and its verified WindowServer window IDs. The controller did not manage user application windows, restart Dock or change Spaces. The temporary validation LaunchAgent and fixture were removed after completion.

| Requested geometry | Observed result | Layout acceptance |
| --- | --- | --- |
| Width 300 | Width 700 (fixture minimum) | Retained request 300; footprint 700 and neighbor gap preserved |
| Width 1000 | Intermediate native widths then 1000 | Shared resize trajectory; logically focused neighbor stays within 2 points |
| Width 1600 | Width 1200 (fixture maximum) | Retained request 1600; footprint 1200 |
| Stacked row height 200 | Height 280 (fixture minimum) | Retained row request 200; sibling allocated below with 16-point gap |

[Native observations](evidence/size-24G84/observations.jsonl) record requested, expected and actual frames with timestamps and readback status. [Controller result](evidence/size-24G84/result.txt) records the passing assertions. Physical keyboard focus remained with the user's application; focused-neighbor assertions refer to the isolated layout model.

## Limits

The fixture tests cross-process AX and native AppKit clamping. Chrome, Ghostty and other representative applications still require acceptance checks. Stable readbacks are a heuristic: AX exposes no universal min/max geometry or acknowledgment serial. This does not demonstrate compositor-level synchronization, frame-rate guarantees, foreign clipping or SIP-enabled Space control. The original requests remain distinct from provisional observed footprints.

## Rollback

The pre-update executable is retained at `bin/size-validation-20261026/shoji-before-validation`. Restore it atomically, then restart only Shoji:

```sh
cp -p bin/size-validation-20261026/shoji-before-validation bin/shoji.next
mv -f bin/shoji.next bin/shoji
launchctl kickstart -k "gui/$(id -u)/tech.shoji.window-manager"
```

Backups under ignored `bin/` must be retained before cleaning build artifacts.

## Installed update

Installed candidate SHA-256: `9927d9f175301cb13bd209599ff2df72cd4a4bda1ff9cc64a7b3ffa3602b2176`. The LaunchAgent restarted successfully. All three prior BSP layouts, gesture enablement, runtime animation duration 0.5 and focused-window geometry were preserved. The animation recovery journal was empty. The fixture process and temporary validation job were absent. Before/after runtime snapshots are retained under `bin/size-feedback-20261026/`.

## User acceptance follow-up

The user confirmed the supplied Chrome/Ghostty checks all work: three-window navigation, narrow/wide sizing, rapid changes, Fn-assisted gesture reversal and closing the middle window. They report the interactions remain rough, especially smoothness. This establishes functional acceptance of those cases, not measured latency or visual parity with Niri. P02/P07 remain open for motion quality.
