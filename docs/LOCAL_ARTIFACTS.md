# Local build outputs and research artifacts

Source, tests, vendored decoder sources and concise validation evidence are saved in Git. Build products and machine-local research inputs stay ignored.

| Path | Purpose |
| --- | --- |
| `bin/` | Rebuildable executables, tests and libraries. Cleanup preserves the installed `shoji`, `shoji-loader`, `shoji-sa.dylib`, the native `shoji-dev` command and the local `odin-arm64e` compiler. |
| `.toolchain/` | Pinned compiler and Odin libraries required for reproducible local builds. |
| `artifacts/dock-evidence/` | Retained current/baseline/macOS 27 Dock binaries, acquisition manifests and comparison reports. |
| `artifacts/macos27-vm/` | Restore acquisition and VM installation records; any retained IPSW belongs here. |
| `artifacts/macos27-guest/` | Historical isolated guest transfer kit with its original hashes and provenance; rebuild before treating it as current. |
| `artifacts/validation/investigations-2026-10-27.tar.gz` | Verified compressed archive of 249 non-binary investigation files, including raw traces, logs and diagnostic scripts. |
| `artifacts/rollback/2026-10-27/` | One copy of the working runtime, payload and loader, with hashes and source checkpoint. |
| `artifacts/cleanup-2026-10-27.json` | Relocation index, archived-file checksums and archive/runtime hashes. |
| `docs/evidence/` | Small, versioned summaries supporting the validation documents. |

The 2026-10-27 cleanup saved source checkpoint `e537b25`, preserved the working runtime and removed old test executables, symbol bundles, probe applications and duplicate experimental builds. Historical notes refer to their original `bin/` locations. Dock/VM records now use the paths above; other archived records retain their original relative names inside the compressed archive. Expand selected records into a temporary directory when investigating them rather than restoring old clutter into `bin/`.

```sh
task clean:preview
task clean
tar -tzf artifacts/validation/investigations-2026-10-27.tar.gz
```

`task clean` does not remove research artifacts or unknown files, follow symlinks, stop/restart Shoji, or modify the Dock. It removes optional helper executables too; rebuild them with their named tasks when needed. Decoder libraries rebuild through `task raven`, and `task check` declares that prerequisite. An unrecognized future output stays in place until its cleanup policy is explicit.

The known `bin/universal/`, `bin/transaction-fix/` and `bin/macos27/` output
directories are also removable when every entry is an expected Mach-O output.
Unknown files, backups, subdirectories, nonbinary inputs or symlinks preserve the
entire directory. Preview the exact removal list with `task clean:preview`.

The VirtualBuddy VM is outside this repository at `~/Library/Application Support/VirtualBuddy/Misty Pony.vbvm`; project cleanup does not touch it. The read-only restore compatibility probe now has maintained source/entitlements under `tools/vm-preflight/` and can be rebuilt with `task build:vm-preflight`.

Ignored artifacts and rollback copies are local conveniences, not remote backups. Git checkpoints preserve the maintained code and versioned validation evidence; large Apple images and raw archives are not committed.
