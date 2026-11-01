# Gating WindowServer: how we built a release-controlled window ordering hold on macOS

*Or: reverse engineering SkyLight, surviving pointer authentication, and
learning that a window you never show is a window that never exists.*

Shoji is a window manager, and window managers on macOS live with an
uncomfortable truth: the compositor owns the truth. AppKit, SkyLight and
WindowServer decide when a window moves, orders, and — crucially — when it
becomes visible. We wanted to know whether a window-ordering decision could
be **held, inspected, and released under external control**, with proof that
the hold actually gates the transition to visibility. Not a hacky "it seems
to work" — measured, timestamped, repeatable proof inside a disposable VM we
were explicitly allowed to break.

This is the story of how far we got, including every way we failed first,
because the failures are where the understanding came from.

## The ground rules

Everything happened in a VirtualBuddy guest ("Shoji Test", macOS 26A434) —
never on the host. Private ABI recovered by static analysis stayed a
*hypothesis* until the runtime corroborated it. Payloads, once installed,
stay resident until WindowServer exits; there is no live unhook. And every
claim had to point at a saved artifact: install reports, event dumps, crash
logs, visibility traces. If it isn't in `artifacts/`, it didn't happen.

## Phase 0: find the exact function, on the exact build

Window ordering flows through SkyLight, a private framework. Using Ghidra on
the guest's *exact* SkyLight build (SHA-256
`b7b3f079…c673`, UUID `8a3b348e…a234`) — not the host's, not "a similar
version" — we traced the indirect call inside `SLSOrderWindow` to
`CGXOrderWindowListSpaceSwitchOptions`, and confirmed the eligibility helper
`_PKGWindowEligibleForSwitchOrderingRelativeTo` tests exactly bit 0 of its
flag argument (`tbnz w2, #0`). Forty-nine exported functions later, the
static model had zero unresolved warnings. REA independently inspected the
shipped binaries to corroborate the loader-side flow.

We also rejected the easy path. Code caves — gaps in the text section —
turned out to contain live unowned instructions, and a search for nearby
allocation space failed across 16,380 candidates with `KERN_NO_SPACE`. So:
no caves. The hook would be a 16-byte inline absolute jump at the function
entry, with a trampoline that replays the exact four-instruction prologue
and jumps back.

## Phase 1: getting code into WindowServer without killing it (we killed it)

The loader injects a tiny copied bootstrap into WindowServer, creates a
remote pthread, and `dlopen`s the payload. Two crashes taught us arm64e
pointer authentication the hard way:

1. **The `pthread_create` crash.** The thread entry function pointer must be
   *signed*. Passing a stripped address: instant `ExcUserFault`.
2. **The 48-bit mask bug.** Stripping PAC bits with a naive
   `ptr & 0x0000FFFFFFFFFFFF` mask destroys more than the signature on
   Apple silicon. The fix was not to strip at all: call the resolved symbol
   through `BLRAA` with a zero discriminator and let the CPU authenticate
   it.

The second lesson generalised into a design rule that saved us repeatedly:
**don't reconstruct pointers, authenticate them.** The payload's entry point
is an exported symbol, `shoji_ws_observer_start`, resolved with `dlsym`,
reported with `dladdr` (so we can verify which image actually loaded), and
invoked exactly once through the `BLRAA` helper. A one-shot guard came
later, after we discovered an embarrassing truth: entry bytes in an install
report proved a hook was *already* installed — an earlier run we had
confidently described as "the constructor never ran" had, in fact, run and
installed fine. Overconfident narration is a bug class too. The guard makes
duplicate invocation harmless instead of silently overwriting the original
install status.

## Phase 2: rewriting instructions other threads are executing

Patching live code in a 20-thread compositor is a race you only get to lose
once. The installer works under an all-other-threads Mach barrier:

1. Suspend every thread, verify each one's PC is **outside** the 16 bytes
   being patched (offsets 4–15 are the kill zone).
2. Privatize the page (`VM_PROT_COPY`-style protection dance using raw
   `mach_vm_protect` — no libSystem stubs, because the target text is
   temporarily non-executable), then write a temporary `B .` — an
   instruction that branches to itself. Any caller arriving mid-install
   *parks* in a two-instruction loop instead of executing a half-written
   jump.
3. Resume, drain, re-suspend, re-verify PCs.
4. Publish the full 16-byte jump, restore exact protections, release the
   barrier.

Even this failed transiently: one run reported barrier entry failure, and
added diagnostics showed a suspended thread simply hadn't reported its
stopped state before a 1,000-cycle spin gave up. The barrier now waits up to
20 ms per thread and retries entry, with a 256-thread cap and per-failure
reason codes. Every subsequent install — 40 consecutive local runs, then the
guest — has been clean.

## Phase 3: watching, then holding

The observer callback records a bounded ring of events (window ids,
operations, result codes, Mach timestamps before/after the forwarded call)
and forwards everything to the original via the trampoline. A separate
control thread — never the callback — handles a tiny file protocol in
`/private/tmp`: `hold <id>`, `release`, `dump`.

