# Development, inspection and test tools

Build all tools with `task build:tools`. Each has its own source, entry point,
help output and executable:

| Tool | Source | Responsibility |
| --- | --- | --- |
| `bin/shoji-dev` | `tools/shoji-dev/dev` | Signing, pinned compiler preparation, archive creation and build-output cleanup. |
| `bin/shoji-inspector` | `tools/shoji-inspector/inspect` | Mach-O normalization, bootstrap relocation checks and archive verification. |
| `bin/shoji-harness` | `tools/shoji-harness/harness` | Compiler regressions, evidence/report orchestration, live fixtures and recovery checks. |

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
./bin/shoji-harness validate --preflight-only
./bin/shoji-inspector check-bootstrap bin/shoji-loader
./bin/shoji-dev clean --dry-run
```

The former `shoji-dev validate`, `live` and `check-asm` commands now belong to the
harness. `normalize-arm64e` and `check-bootstrap` belong to the inspector.
`shoji-dev package --verify ARCHIVE` becomes `shoji-inspector check-archive ARCHIVE`.
`task test:tooling` becomes `task test:harness`. Live fixture source now lives in
`tools/shoji-harness/fixtures/desktop`; its generated binary is
`bin/shoji-harness-fixture`. Historical evidence can retain the original names.

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
