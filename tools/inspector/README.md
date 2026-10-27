# Binary and release inspector

`task build:inspector` builds `bin/inspector`.

```sh
./bin/inspector check-bootstrap bin/shoji-loader
./bin/inspector check-archive dist/shoji-local-macos.tar.gz
./bin/inspector normalize-arm64e bin/shoji-loader.new
```

The inspector owns Mach-O header validation/ABI normalization, copied-bootstrap
relocation checks and release member/checksum verification. Normalization changes
only the explicitly selected thin arm64e binary after validating its header; it
must precede signing. The other commands inspect their inputs.

It does not build compilers, create signing identities, run live windows, inject
payloads or restart services. The harness can use the inspector library to verify
archives without importing development workflows. Both share only command/path
helpers and the release file catalog under `tools/common`.