First contact was humble and glorious: `SLSOrderWindow` from a guest trigger
app moved the call count 57 → 59, with the new events naming exactly our
window `75`, operations `1` (front) and `0` (out), both returning `0`.

The hold extends the callback: if the call orders our armed target window,
wait — up to a hard timeout — until an external `release` arrives, *then*
forward. `held=1` means released, `held=2` means the timeout fired and the
call forwarded anyway. WindowServer never hangs. A released hold once
completed in 23,907 Mach ticks (~1 ms) when the release was already waiting.

## Phase 4: the visibility plot twist

Proving the call is delayed is easy. Proving *visibility* is delayed is
where we almost fooled ourselves.

Attempt one: query `CGWindowList` with `swift -e` during and after the hold.
Every post-release query "missed" — the window was either still
`onscreen=false` or had zero bounds. Attempt two: realise `swift -e`
*compiles* before it runs; our measurement tool had seconds of latency
built in. So we built a compiled sampler: 2 ms cadence, Mach timestamps,
CSV out.

Then the deeper truth landed. Even unheld, our trigger window never became
visible. Zero bounds, forever. The reason: raw `SLSOrderWindow` on an AppKit
window that was never ordered in does nothing visible — and AppKit on a
process that never pumps its run loop doesn't even *emit* the ordering call
(the event log for that run contains no call for the window at all). The
fix was embarrassingly macOS: `orderFrontRegardless` plus
`runUntilDate:` pumping. Instantly, a working positive control — the window
goes `onscreen=true` with real bounds ~38.5k ticks (~1.6 ms) after the
unheld ordering call.

Now the gated experiment meant something. Window 76, hold armed:

- The ordering call held **14,828,413 ticks (~618 ms)**, released
  externally, forwarded, `result=0`.
- Every sampler observation that completed during the hold:
  `onscreen=false`.
- One query issued ~63k ticks into the hold **blocked for ~656 ms** and
  returned only ~41 ms after the forward — already showing `onscreen=true`
  with real bounds.

That stalled query is the nicest evidence we have: while the ordering call
is held, WindowServer cannot even *answer* a window-list query about the
outcome. No observer can see post-ordering state during the hold, because
the state transition is the held call itself. The window-list visibility
transition is provably gated by our release.

One honest boundary: this is window-list evidence, not pixel evidence. The
frame buffer question — did the compositor present anything early? — needs
ScreenCaptureKit or equivalent, and the guest has Screen Recording
permission denied (`screencapture` can't create images either). That claim
stays open.

## Phase 5: hardening, driven by live bugs

Running the gate exposed its own control channel as the weakest link — each
defect observed live, then fixed:

- **Stale request replay.** A leftover `dump` file was re-executed every
  1 ms poll; we watched the response file's mtime advance every second.
  Worse, a leftover `hold` file *re-armed the gate* after the claim. Fix:
  execute each distinct command once, reject torn reads (every command must
  end with `\n`).
- **Racy claim.** Load-check-store meant two concurrent matching calls could
  both hold. Fix: one `atomic_exchange`.
- **Fake deadline.** The "3 second" timeout counted 3,000 `usleep(1ms)`
  iterations and measured **4.8 s**. Fix: a real `mach_absolute_time`
  deadline from `mach_timebase_info` (now exported in the dump header).
- **Torn snapshots.** The dump bulk-copied the event ring while the callback
  wrote it. Fix: per-event seqlock — the writer publishes the sequence
  number last with release semantics; the reader retries and counts
  unsettled slots as `torn`.
- **Torn reads.** The response was truncated in place; a reader copied
  **0 bytes** mid-rewrite, live, during our own experiment. Fix: write to a
  sibling temp file and `rename`.

The rebuilt payload (cctor13) went into a fresh WindowServer and validated
end to end: one `dump` → exactly one response write; one hold → exactly one
held event (no rearm); released hold 590.4 ms with `held=1`; timeout
**3.002 s** against the 3.000 s deadline with `held=2`; 10/10 racing
response copies complete; `torn=0`; WindowServer healthy, no new crash
reports.

## What we actually proved, and what we didn't

**Proven, with saved evidence:** on an exact macOS 26A434 build, an injected
observer can intercept a recovered SkyLight ordering function inside a live
WindowServer, hold a targeted window's ordering call under external control
for a strictly bounded time, release it on command or fail open on timeout,
and the hold provably gates the window-list visibility transition — with
WindowServer stable throughout.

**Not proven:** prevention of early *displayed frames* (pixel-level),
coverage beyond this one ordering path, input-alignment guarantees, any kind
of production-safe protocol, recovery, or update story — and there is no
unhook short of WindowServer exit.

The gap between those two lists is exactly the size of "demo" versus
"feature". But for a compositor that guards its secrets behind private
frameworks, pointer authentication, and a complete absence of documentation,
a release-gated, evidence-backed ordering hold is a door we were told wasn't
there.

---

*All artifacts, install reports, event dumps and visibility traces referenced
above live under `artifacts/windowserver-vm-probe/` in the Shoji repository.
The experiment is disposable and guest-only; SIP must never be disabled on a
user machine for Shoji.*
