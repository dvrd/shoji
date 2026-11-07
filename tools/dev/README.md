# Development CLI

`task build:dev` builds `bin/dev`. `task build:tools` builds all three
focused tools. Taskfile remains the normal interface for building Shoji.

```sh
./bin/dev signing setup
./bin/dev signing check
./bin/dev signing sign bin/shoji.new --install bin/shoji
./bin/dev toolchain --patch-only
./bin/dev build-arm64e "$PWD/.toolchain/Odin"
./bin/dev package --version local
./bin/dev clean --dry-run
```

This tool owns persistent signing, pinned compiler preparation, release archive
creation and cleanup of known generated outputs. Signing verifies the candidate
before atomic installation and reuses the existing certificate/identifier.

Binary and archive inspection belongs to `inspector`; test execution and
live fixtures belong to `harness`. Service control is `shoji service`.
There are no forwarding commands for those other tools in this CLI.

After creating a package, verify it with `inspector check-archive ARCHIVE`.
`task package` performs both steps. Cleanup preserves the runtime, all three CLIs,
the arm64e compiler, unknown files, symlinks and research artifacts.

See [the development guide](../../docs/DEVELOPMENT.md).
