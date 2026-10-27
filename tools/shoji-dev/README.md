# Development CLI

`task build:dev` builds `bin/shoji-dev`. `task build:tools` builds all three
focused tools. Taskfile remains the normal interface for building Shoji.

```sh
./bin/shoji-dev signing setup
./bin/shoji-dev signing check
./bin/shoji-dev signing sign bin/shoji.new --install bin/shoji
./bin/shoji-dev toolchain --patch-only
./bin/shoji-dev build-arm64e "$PWD/.toolchain/Odin"
./bin/shoji-dev package --version local
./bin/shoji-dev clean --dry-run
```

This tool owns persistent signing, pinned compiler preparation, release archive
creation and cleanup of known generated outputs. Signing verifies the candidate
before atomic installation and reuses the existing certificate/identifier.

Binary and archive inspection belongs to `shoji-inspector`; test execution and
live fixtures belong to `shoji-harness`. Service control is `shoji service`.
There are no forwarding commands for those other tools in this CLI.

After creating a package, verify it with `shoji-inspector check-archive ARCHIVE`.
`task package` performs both steps. Cleanup preserves the runtime, all three CLIs,
the arm64e compiler, unknown files, symlinks and research artifacts.

See [the shared workflow](../../docs/DEVELOPMENT_TOOLS.md).
