# Scrolling preview: live activation

Date: 2026-10-25. Host: macOS 15.6 / 24G84, Apple silicon.

## Activated

The signed scrolling candidate was installed at the existing `bin/shoji` path and only the `tech.shoji.window-manager` LaunchAgent was restarted. The service responds to IPC and retains the same designated requirement (identifier `tech.shoji.window-manager`, certificate leaf `6D7E315604019D4D0424770736986C54C9CA44CF`). Dock was not restarted or reinjected by this activation.

- Installed/preview SHA-256: `5b497ad247f4815a392c806da42cc54dca1f90edf1b977c95acffc8ac95fd9b4`.
- Previous executable SHA-256: `4ab0379d94410f21c426b704a77ca19b018f9a4961f6c9a4d7fba15c5860140b`.
- Actual rollback executable: `bin/scroll-live-20261025/shoji-before`.
- Runtime snapshots: `bin/scroll-live-20261025/` (ignored local artifacts, not permanent repository evidence).

The Ghostty window's native Space, ID 6 / UUID `4E5359EE-8716-4894-AE23-8B22977D4702`, was switched from BSP to scroll. Its requested/reported frame changed from `(4, 42, 1720, 1071)` to `(4, 42, 1032, 1071)`, matching the default 60% width. Other Spaces remained in BSP. The active Space changed during testing; native indices reordered, so the UUID/ID, not a remembered index, identifies this test Space.

## Animation attempt

A short test enabled duration 0.18, focused Ghostty and attempted a 70%-width resize before centering. The first animated frame operation returned:

```text
Screen Recording permission is required for window animations
```

The native backend checks this prerequisite before creating its proxy. Therefore no successful live movement, resize, retargeting or shuffling animation is claimed. The centering command after the failed resize did not execute. There is only one managed window on the test Space, so multi-window shuffling also needs an additional test window.

The tested width was restored to 1032 and animation duration returned to 0. The service remained running. Final observations showed Ghostty's Space in scroll, VirtualBuddy's Space in BSP and focused, and no loaded-payload or Accessibility failure during activation. Requesting Screen Recording is a separate prerequisite from the existing Accessibility grant.

## Resume

1. User enables Screen Recording for `/Users/kakurega/dev/projects/shoji/bin/shoji` in System Settings → Privacy & Security.
2. Restart only Shoji if required for the permission to take effect. Restart/config reload may reset layout to the existing shojirc's BSP setting; reapply scroll deliberately to the intended Space.
3. Query fresh Space/window identity before each test sequence. Avoid remembered indices because macOS may reorder native Spaces. Leave VirtualBuddy/VM windows outside the layout test.
4. Repeat resize, centering and interrupted-animation checks; then test shuffling/focus with multiple managed windows. Independently check actual geometry/visibility and dialogs. Capture-based animation remains distinct from interactive native-surface composition.

No user configuration file was edited; the active scroll selection and duration are runtime settings. The initial permission request is pending.

## Rollback from this activation

From the project root, restore the saved executable and restart Shoji:

```sh
cp -p bin/scroll-live-20261025/shoji-before bin/shoji.next
mv -f bin/shoji.next bin/shoji
launchctl kickstart -k "gui/$(id -u)/tech.shoji.window-manager"
```

For layout-only rollback, select the Ghostty Space from a fresh query (or switch to it), set animation duration 0, and run `./bin/shoji -m space --layout bsp`. Do not apply that command assuming the currently active Space is still the test Space.

## After the Screen Recording grant

The user enabled Screen Recording, and Shoji was restarted. The next frame attempt passed the capture-permission check but reported `Proxy_Order` native error 35798832. A recovery record for window 25/proxy 1847 remained. Animation was disabled, the desired width reset to 1032, and Shoji alone restarted to release the failed proxy. Startup configuration resets the runtime layout to BSP; do not assume the earlier scroll selection survived that restart. The recovery journal was preserved at `/tmp/shoji-animation_501.json` and copied to the local evidence folder, not deleted to conceal a pending recovery.

Read-only inspection established an ABI error in the old addition: its transaction functions do not supply the integer status being inspected. A corrected arm64e payload is staged separately, with the installed payload backed up. See [transaction ABI findings, tests and limitations](TRANSACTION_ABI.md). The Screen Recording request is complete; applying the corrected addition requires approval for a Dock restart before animations can be retested. No live animation success is claimed yet.

## Corrected payload applied and restoration

The user approved one Dock restart. The staged payload was atomically installed, Dock restarted through `gui/501/com.apple.Dock.agent`, and Shoji reloaded the addition. The old pending recovery record cleared without manual journal deletion.

The following Ghostty operations then completed without the former Proxy_Order error: a 70%-viewport width request, centering, and rapid width requests 1100 → 1250 → 1032 with 40 ms between requests. After settling, the journal was empty and the window query reported `(4, 42, 1032, 1071)`, visible and not hidden. This establishes successful command flow and cleanup, not independently measured visual frame pacing or multi-window shuffle acceptance.

The user then reported that Ghostty was stuck smaller/centered instead of filling the work area. Testing stopped. Animation duration was set to 0, the test Space returned to BSP, and temporary Space labels were removed. A second Ghostty window appeared during restoration, so BSP split the work area; the main window was explicitly zoomed to the work-area frame and focused. Its reported frame is now `(4, 42, 1720, 1071)`, with no remaining animation journal entries. The second terminal subsequently disappeared from the window query. User confirmation of the restored appearance is pending.

Scroll is not left active after this recovery. Do not repeat live tests on the user's working terminal as though a 60%-width resting column were the original full-width geometry. Use disposable windows and restore the user's layout/focus before handing control back. Multi-window shuffling, actual animation appearance, dialogs and failure/exit recovery still need separate acceptance.

## Disposable-window backend smoke test

The user confirmed Ghostty filled the work area again. A subsequent animation check used only two disposable accessory-app windows, verified through the live daemon to have the fixture PID and `is-floating=true` before mutation. No working window was included in the move/resize commands. The helper's new `floating-desktop` mode keeps those surfaces outside ordinary tiling and bounds their lifetime to 60 seconds.

The first fixture expired between interactive orchestration steps; the attempted command returned “could not locate window,” and the cleanup trap restored duration 0. The repeat ran launch, discovery, ownership/floating validation, actions and cleanup in one bounded shell sequence.

The successful repeat used fixture PID 42793, windows 2238 and 2239, and temporary animation duration 0.18. After initial placement at x=160 and x=880, the windows exchanged positions. The first window then received 650×480 followed 40 ms later by 580×440, exercising an interrupted resize while the second window completed its move. Final daemon-reported frames were:

- 2238: `(880, 160, 580, 440)`.
- 2239: `(160, 160, 600, 450)`.

The journal was empty after settling, both fixture IDs disappeared after closing the verified fixture process, and duration returned to its pre-test value of 0. Ghostty's reported frame remained `(4, 42, 1720, 1071)` before and after. Evidence is in `bin/scroll-live-20261025/{floating-fixture2.stdout,floating-membership.json,windows-floating-test.json,windows-after-floating-test.json,journal-floating-test.json}`.

This is a live backend test of animated movement, exchanged positions and rapid resize requests using floating fixtures. It complements the scrolling-layout command tests; it is not a live acceptance test of `scroll --swap` on a separate native Space. Physical frame pacing, visual smoothness, dialog behavior and multi-display clipping remain unmeasured. The current working layout remains BSP, not scroll, and animation remains disabled outside the test.
