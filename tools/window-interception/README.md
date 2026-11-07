# WindowServer interception harness

macOS draws every window through one process, **WindowServer**. Rearranging
windows via Accessibility makes apps move one at a time, so transitions tear.
Shoji injects a small payload **inside WindowServer** that can briefly hold the
one call that orders a window onto a Space
(`CGXOrderWindowListSpaceSwitchOptions`) until Shoji has staged the final
positions, then release — so a rearrangement lands in a single frame.

The **payload logic ships in `src/`** (`src/experimental/window_server/` and
`src/experimental/window_server_payload/` → `bin/shoji-ws.dylib`); production
Shoji drives it directly over an authenticated Mach channel (the "gate", see
`src/ws_adapter.odin`). Everything here is the **disposable, build-pinned
(26A434) experiment harness** around that engine — it is not a product feature.

## Layout

| Path | What it is |
| --- | --- |
| `src/experimental/window_server_payload/` | (Moved to `src/`.) The payload itself. `task build:windowserver-ordering-observer` builds it with the gate-client CDHash pinned for these experiments; `task build:windowserver-payload` builds the shipped copy. |
| `windowserver-payload-probe/` | Minimal payload used to probe load/permission on a build. |
| `gate-client/` | CLI to poke the gate by hand: `hello`, `bounds WID`, `place WID X Y`, `dump`. Test driver only. |
| `gate-handoff/` | Standalone gate-owner process + `gate-ctl.swift`/`gate-handoff-run.swift` wrappers that stage a whole layout (`layout-begin`/`add`/`arm`). Test driver only. |
| `lifecycle/` | Deploy/operate on a real machine: `trust-client.swift` (allowlist a Shoji build), `sentinel.swift` (kill switch), `report.swift`/`--ws-report` (diagnostics), plus the install/update/authorize docs. |
| `rea/` | Reverse-engineering + per-build port pipeline: `port-build.swift` (carve a new build → `model.json`), `diff-build.swift` (PORT CLEAN/NEEDED), `ghidra/` (static analysis), `abi-selftest/` + `hook-selftest/` (prove the arm64e ABI and hook install/remove on a build before it touches the real WindowServer). |
| `fixtures/` | Throwaway test windows pushed through the payload: `layout-frame/` (C1 atomic swap), `focus-raise/` (C2 focus receipt), `ordering-trigger/` (spawns a window + triggers a Space ordering), `visibility-sampler/` (polls CGWindowList to prove no mid-move flicker). |
| `c4-live.swift` | End-to-end acceptance on the guest: install → trust → run → drive a real app → assert Accessibility and WindowServer agree on the final pixel (±1px). |
| `run-experiment.swift` | Inject the observer into the live WindowServer (reboot-then-inject). |

## Safety

Guest-only, exact-build. Every unsupported state degrades to Shoji's native
Accessibility paths. Kill switch: `sudo touch
/Library/GPUBundles/ShojiWindowServerProbe/DISABLED`. See `lifecycle/` for the
install, update and authorization story.
