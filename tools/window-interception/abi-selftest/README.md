# Owned native/Odin ABI fixture

```sh
task build:windowserver-abi-selftest
```

Run `bin/shoji-ws-abi-selftest` in the disposable Shoji Test guest after
recording its build and the binary SHA-256. It never attaches to WindowServer,
loads SkyLight, changes memory protections or patches code. Build success is
not a runtime pass. On 2026-10-28 the 26A434 guest passed the fixture with exit
status 0. Its binary SHA-256 was
`a94cbbe9e4b11cd8f59fa007dc7938bc85a0dcfdd1bb9c81320d385c132a96d5`.
Raw build identity, output and exit status are retained in the ignored local
`artifacts/windowserver-vm-probe/observe-20261028/c-odin-abi.log`.

The C compiler calls a signed Odin callback with an opaque context pointer,
three borrowed pointer arrays, a 32-bit count, and a C boolean. Odin forwards
the same arguments to an ordinary native C function. The fixture checks:

- high-bit and all-ones unsigned array values;
- signed order values -1, 0, and 1;
- both canonical boolean values;
- a zero count with null arrays;
- negative and wide positive 32-bit results;
- exactly four calls through to the native function.

The arrays live on the C caller's stack for the synchronous calls. The callback
does not retain them. The procedure pointer uses Shoji's existing arm64e signing
bridge. This validates only the selected compiler boundary with owned data. It
does not validate the private ordering function's semantics, accepted nonzero
boolean representations, a trampoline, register preservation under all paths,
WindowServer permissions/threads/locks, or a presentation boundary.
