# Source map

**All of `src` contains 33 Odin files**, including scanner tests, architecture
variants and experimental WindowServer code. This count covers the entire source
hierarchy, not just the engine and macOS packages.

| Package | Files | Responsibility |
| --- | ---: | --- |
| `src` | 1 | Main executable entry point |
| `src/engine` | 6 | Window state, layout, motion, input, settings and commands |
| `src/macos` | 7 | Native implementation of the engine and runtime |
| `src/addition/bridge` | 2 | ARM64 and Intel assembly call conventions |
| `src/addition/loader` | 2 | Injection and ARM64 authenticated thread state |
| `src/addition/patterns` | 3 | Shared scanner and architecture-specific signature tables |
| `src/addition/payload` | 1 | Dock payload |
| `src/addition/protocol` | 1 | Dock protocol |
| `src/addition/recovery` | 1 | Shared animation recovery state |
| `src/addition/windowserver/payload` | 1 | Experimental WindowServer payload |
| `src/addition/windowserver/protocol` | 1 | Experimental WindowServer protocol |
| `src/addition/windowserver/target` | 1 | Experimental target policy |
| `src/dockscan` | 3 | Acquisition, analysis and regression tests |
| `src/loader` | 1 | arm64e loader executable entry point |
| `src/service` | 1 | launchd service management |
| `src/support` | 1 | Process and filesystem utilities |
| **Total** | **33** | |

## Core navigation

| Responsibility | Engine | macOS |
| --- | --- | --- |
| Window state and lifecycle | [windows.odin](../src/engine/windows.odin) | [runtime_darwin.odin](../src/macos/runtime_darwin.odin) |
| BSP, stack and scrolling layout | [layout.odin](../src/engine/layout.odin) | Frame writes and accepted-size observations live in backend |
| Animations and resize transitions | [motion.odin](../src/engine/motion.odin) | [motion_darwin.odin](../src/macos/motion_darwin.odin) |
| Pointer and gestures | [input.odin](../src/engine/input.odin) | [input_darwin.odin](../src/macos/input_darwin.odin) |
| Configuration and rules | [settings_darwin.odin](../src/engine/settings_darwin.odin) | Signal snapshots live in workspaces |
| Commands, queries and workspace operations | [commands.odin](../src/engine/commands.odin) | [ipc_darwin.odin](../src/macos/ipc_darwin.odin), [workspaces_darwin.odin](../src/macos/workspaces_darwin.odin) |
| Native declarations and action execution | — | [backend_darwin.odin](../src/macos/backend_darwin.odin) |
| Dock and experimental WindowServer integration | — | [addition_darwin.odin](../src/macos/addition_darwin.odin) |

Each file contains named responsibility sections. These are navigation groups
inside the existing packages; procedure interfaces and execution order are preserved.

- Engine/windows contains manager state, admission, window commands, scratchpad
  and accepted-size policy.
- Engine/layout contains the shared tree, BSP constraints, Scroll columns, row
  sizing and column transfers.
- Engine/motion contains window animation, viewport springs, animated geometry
  and motion traces. Input remains responsible for gesture routing.
- macOS/runtime contains the daemon loop, application notifications, desktop
  refresh, window observations, visibility, opening readiness and opening notices.
- macOS/backend contains framework declarations, action execution, Accessibility
  frame writes and accepted-size observations. Its owned-window validator stays
  inside signed Shoji to preserve the existing Accessibility identity.
- macOS/motion contains display pacing, frame batching, animation recovery,
  owned surfaces, resize content transitions and interaction feedback.
- macOS/workspaces contains display/Space discovery, display focus, event snapshots
  and signal delivery.
- macOS/addition keeps Dock and experimental WindowServer integration in distinct
  named sections. Consolidation does not enable or execute the experiment.

## Supporting implementations

- [loader_darwin.odin](../src/addition/loader/loader_darwin.odin): Mach declarations,
  copied bootstrap, loader lifecycle and target selection.
- [payload_darwin.odin](../src/addition/payload/payload_darwin.odin): Dock discovery,
  native Space/window operations and protocol server.
- [WindowServer payload](../src/addition/windowserver/payload/payload_darwin.odin):
  experimental native declarations and protocol server.
- [acquisition.odin](../src/dockscan/acquisition.odin): installer/MobileAsset
  acquisition, decompression and terminal progress.
- [scanner.odin](../src/dockscan/scanner.odin): Mach-O parsing, compatibility
  analysis, patch proposals and evidence serialization.
- [scanner_test.odin](../src/dockscan/scanner_test.odin): scanner and PBZM regressions.
- [support_darwin.odin](../src/support/support_darwin.odin): filesystem helpers,
  options, serialization, process execution and cancellation.

## Why some files remain separate

Architecture-suffixed assembly and signature tables retain compiler selection.
The shared pattern scanner stays separate to avoid duplicating it in both tables;
its ARM64 table also supplies the scanner's embedded pattern evidence. Executable
entry points and shared protocol/recovery packages retain their distinct build and
import roles. Darwin-suffixed implementations preserve native ABI constraints.

This pass reduces the entire source tree from 57 to 33 files without relocating
code outside `src` to change the count. Earlier consolidation reduced engine/macOS
fragmentation from 56 files to 20; this pass reduces those packages further to 13,
including their experimental integration code.

## Development tools

The independent `dev`, `inspector` and `harness` executables retain their interfaces.
Their entry points share startup and error handling through `tools/common`.

- `tools/dev/dev/artifacts.odin`: packaging and known artifact cleanup; signing
  and compiler toolchain handling remain separate.
- `tools/inspector/inspect/inspection.odin`: bootstrap, Mach-O and release inspection.
- `tools/harness/harness/checks.odin`: compiler diagnostics and target validation;
  desktop, animation and Space workflows retain their own files.

See [development tools](DEVELOPMENT_TOOLS.md) for commands and validation options.
