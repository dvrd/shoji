# WindowServer interception harness

macOS draws every window through one process, **WindowServer**. Rearranging
windows via Accessibility makes apps move one at a time, so transitions tear.
Shoji injects a small payload **inside WindowServer** that holds window ordering
and transaction commits until Shoji has staged the final positions, then
releases them, so a rearrangement lands in a single frame.

The engine ships in `src/`: the gate in `src/windowserver/gate/`, the payload
in `src/payloads/windowserver/` (→ `bin/shoji-ws.dylib`), and root attach in
`src/windowserver/attach/` (`shoji --ws-attach`). Production Shoji drives it
over an authenticated Mach channel (`src/ws_adapter.odin`). Install,
authorization, recovery and porting are documented in the
[payload README](../../src/payloads/windowserver/README.md).

Everything here is test and porting tooling around that engine, pinned to the
supported build (26B123).

## Layout

| Path | What it is |
| --- | --- |
| `gate-client/` | CLI to poke the gate by hand: `hello`, `bounds WID`, `place WID X Y`, `dump`. |
| `gate-handoff/` | Standalone gate owner plus `gate-ctl.swift`/`gate-handoff-run.swift`, which stage a whole layout (`layout-begin`/`add`/`arm`). |
| `lifecycle/` | `trust-client.swift` (rewrite the allowlist), `sentinel.swift` (kill switch), `report.swift` (decode a saved ring offline). |
| `rea/` | Per-build port pipeline: `port-build.swift` (build → `model.json`), `diff-build.swift` (PORT CLEAN/NEEDED), `ghidra/` (static analysis), `abi-selftest/` and `hook-selftest/` (prove the arm64e ABI and hook install/remove before touching WindowServer). |
| `fixtures/` | Test windows driven through the payload: `ordering-trigger/` (Space ordering), `visibility-sampler/` (CGWindowList sampling). |
| `c4-live.swift` | Live acceptance (`task windowserver:live -- MODE`): `trust`, `run`, `controller`, `daemon`. Asserts Accessibility and WindowServer agree on the final frame (±1 px). |
| `run-experiment.swift` | Original VM injector for the harness observer build. Production uses `shoji --ws-attach`. |

## Safety

Exact-build only. Every unsupported state degrades to Shoji's native
Accessibility paths. Kill switch:
`sudo touch /Library/GPUBundles/ShojiWindowServerProbe/DISABLED`.
