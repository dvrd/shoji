# WindowServer ordering observer experiment

This is a disposable, exact-build experiment for the `Shoji Test` VirtualBuddy
guest only. It is not a production Shoji feature. It implements an observer and
a bounded experimental ordering hold, not a proven complete presentation gate.

The experiment targets one recovered 26A434 SkyLight function,
`CGXOrderWindowListSpaceSwitchOptions`, only after validating the loaded image's
UUID, mapped text range, slide and entry bytes. The observer records bounded
events in memory and forwards every call immediately. File I/O happens on a
separate control thread, never in the ordering callback.

## Current result

Validated in the disposable guest on 2026-10-30 and 2026-10-31:

- WindowServer loaded the observer at a known image base and remained healthy.
- The payload installed a two-phase inline absolute jump. No nearby allocation
  or unsafe code cave was used.
- The first word was temporarily changed to `B .` under an all-other-threads
  barrier; after callers parked only at the entry, the complete 16-byte jump was
  published and the barrier released.
- `SLSOrderWindow` from a guest trigger reached the observer. In one clean run,
  calls changed from 57 to 59; the new events were window `75`, operation `1`
  and window `75`, operation `0`, both returning `0`.
- Timestamped events record Mach time before and after the forwarded original.
- A targeted gate can hold one window ID before forwarding. A hidden trigger
  window existed in the window list during the hold with
  `kCGWindowIsOnscreen=false` and zero bounds.
- External `hold <window-id>` and `release` control requests work through the
  bounded control thread. A released hold records `held=1`; a missing release
  records `held=2`, times out, and forwards the original call rather than
  hanging WindowServer.
- The latest clean install used 21 threads and left WindowServer running after
  release and timeout runs. With the 1 ms control poll, a release already
  written before the callback enters completes with `held=1` and a duration of
  23,907 Mach ticks. A missing release records `held=2`, times out, and then
  forwards normally.
- Barrier retry diagnostics identified the transient failure precisely: a
  suspended thread had not yet reported a stopped/waiting state before the old
  1,000-cycle spin expired. The current barrier waits up to 20 ms per thread.

Evidence:

- `artifacts/windowserver-vm-probe/ws-existing-hook-events-20261030-175037/`
- `artifacts/windowserver-vm-probe/ws-sls-delta-20261030-175458/delta.json`
- `artifacts/windowserver-vm-probe/ws-timed-delta-live-20261030-184210/delta.json`
- `artifacts/windowserver-vm-probe/ws-hold-visibility-sample-20261031-111348/`
- `artifacts/windowserver-vm-probe/ws-gate-release-final-20261031-143821/`
- `artifacts/windowserver-vm-probe/ws-gate-timeout-20261031-143838/`
- `artifacts/windowserver-vm-probe/ws-gate-wait-staged-20261031-192837/`
- `artifacts/windowserver-vm-probe/ws-gate-lowlatency-final-20261031-212932/`

Earlier failures and crash reports are retained. The most important were a
`pthread_create` pointer-authentication failure, a wrong 48-bit strip mask,
failed constructor execution, duplicate invocation overwriting status, and
transient thread-barrier entry failure. The working loader resolves
`shoji_ws_observer_start` with `dlsym`, reports `dladdr` on that symbol, calls
it through a same-section `BLRAA` helper, retries bounded barrier entry, and
uses a one-shot start guard. Local self-injection validates the explicit path
before WindowServer use.

## Boundaries

- The gate is proven to delay a matching ordering call before forwarding. It is
  not yet proven to prevent a composed frame, and the hidden-window result is a
  window-list observation, not pixel/screen evidence.
- A complete presentation gate still needs correlation with frame metadata or
  capture evidence before claims about early-frame prevention.
- The payload and hook are resident until WindowServer exits; no live unhook is
  claimed.
- The current VM has a live observer. Do not run another observer build in the
  same WindowServer session; restart the disposable session first.
- Production use would need a completely different support, recovery, update and
  code-signing story. SIP must not be disabled on a user machine for Shoji.

## Build

```sh
task build:windowserver-ordering-observer
task build:windowserver-ordering-trigger
task loader
```

The payload build is intentionally ad-hoc signed for the disposable guest.
The loader's `--self-test-windowserver-payload` mode validates explicit symbol
invocation in its own process before any WindowServer run.
