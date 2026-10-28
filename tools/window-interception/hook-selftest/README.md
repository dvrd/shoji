# Owned-process arm64e hook self-test

This experimental executable patches only a function in its own anonymous
memory. It does not discover, attach to, or modify Dock or WindowServer.

```sh
task build:windowserver-hook-selftest
./bin/shoji-ws-hook-selftest
```

The test allocates three pages within direct-branch range of its own replacement,
constructs a six-argument function beginning with `PACIBSP`, and constructs
an executable trampoline containing that instruction and a branch back to the
original. It patches the target through a writable alias of the executable page,
invalidates the instruction cache, and verifies the baseline, replacement call,
all six integer arguments, return result, and rejection of a second patch. It
also verifies 100 install/restore/release cycles, rejection of a conflicting
instruction, and retained ownership/retry after an injected deallocation failure.
`Hook_State` owns one alias at a time and rejects reinstalling while cleanup is
pending. Teardown restores the original instruction before releasing the alias.

The lifecycle tests run single-threaded. A subsequent stress test starts four
pthread callers, waits for at least 10,000 original results, and installs the
hook while those callers run. Across four million calls it requires only
original or hooked results and matching replacement-call counts. All workers
join before teardown, establishing quiescence for this fixture only.

This does not prove safe patching of a running shared-cache function, instruction
relocation generally, pointer authentication for other compiler boundaries,
or safety inside WindowServer. `teardown_quiescent` requires an external barrier
that stops new calls and drains in-flight calls; it does not implement that
barrier. No live WindowServer unhooking is enabled.

The deallocator is passed in as a correctly typed raw procedure resolved from
libsystem_kernel, using Shoji's existing loader facilities. This avoids an
incorrect pointer argument in the current Odin SDK declaration; the native Mach
ABI itself has not changed. Failed releases retain the address for retry rather
than losing ownership or allocating another alias. A separate regression models
an already-restored instruction left by failed read-back verification; retry
accepts both original words and releases the alias without accepting partial or
unexpected words. The guest passed this regression and the stress test on
2026-10-28; local evidence is in `teardown-retry.log`.

On the disposable macOS 27.0.1 / 26A434 guest with SIP and library validation
disabled, the Odin arm64e self-test passed. An earlier variant incorrectly
signed an Odin procedure value, causing its own process to crash with a pointer
authentication fault; it did not modify WindowServer. The corrected variant
uses raw Odin procedure values, consistent with the project's arm64e compiler.
