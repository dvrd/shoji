# Agent guidance

## Reverse-engineering (REA) tooling lives in spelunker

Shoji does not carry reverse-engineering tooling. Everything that inspects a
macOS build to decide what Shoji may hook belongs to the separate **spelunker**
project (`~/dev/projects/spelunker`, its own repository):

- `spelunker-port` CLI (`task install:port` there; installs to `~/.local/bin`):
  `build`, `diff`, `decode-table`, `resolve-stubs`, `profiles`.
- What Shoji hooks is the `shoji-windowserver` `PortProfile` in
  `Sources/SpelunkerPort/PortModel.swift`; change it there, with tests.
- Ghidra headless scripts and their analysis record: `Support/ghidra/`.

Shoji keeps only what it consumes:

- Per-build models in `artifacts/macos_versions/<build>/model/` (local,
  ignored by Git), written by `spelunker-port build --out`.
- Build constants in `src/windowserver/gate/target.odin` and
  `src/payloads/windowserver/gate_expected.odin`, copied from a model only
  after the diff and live checks below.
- Its own verification: the gate self-tests
  (`task build:windowserver-abi-selftest`, `build:windowserver-hook-selftest`)
  and live acceptance (`task test:windowserver -- --move-space`, with the
  service stopped first and started again afterwards).

### Porting to a new macOS build

1. `spelunker-port build --profile shoji-windowserver --cache DYLD_CACHE --out
   artifacts/macos_versions/BUILD`
2. `spelunker-port diff artifacts/macos_versions/26B123 artifacts/macos_versions/BUILD`
   (exit 0 `PORT CLEAN`, 3 `PORT NEEDED`). Never carry offsets forward on
   static analysis alone.
3. On `PORT NEEDED`, do the analysis in spelunker (Ghidra scripts, new
   decoders) and keep its results there.
4. Update the build constants, run `task check`, `task test`, the self-tests,
   then the live acceptance. Mark the build supported only after it passes.

### Adding analysis capability

- A new hooked function, framework or table decoder is spelunker code
  (`SpelunkerPort`, a `PortProfile` entry, or a `spelunker-port` command) with
  tests, not a script in this repository.
- Do not add one-off Swift, shell, Java or Ghidra scripts under `tools/`. Run
  experiments in spelunker or a scratch directory, and record conclusions that
  shape Shoji's design in `docs/research/`.
- `tools/` holds only what builds, tests or ships Shoji; remove an experiment's
  code once its findings are written down.
