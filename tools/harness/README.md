# Test and validation harness

`task build:harness` builds `bin/harness`. Use `task build:tools` to prepare
its companion dev and inspector executables for the complete validation workflow.

```sh
task test:harness
task test:compiler
task test:motion
./bin/harness validate --preflight-only
```

The harness owns compiler regression fixtures, validation reports, disposable
window/Space fixtures and crash-recovery checks. Its regression suite also tests
the development and inspector modules and shared service/process behavior.
`fixtures/desktop` supplies the native window fixture and headless motion runner;
`fixtures/cancellation` exercises interruption/timeout ownership without touching
other desktop processes.

Live checks are explicit:

```sh
./bin/harness live desktop
./bin/harness live spaces
./bin/harness live animation
./bin/harness live windowserver [--move-space]   # task test:windowserver
```

The desktop and windowserver checks refuse an existing daemon. The windowserver
check runs the Shoji.app binary (its sudoers rule and Accessibility approval)
with `windowserver_gate on` and compares every frame with WindowServer's bounds.
`fixtures/ws-abi-selftest` and `fixtures/ws-hook-selftest` are the gate's
in-process ABI and hook self-tests (`task build:windowserver-*-selftest`). Space cleanup uses only the
returned disposable Space ID. Payload reload/Dock restart requires its explicit
option and policy/recovery guards. Process cleanup targets owned command groups;
evidence and cleanup failures produce nonzero results and preserve original errors.
No live checks run merely by building the harness or running `task test:harness`.

For a guest without the Odin toolchain, copy the built `harness-fixture` beside
the other binaries and pass `--prebuilt-fixture` to a live check. The harness
verifies the fixture's code signature and prints its SHA-256 instead of
recompiling it. The ordinary path still builds the fixture from source.

`validate` invokes Taskfile for builds, the dev CLI for archive creation, and the
inspector for bootstrap/archive checks. It records pending live checks accurately.
