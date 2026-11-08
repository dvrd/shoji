# WindowServer gate payload

This package is the payload Shoji loads into WindowServer
(`task build:windowserver-payload` → `bin/shoji-ws.dylib`, loaded by
`shoji --ws-attach`). The gate engine it serves lives in
`src/windowserver/gate/`; the daemon side is `src/ws_adapter.odin` and
`src/ws_attach_runtime.odin`. `task test:windowserver` is the live acceptance
check (`tools/harness/harness/live_windowserver.odin`).

Supported build: macOS 26B123 (`BUILD` in `src/windowserver/gate/target.odin`),
live-verified on a physical M1 Max: ordering hook, transaction-table gate
(dispatch redirected to a private table copy because `__AUTH_CONST` cannot be
made writable) and C1/C2/C4 through the Shoji daemon. Every other build, and
every refused or failed state, falls back to Shoji's native Accessibility paths.

## Production attach

1. `task install:windowserver` installs the payload root-owned in
   `/Library/GPUBundles/ShojiWindowServerProbe/` and prints the sudoers line.
   See [SIP.md](../../../SIP.md) for the privileged setup.
2. `shoji -m config windowserver_gate on` (in shojirc) makes the daemon run
   `sudo -n shoji --ws-attach` in the background; the config run never waits.
   Outside the daemon, `SHOJI_WS_ADAPTER=1` opts a process in.
3. `--ws-attach` (root, no arguments) refuses on the `DISABLED` sentinel, another
   build, or a payload/directory writable by anyone but root. It injects unless
   the status file proves this WindowServer already serves a gate, adds its own
   CDHash to the `clients` allowlist (newest 16 kept) and hands a send right to
   the daemon's session rendezvous. The daemon still has to pass HELLO.
4. Transient failures retry 5 times (2 s doubling to 30 s); refusals (exit 3)
   stop at once. `shoji service status` shows the `gate` row and its cause.

After HELLO the daemon sends `Capabilities`. A payload that supports it
reports `LayoutSubmit` (a whole layout of up to 32 moves in one Mach message)
and its item limit; an older payload answers status 1 and the daemon keeps the
legacy `LayoutBegin`/`LayoutAdd`/`LayoutArm` sequence of at most 8 moves.
`shoji -m debug ws status` shows which protocol is in use.

While a trackpad swipe drags the scroll strip, and while the camera spring
runs, the daemon sends each frame's window moves as one batch and resyncs
Accessibility once the camera is still
(`scroll_camera_apply` in `src/manager.odin`).

The payload stays resident until WindowServer exits; there is no live unload.
Logging out does not restart WindowServer, so a new payload needs
`sudo killall -9 WindowServer` (this logs you out).

## Authorization

The gate's Mach owner is first-HELLO-wins, identified by audit-token PID and
PID version. Every command requires an authorized client CDHash, read through
`csops_audittoken`, so a client cannot claim an identity. Two sources
authorize a client:

- CDHashes pinned at build time (`-define:SHOJI_GATE_CLIENT_CDHASH`; no current
  build uses it).
- The `clients` allowlist beside the payload (one 40-hex CDHash per line),
  reread on every HELLO. `--ws-attach` adds the running binary itself, so a
  rebuilt Shoji is trusted on its next attach. The payload ignores the file unless the file and its directory are
  root-owned and not group- or world-writable (`gate_allowlist_trusted`).

Trust comes from root ownership: anything that can write the allowlist already
has root. A Shoji update therefore needs no payload rebuild, and the
Accessibility grant survives because TCC keys on the signing certificate.
An owner that dies is reclaimed by the next verified HELLO, only when
`kill(pid, 0)` reports ESRCH.

## Failure and recovery

Recovery is bounded at every level:

1. A claimed hold fails open at its 3 s deadline (`held=2`) and forwards the
   original call, so a dead or stalled controller never pins a window.
2. A controller polls its gate right (`mach_port_type`) and exits when the gate
   dies instead of racing a successor.
3. Owner death is reclaimed by the next verified HELLO (above).
4. The kill switch refuses injection before anything is touched:
   `sudo touch /Library/GPUBundles/ShojiWindowServerProbe/DISABLED`
   (remove it to re-enable), or `SHOJI_WINDOWSERVER_DISABLE=1`. It does not
   unload a resident payload; it takes effect at the next WindowServer start.

