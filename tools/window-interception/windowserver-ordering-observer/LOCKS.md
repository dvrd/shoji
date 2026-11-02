# Lock and serialization audit (B2)

Question: when the gate holds a call, what else stalls — and what locks
are we spinning inside?

## Empirical findings (decisive)

1. **Concurrency probe (cctor16, PID 21804)** — window A's transaction op
   was armed and held to the 3.000 s deadline (`held=2`). An independent
   process committed window B ~1.5 s into the hold (its `SLSTransactionCommit`
   returned immediately). **B's op executed ~0.3 ms after A's hold
   expired** — queued for the entire remaining hold. Evidence:
   `artifacts/windowserver-vm-probe/ws-tgate-cctor16-result-20261102-144940/shoji-tgate-concA.response.bin`
   (seq 25 vs 27 timestamps).
2. **No overlap anywhere** — across all gated runs (717 ms / 732 ms /
   3,004 ms holds), no transaction op ever executed inside a hold window.
   Caveat: guest traffic is sparse, so run 1 alone was only suggestive;
   the probe above is the controlled version.
3. **Inline hook, earlier evidence** — an independent `CGWindowList`
   query issued during a hold blocked for the hold's full remainder
   (~600 ms), returning only after the forward. The serialization covers
   even read-only window-list service.

## Static observations

- `PKGTransactionCommit` carries a reentrancy flag (`ldrb w8,
  [x27, #0xc50]` at 0x187451528) and stores the committing connection to
  a global (`str x22, [x8, #0x480]` at 0x187451590) — the commit path
  expects nesting to be tracked, not concurrent commits.
- Dispatch itself is a single indirect call per op (`blraaz`) inside one
  loop; there is no per-connection parallelism in the loop.

## Conclusion

**A hold is globally serializing.** Whether the mechanism is a serial
dispatch queue or a global lock (residual detail; thread-id evidence
could distinguish), every client's transaction — and at least some
read-only services — wait for the held op to forward.

Design consequences:

- The fail-open deadline is the safety bound; 3.000 s measured at
  3,002–3,004 ms consistently.
- **For production the serialization is a feature, not a bug**: it is
  exactly the atomicity a "one-frame layout application" needs — nothing
  interleaves between our gated op and the batch we release after it.
  But holds must shrink from experiment-scale (seconds) to frame-scale
  (a few ms), because the world pauses meanwhile.
- The gate design does not need to change; its *use* must be short and
  rare. Recorded in PLAN B2 as closed with this guidance.

## Residual

- Mechanism (serial XPC queue vs global mutex): record the dispatch
  thread's id in gate events if ever needed; not blocking.
- Whether read-only window services (CGWindowList) share the commit
  serialization or the ordering function's own lock: the inline-hook
  stall suggests shared; not yet mapped per service.
