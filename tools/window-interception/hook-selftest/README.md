# Owned-process arm64e hook self-test

This experimental executable patches only a function in its own anonymous
memory. It does not discover, attach to, or modify Dock or WindowServer.

```sh
task build:windowserver-hook-selftest
./bin/shoji-ws-hook-selftest
```

The test allocates two pages within direct-branch range of its own replacement,
constructs a six-argument function beginning with `PACIBSP`, and constructs
an executable trampoline containing that instruction and a branch back to the
original. It changes the target page from executable to writable and back,
invalidates the instruction cache, and verifies the baseline, replacement call,
all six integer arguments, and return result. It is a single-threaded test;
it does not prove safe patching of a running shared-cache function, instruction
relocation generally, pointer authentication for other compiler boundaries,
or safety inside WindowServer.

On the disposable macOS 27.0.1 / 26A434 guest with SIP and library validation
disabled, the Odin arm64e self-test passed. An earlier variant incorrectly
signed an Odin procedure value, causing its own process to crash with a pointer
authentication fault; it did not modify WindowServer. The corrected variant
uses raw Odin procedure values, consistent with the project's arm64e compiler.