Do not unhook live code or retry injection blindly after a crash: keep the
crash report, set the kill switch, restart WindowServer and attach again.

## macOS updates

Exact-build checks make an OS update fail safe. The loader and payload verify
the SkyLight image UUID and the hooked entry bytes; a mismatch installs
nothing, the adapter finds no gate (`Absent`) and Shoji uses native paths.
`shoji --ws-report` then shows `payload supports 26B123: no`.

Porting a new build uses `spelunker-port` from the separate spelunker project
(`task install:port` there; profile `shoji-windowserver`):

1. `spelunker-port build --profile shoji-windowserver --cache DYLD_CACHE --out
   artifacts/macos_versions/BUILD` writes `model/model.json` (UUID, entry
   bytes, dispatch table, op map) and `model/transaction-dispatch-table.txt`.
   Ghidra (spelunker's `Support/ghidra`) is needed only when the diff shows
   changes.
2. `spelunker-port diff artifacts/macos_versions/REF artifacts/macos_versions/BUILD`
   prints `PORT CLEAN` or `PORT NEEDED` with the changed fields (exit 0 or 3).
   Never copy offsets forward on static analysis alone.
3. Update the build constants (`target.odin`, `gate_expected.odin`,
   `WS_SUPPORTED_BUILD`), then run `task test` and the ABI selftests
   (`task build:windowserver-abi-selftest`, `build:windowserver-hook-selftest`).
4. Live acceptance: stop the service (`shoji service stop`), run
   `task test:windowserver -- --move-space`, then `shoji service start`. It runs
   an isolated daemon with the gate on and checks swap (C1), focus (C2) and a
   Space move (C4) against WindowServer's own bounds; evidence is printed.
5. Mark the build supported only after step 4 passes.

## Diagnostics

`shoji --ws-report [DIR]` prints the macOS build against the supported build,
the kill switch, payload sha256 and residency, this binary's CDHash, allowlist
trust and membership, and the gate state. With `DIR` it also exports the event
ring (`ws-ring.bin` and decoded `ws-ring.json`), through the daemon
(`debug ws dump`) when the daemon owns the gate, otherwise by claiming the gate
briefly.

The decoder refuses truncated, torn and inconsistent snapshots. Keep
credentials and SSH keys out of diagnostic bundles.

### Ring format (version 3)

40-byte header: `magic[8]`, `version`, `calls`, `entry`, `branch_word` (u64
each), then `timebase_numer`, `timebase_denom`, `torn` (u32 each) and 4 bytes
of alignment padding. Then 256 events of 104 bytes: `sequence`, `connection`,
`before`, `after` (u64 Mach ticks), `count`, `flag`, `result` (i32),
`captured`, `held` (u32), then `ids[4]`, `operations[4]` (i32), `relative[4]`.
`sequence` is zero for empty or dropped (torn) slots and is published last by
the writer; `held` is 0 normally, 1 when externally released, 2 on timeout.

## What the experiment established

The gate began as a disposable VM experiment on 26A434 (October 2026). Its
conclusions still shape the design:

- The hook is a two-phase inline absolute jump published under an
  all-other-threads barrier (first word `B .`, then the full 16 bytes). Barrier
  entry accepts suspended threads that are stopped, waiting, halted or in an
  uninterruptible wait, bounded at 20 ms per thread.
- Ordering-callback work stays in memory; file I/O runs on a separate control
  thread. Event copies use a per-event seqlock, responses are published by
  rename, and hold deadlines use `mach_absolute_time`.
- A held `CGXOrderWindowListSpaceSwitchOptions` call holds presentation:
  ScreenCaptureKit saw zero complete frames of the held window during
  600 ms holds, and the first frame landed 38–43 ms after release.
- The ordering hook covers intra-space z-order only. Space switches, surface
  updates and bounds/transform changes go through `PKGTransactionCommit`,
  which is why the payload also gates the transaction dispatch table.
- Earlier failures worth remembering: a `pthread_create` pointer-authentication
  fault, a wrong 48-bit strip mask, duplicate invocation overwriting status,
  and a stale request file re-arming every poll.

## Build

```sh
task build:windowserver-payload        # bin/shoji-ws.dylib
task build:windowserver-abi-selftest   # owned C/Odin ABI fixture
task build:windowserver-hook-selftest  # hook install/remove in its own process
```

The loader's `--self-test-windowserver-payload` mode validates symbol
invocation in its own process before any WindowServer run.
