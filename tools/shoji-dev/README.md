# Native development tools

`task build:dev` builds `bin/shoji-dev` with Odin and ad-hoc signs this developer
executable. It does not require a configured signing identity. `task signing:setup`
then prepares persistent application signing; existing identities are reused.
Run commands from the repository root, or keep the executable in its `bin/`
directory so it can locate the project. Release packages include this executable.

```sh
task build:dev
./bin/shoji-dev --help
./bin/shoji service status
```

| Command | Responsibility |
| --- | --- |
| `signing setup`, `check`, `sign` | Persistent Keychain identity, designated requirements and verified atomic installation. |
| `service plist`, `install`, `start`, `stop`, `restart`, `status`, `uninstall` | Same launchd controller as `shoji service`; use the application command for everyday operation. |
| `toolchain`, `build-arm64e` | Prepare the pinned Odin checkout, apply exact compiler patches and build the isolated compiler. |
| `normalize-arm64e`, `check-asm`, `check-bootstrap` | Mach-O ABI normalization, compiler regressions and bootstrap relocation checks. |
| `package`, `package --verify ARCHIVE` | Release archive assembly, member validation and SHA-256 verification. |
| `clean --dry-run`, `clean` | Preview or remove known rebuildable outputs while preserving the installed runtime, compiler and research artifacts. |
| `validate`, `validate --preflight-only` | Record build/test and target-machine prerequisite evidence. |
| `live desktop`, `live spaces`, `live animation` | Explicit live checks with disposable fixtures and evidence reports. |

The CLI passes literal argument arrays to Apple/system tools; no shell command
construction or Python interpreter is involved. Compiler builds still use Odin's
upstream shell build script and C++ toolchain. Apple signing, launchd, archive and
inspection commands remain platform dependencies.

`live desktop` refuses an existing window-manager daemon. Space checks track the
newly created Space and never accept a pre-existing Space as a cleanup target.
Dock restart is available only through the explicit `live animation --dock-restart`
option, with noninteractive sudo policy checks and recovery guards. Ctrl-C or
SIGTERM cancels owned child processes and permits deferred fixture/Space cleanup.
SIGKILL cannot run cleanup handlers.

`task test:tooling` runs native service, signing, packaging, cleanup, timeout,
cancellation and live-safety regressions. Service/Dock mutations are mocked;
temporary fixture processes and archives exercise real native process/file paths.
`task test:compiler` runs real compiler diagnostics against the pinned compiler.

The implementation shares `src/service` and `src/support` with the application.
`tooling/` contains development workflows, `tests/` their regressions and
`fixtures/` isolated executable test subjects. No development commands are loaded
into the window-manager daemon.
