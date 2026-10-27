# Native tooling migration

The maintained project no longer requires Python. The 19 previous Python tools
and test modules have been removed. Their workflows live in Odin:

| Previous entry point | Native replacement |
| --- | --- |
| `tools/service.py` | `bin/shoji service COMMAND` |
| `tools/signing.py` | `bin/shoji-dev signing COMMAND` |
| `tools/toolchain.py` | `bin/shoji-dev toolchain` |
| `tools/build_odin_arm64e.py` | `bin/shoji-dev build-arm64e SOURCE` |
| `tools/normalize_arm64e_abi.py` | `bin/shoji-dev normalize-arm64e BINARY` |
| `tools/check_odin_asm.py` | `bin/shoji-dev check-asm` |
| `tests/check_bootstrap.py` | `bin/shoji-dev check-bootstrap BINARY…` |
| `tools/package_release.py` | `bin/shoji-dev package` |
| `tools/clean.py` | `bin/shoji-dev clean` |
| `tools/validate.py` | `bin/shoji-dev validate` |
| `tools/live_desktop.py` | `bin/shoji-dev live desktop` |
| `tools/live_spaces.py` | `bin/shoji-dev live spaces` |
| `tools/live_animation.py` | `bin/shoji-dev live animation` |
| Python tooling regression tests | `task test:tooling` |

Taskfile and CI invoke these commands. Bootstrap the developer executable with
`task build:dev`; persistent application signing is a separate step. Release
archives contain `shoji`, `shoji-loader`, `shoji-sa.dylib` and `shoji-dev`.

The launchd label remains `tech.shoji.window-manager`. The per-user plist,
configuration, log paths and persistent application signing identifier remain the
same. The existing local signing identity is reused, preserving the designated
requirement used for Accessibility authorization. Hammerspoon's service command
is now `SHOJI .. " service"`.

The migration includes strict signing/install checks, launchd ownership guards,
archive validation, process timeouts, cancellation cleanup, isolated fixture
ownership and guarded disposable-Space cleanup. Native tests use injected
executors for service/Dock mutations and real temporary files/processes where
appropriate. Live destructive checks remain explicit opt-ins, independent of
automated test success.

Historical investigation archives, evidence transcripts and third-party vendor
documentation can mention earlier Python commands. Those records preserve their
original provenance and are not current setup instructions.

## Validation on 2026-10-27

The native `shoji-dev validate` command completed on macOS 15.6 (24G84), arm64,
with status `automated-checks-passed-live-pending`. Local reports and command logs
are retained under `artifacts/validation/native-migration/`.

- Compiler/vet checks and eight real assembly diagnostic cases passed.
- All 262 core tests passed on arm64 and all 262 passed under Rosetta.
- All 14 native tooling tests passed, including interrupted child cleanup.
- Loader self-test, both copied-bootstrap inspections, universal builds and
  release checksum verification passed.
- Desktop inspection and the existing payload handshake passed.
- Native service restart succeeded with the existing signing identity,
  Accessibility access and launchd configuration. Hammerspoon uses the native
  service command. Gesture/animation settings were checked after startup.
- The live desktop command refused the already running daemon as intended.

The combined validation exposed existing gesture tests whose synthetic events
inherited the real cursor position; those events now explicitly target the test
display. A sandboxed Rosetta self-injection attempt timed out; the full validator
was run outside that sandbox and passed. No Dock restart or live Space/window
mutation was performed for this migration. Remote CI remains unverified.
