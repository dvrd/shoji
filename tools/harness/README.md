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
```

The desktop check refuses an existing daemon. Space cleanup uses only the
returned disposable Space ID. Payload reload/Dock restart requires its explicit
option and policy/recovery guards. Process cleanup targets owned command groups;
evidence and cleanup failures produce nonzero results and preserve original errors.
No live checks run merely by building the harness or running `task test:harness`.

`validate` invokes Taskfile for builds, the dev CLI for archive creation, and the
inspector for bootstrap/archive checks. It records pending live checks accurately.
