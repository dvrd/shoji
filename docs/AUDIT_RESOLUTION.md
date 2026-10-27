# Project audit resolution — 2026-10-27

All six warnings and the maintenance-ownership finding from the audit of
`4b1d504` are addressed.

| Finding | Resolution |
| --- | --- |
| W1: descendant processes survive interruption/timeouts | Darwin `posix_spawn` creates an owned command process group atomically, resets child signal state and restricts inherited descriptors. Nested tools share the command group. Cleanup gracefully stops the group, escalates remaining processes and reaps the direct child. |
| W2: duplicate standalone tools | Removed `tools/build_odin_arm64e/` and `tools/normalize_arm64e_abi/`; the native `dev` commands remain the maintained entry points. |
| W3: unused foreign APIs | Removed the six unused declarations from macOS bindings, socket bindings and loader declarations. |
| W4: missing evidence can still report success | Command/report/hash failures now propagate. Workflow cleanup finishes before final evidence is saved and the actual returned error is selected. Original check errors, cleanup errors and evidence errors remain distinguishable. Blocked desktop and target-mismatch classifications are retained. |
| W5: known output directories accumulate | Cleanup recognizes universal, macOS 27 and transaction candidate directories only when all entries are expected Mach-O outputs. Backups, unknown files, nonbinary inputs, subdirectories and symlinks preserve the entire directory. |
| W6: inconsistent quality gates | Every maintained Odin build/test/check task treats warnings as errors. `task check` also covers the live fixture, loader, cancellation fixture, Objective-C VM probe and shell helper. Compiler diagnostic fixtures retain their explicit expected-warning checks. |
| I1: decoder maintenance ownership | `tools/shoji-dock/vendor/liblzraven/SHOJI.md` assigns responsibility to Shoji maintainers and records the update, regression-vector and Apple-output comparison requirements. The pinned dependency and original license are retained. |

Regression coverage includes nested native/shell processes, interruption, timeout,
a worker that ignores graceful termination, unrelated-process preservation,
blocked report/command-log destinations, missing binary hashes, original-error
preservation and cleanup of known/mixed/symlinked output directories.

Verification on macOS 15.6 (24G84), Apple Silicon:

- Strict application/development builds on arm64 and amd64; payload on arm64e and
  amd64; loader and all maintained diagnostics compile successfully.
- 262 arm64, 262 Rosetta, 16 tooling, 17 scanner and 6 compositor tests pass:
  563 Odin test executions, plus both compiler diagnostic suites, upstream decoder
  correctness/rejection suites, loader self-test and bootstrap inspections.
- The motion continuity check passes with 1,479 samples.
- Desktop preflight passes and the live desktop command refuses an existing daemon.
- The application CLI is installed with the existing designated signing identity;
  the native development CLI is rebuilt. The running service is not restarted.

Local logs and reports are retained under `artifacts/validation/audit-fixes/` and
`.cruft/audit-fixes/`. Original audit evidence remains under `.cruft/project-audit/`.
No live Space/window mutations, Dock reload/restart or SIP changes were needed.
Remote CI and macOS 27 runtime execution remain outside this verification.
