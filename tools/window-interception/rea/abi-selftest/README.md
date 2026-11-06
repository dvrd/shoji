# Owned native/Odin ABI fixture

```sh
task build:windowserver-abi-selftest
```

Run only in the disposable Shoji Test guest after recording the build and
binary SHA-256. The default command does not attach to WindowServer, load
SkyLight, change memory protections, or patch code:

```sh
bin/shoji-ws-abi-selftest
```

The native compiler calls a signed Odin callback with an opaque context pointer,
three borrowed pointer arrays, a 32-bit count, and a C boolean. Odin forwards
the same arguments to an ordinary native C function. The fixture checks high-bit
and all-ones unsigned values, signed operations -1/0/1, both canonical booleans,
null arrays with a zero count, negative and wide positive results, and exactly
four calls through to the native function. The arrays live on the C caller's
stack for these synchronous calls and are not retained.

## Opt-in native trampoline and execution-barrier experiment

`--trampoline` explicitly modifies only the fixture process's own native text
and owned mappings. Do not run it against WindowServer or on the host:

```sh
bin/shoji-ws-abi-selftest --trampoline
```

The experiment resolves the real native target with `dlsym`, validates its
`PACIBSP` entry, allocates a nearby relay/trampoline, and performs 16 complete
C -> patched C entry -> Odin replacement -> copied-entry trampoline -> original
C round trips. It verifies pointer arrays, signed operations, count, canonical
booleans, and results on every round trip. Entry bytes and aliases are restored
after each cycle.

The native-text page is privatized with `VM_PROT_COPY`, followed by a COW store
and execute-permission restoration. Between those two protection transitions,
only inline storage and raw `dlsym`-resolved libsystem calls are permitted.
Calls through the image's authenticated stubs are unsafe because they can share
the temporarily non-executable page. Earlier crash reports demonstrate this
exact failure mode; they are not evidence of a Mach privatization failure.

The concurrent phase then:

- inventories at most 128 threads using unique thread IDs, suspends every other
  thread, and verifies a second identical inventory;
- proves the completed-call counter does not advance while the other threads
  are suspended;
- privatizes and installs under that barrier, then resumes only after execute
  permission and the relay/trampoline are ready;
- joins every caller before teardown and restores the entry, alias, and original
  current/maximum protections.

The final 26A434 run completed 516,516 calls with 4,012 forwarded calls and zero
errors. A forwarded total need not be divisible by four: a worker can be
suspended in the middle of a native run and complete only its remaining calls
after installation. The run also passed 16 single-thread round trips and the
default ABI mode. WindowServer remained PID 169. Commands, outputs, hashes and
exit statuses are in `artifacts/vm-probe/abi-trampoline-20261028-v14/`.
The binary SHA-256 was
`943958ecdaa686f867e6339b32d045b413bcfefdc3510ebcfd6353bde1831ce0`.
Earlier `abi-trampoline-20261028-*` directories retain connection failures,
alias/protection failures, incorrect target resolution, stub-execution crash
reports, and intermediate assertions rather than overwriting them.

This validates only the selected owned compiler and patch mechanics. It does
not validate the private SkyLight ABI, noncanonical runtime boolean values,
WindowServer's threads/locks/sandbox, reentrancy, or a presentation boundary.
Fixture teardown is externally quiescent. It does not establish safe live
WindowServer unhooking, and no such unhooking is permitted by this experiment.
