# Development

## Source map

Odin packages are directories. The root `shoji` package holds the daemon,
window manager and macOS runtime; subpackages hold code with a clear boundary.

| Package | Responsibility |
| --- | --- |
| `src` | Executable, manager, commands, runtime, input, motion and native backend |
| `src/layout` | Layout tree (BSP/stack nodes and views) and scroll-strip geometry |
| `src/dock` | Dock protocol, animation recovery and signature scan tables |
| `src/inject` | Remote-thread loader and arm64/amd64 call shims used to inject payloads |
| `src/payloads/dock` | Payload loaded into Dock (`bin/shoji-sa.dylib`) |
| `src/payloads/windowserver` | Payload loaded into WindowServer (`bin/shoji-ws.dylib`), see its [README](../src/payloads/windowserver/README.md) |
| `src/windowserver/gate` | WindowServer gate: hooks, Mach protocol, identity, build target |
| `src/windowserver/attach` | `shoji --ws-attach`: root attach, image scan, install paths |
| `src/service` | `shoji service` (launchd service control and status) |
| `src/ipc` | Command socket wire format and client |
| `src/health` | Health report shared by the daemon, service and attach |
| `src/support` | Filesystem, process execution and small shared helpers |
| `src/native` | Native types shared by Shoji and the payloads |
| `src/loader` | arm64e `shoji-loader` executable |

Root package files, grouped by responsibility:

| Area | Files |
| --- | --- |
| Entry and commands | `main`, `commands`, `command_server`, `config_run`, `settings`, `rules`, `regex` |
| Manager and windows | `manager`, `window_commands`, `window_opening`, `opening_notices`, `scratchpad`, `size_feedback`, `size_validation` |
| Layout glue | `layout_scroll` (constraints, scroll commands, rows, transfers), `layout_motion` |
| Runtime | `runtime`, `app_notifications`, `refresh`, `window_observation`, `window_readback`, `workspaces`, `notify`, `health_runtime` |
| Motion | `display_clock`, `animation`, `animation_journal`, `motion_coordinator`, `motion_trace`, `surfaces`, `resize_transition`, `feedback` |
| Input | `touch_input`, `pointer_input`, `scroll_input`, `pointer_drag`, `gesture_routing` |
| Native backend | `backend` |
| Payload clients | `payload_client` (Dock), `ws_adapter`, `ws_attach_runtime`, `ws_report` (WindowServer) |

Architecture suffixes (`_arm64`, `_amd64`) are real build selections: Intel
slices are still built. Shoji is macOS-only, so files carry no OS suffix.

## Tools

Build all tools with `task build:tools`:

| Tool | Source | Responsibility |
| --- | --- | --- |
| `bin/dev` | `tools/dev/dev` | Signing, pinned compiler preparation, archive creation and build-output cleanup |
| `bin/inspector` | `tools/inspector/inspect` | Mach-O normalization, bootstrap relocation checks and archive verification |
| `bin/harness` | `tools/harness/harness` | Compiler regressions, evidence/report orchestration, live fixtures and recovery checks |
| `bin/shoji-dock` | `tools/shoji-dock` | Offline Dock signature scanner (`task dockscan`), see [its guide](../tools/shoji-dock/README.md) |

`tools/common` holds shared process/path context and the release catalog. Use
`shoji service` for service control; no development CLI runs in the daemon.
WindowServer live acceptance is `harness live windowserver`; its ABI and hook
self-tests are `tools/harness/fixtures/ws-*-selftest`. Per-build porting lives
in the separate spelunker project (`spelunker-port`).

```sh
task check            # strict checks: src, payloads, loader, tools
task test             # core tests
task test:harness     # harness regressions
task test:compiler
task test:motion
task test:memory      # needs a logged-in session with Dock running
task test:focus
./bin/harness validate --preflight-only
./bin/inspector check-bootstrap bin/shoji-loader
```

Core, Intel, scanner and harness tests treat tracked leaks and bad frees as
failures. `task test:memory` measures native malloc retention over 2,000 Dock
identity polls and writes `artifacts/memory/native-polling.json`; growth above
16 KiB or 128 live allocations fails. Socket-readiness tests bind disposable
Unix listeners under `/tmp`; a denied bind is a failed prerequisite, not a skip.

One core test fails on a machine whose WindowServer already serves a gate
(`windowserver_gate_mach_round_trip_reports_this_process`); it expects no
payload to be resident.

## Releases

Release assembly builds Intel and Apple silicon slices of the CLIs and ships
them with the runtime binaries. Creation and inspection share one release file
list, and `task package` verifies the finished archive.

## Local files

Build products and machine-local research stay out of Git.

| Path | Purpose |
| --- | --- |
| `bin/` | Rebuildable executables, tests and libraries |
| `.toolchain/` | Pinned Odin compiler and libraries |
| `artifacts/` | Local evidence and measurement output (`memory/`, `macos_versions/`) |
| `docs/local/` | Personal notes and scratch documents |

`task clean:preview` lists what `task clean` would remove. Cleanup preserves
the installed runtime, the compiler and research artifacts; it never follows
symlinks, removes unknown files, restarts Shoji or touches Dock. A known output
directory is removed only when every entry is an expected Mach-O output.
