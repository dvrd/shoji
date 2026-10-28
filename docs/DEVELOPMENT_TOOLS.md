# Development, inspection and test tools

Build all tools with `task build:tools`. Each has its own source, entry point,
help output and executable:

| Tool | Source | Responsibility |
| --- | --- | --- |
| `bin/dev` | `tools/dev/dev` | Signing, pinned compiler preparation, archive creation and build-output cleanup. |
| `bin/inspector` | `tools/inspector/inspect` | Mach-O normalization, bootstrap relocation checks and archive verification. |
| `bin/harness` | `tools/harness/harness` | Compiler regressions, evidence/report orchestration, live fixtures and recovery checks. |

`tools/common` contains shared process/path context and the release catalog; it
contains no signing, live-window or inspection workflow. Native process execution
remains in `src/support`, and the service implementation stays in `src/service`.
Use `shoji service` for service control. No development CLI runs in the daemon.

Taskfile handles build dependencies and chooses the correct executable. Examples:

```sh
task build:dev
task build:inspector
task build:harness
task test:harness
task test:compiler
task test:motion
task test:memory
task test:focus
./bin/harness validate --preflight-only
./bin/inspector check-bootstrap bin/shoji-loader
./bin/dev clean --dry-run
```

The former `dev validate`, `live` and `check-asm` commands now belong to the
harness. `normalize-arm64e` and `check-bootstrap` belong to the inspector.
`dev package --verify ARCHIVE` becomes `inspector check-archive ARCHIVE`.
`task test:tooling` becomes `task test:harness`. Live fixture source now lives in
`tools/harness/fixtures/desktop`; its generated binary is
`bin/harness-fixture`. Historical evidence can retain the original names.

The core, Intel, scanner and harness test tasks treat tracked memory leaks and
bad frees as failures. `task test:memory` separately measures native malloc
retention over 2,000 Dock identity polls in the logged-in macOS session. It creates
no windows and writes `artifacts/memory/native-polling.json`. A running Dock is
required; a headless runner cannot certify this check. After warming native
caches, growth above 16 KiB or 128 live allocations fails the check. For a longer
run, use `./bin/harness-fixture memory-check OUTPUT.json 10000`.

Core socket-readiness tests create disposable Unix listeners under `/tmp` and
drive their current native run loop. They do not connect to the running Shoji
service or require window permissions. Restricted runners must allow local Unix
socket binding; a denied bind is a failed prerequisite, not a skipped test.

Release assembly builds Intel and Apple Silicon slices for all three CLIs and
ships them alongside the runtime binaries. The release file list is shared by
creation and inspection, and `task package` explicitly verifies the finished
archive. Cleanup preserves all three tools while removing disposable fixtures
and known build outputs.

Verified locally after the split: strict checks, 263 core tests on each of arm64
and Rosetta, 16 harness regressions, 17 scanner tests, upstream decoder tests,
both compiler diagnostic suites, loader self-test, bootstrap inspection, headless
motion checks and a signed universal release archive with all six binaries.
Desktop preflight passed. The application candidate was built under
`artifacts/tool-split/`; this refactor did not install a new window-manager
executable, restart the service or reload Dock. Local logs are retained under
`artifacts/tool-split/verification/`.
