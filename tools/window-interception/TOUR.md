# The WindowServer investigation: a guided tour

Nine steps, each with the question we asked, where to look, what the
evidence shows, and what it taught us. Run the commands from the repository
root unless marked *(guest)*. Everything referenced is committed or in
`artifacts/` (gitignored, local evidence store).

---

## Step 1 — Find the exact function in the exact build

**Question:** when an app orders a window, what actually executes inside
WindowServer?

**Look:**

```sh
# The input binary (guest's SkyLight, not the host's):
shasum -a 256 artifacts/windowserver-26A434/extracted/SkyLight
# → b7b3f079742fd1f2b34ea98c51affc59fc4360f12592ff36755a7f591f33c673

# The caller map of the choke point:
head -60 artifacts/windowserver-26A434/ghidra/ordering.txt

# The eligibility check, in raw disassembly:
cat artifacts/windowserver-26A434/ghidra/switch-eligibility-disassembly.txt
```

**What you see:** in `ordering.txt`, `CGXOrderWindowListSpaceSwitchOptions`
lists ~45 callers: every ordering entry point (`__XOrderWindow`,
`CGXOrderWindowListWithGroups`, `PKGTransactionOrderWindow`), the window
tiling manager, menu bars, even the cursor callback. In the disassembly,
`tbnz w2, #0` — a test of exactly bit 0 of the flag argument — and note
`pacibsp`/`autibsp`: pointer-authentication instructions bracketing the
function. That instruction pair is why naive hooking crashes (step 2).

**Lesson:** private ABI is a hypothesis until runtime confirms it — but a
good static model tells you *where to look* and what the runtime must
confirm (UUID, slide, entry bytes, all checked later).

**Also see:** `ordering-caves.txt` — the rejected "code cave" plan
(16,380 candidate gaps, all unusable), which forced the inline-jump design.

---

## Step 2 — Inject code into WindowServer (and crash it twice)

**Question:** how do you run your own code inside the compositor?

**Look:**

```sh
# The remote bootstrap and the PAC lesson:
grep -n -A10 'remote_call_function' src/dock/loader_darwin.odin
sed -n '/remote_worker/,/^}/p' src/dock/loader_darwin.odin | head -30

# The preserved crashes:
ls artifacts/windowserver-vm-probe/abi-trampoline-20261028-v11/crash.ips
ls artifacts/windowserver-vm-probe/ws-observer-crash-20261029-135744/
```

**What you see:** `remote_call_function` is three instructions — an `asm`
block whose entire body is `blraa function, key`. The loader `dlopen`s the
payload remotely, resolves `shoji_ws_observer_start` with `dlsym`, and
calls it through that `BLRAA` with a zero discriminator. The crash reports
are the two ways we got it wrong first: an *unsigned* `pthread_create`
entry (instant `ExcUserFault`), and a `ptr & 0x0000FFFFFFFFFFFF` "PAC
strip" that destroys the pointer.

**Lesson:** on arm64e, don't reconstruct pointers — authenticate them. Try
the proof locally, no VM needed:

```sh
task build:windowserver-ordering-observer loader
./bin/shoji-loader --self-test-windowserver-payload bin/shoji-ws-observer.dylib
# → "WindowServer payload image: path=... dladdr=1 invoked=1"
```

---

## Step 3 — Rewrite instructions other threads are executing

**Question:** how do you patch 16 bytes of live code in a 20-thread
compositor without a single thread executing a half-written jump?

**Look:**

```sh
sed -n '1,80p' src/experimental/window_server/branch.odin   # the two-phase plan
grep -n -A20 'enter_execution_barrier ::' src/experimental/window_server/barrier.odin
```

**What you see:** `plan_inline` builds the 16-byte absolute jump and the
trampoline that replays the exact four-instruction prologue. The installer
(1) suspends all other threads and verifies each PC is *outside* the patch
zone, (2) writes a temporary `B .` (branch-to-self) at the entry — any
caller arriving mid-install parks in a 2-instruction loop — (3) resumes,
drains, re-suspends, re-checks PCs, (4) publishes the full jump and
restores exact page protections.

**Lesson:** the transient install failure that motivated the retry logic
was a thread that "hadn't reported stopped yet" before a 1,000-cycle spin
expired — the barrier now waits 20 ms per thread and reports
`barrier_last_failure` reason codes. The fixture that proves the mechanism
without WindowServer:

```sh
cat tools/window-interception/abi-selftest/README.md
```

---

## Step 4 — Watch real ordering calls live

**Question:** does the hook actually see app window ordering?

**Look:**

```sh
cat artifacts/windowserver-vm-probe/ws-sls-delta-20261030-175458/delta.json
```

**What you see:** `baseline_calls: 57`, `after_calls: 59` — and the two new
events name window `75`, operations `1` (front) and `0` (out), both
`result: 0`, on one connection. That is a guest trigger app's
`SLSOrderWindow` flowing through our callback inside WindowServer, recorded
with Mach timestamps and forwarded untouched.

**Lesson:** the observer records and *forwards* — it never changes
behavior. Event ring: `Observer_Event` in
`windowserver-ordering-observer/main.odin` (sequence published last, for
reasons that matter in step 6).

---

## Step 5 — Hold a window hostage, release on command

**Question:** can one targeted ordering call be delayed until an external
signal — with the compositor surviving?

**Look:**

```sh
# The hold logic in the callback:
sed -n '/^ordering_observer/,/^}/p' tools/window-interception/windowserver-ordering-observer/main.odin | head -30

# Released hold (fast path) and timeout evidence:
python3 -c "
import struct
d = open('artifacts/windowserver-vm-probe/ws-gate-lowlatency-final-20261031-212932/response.bin','rb').read()
off = 40
for i in range(256):
    seq, conn, before, after = struct.unpack_from('<QQQQ', d, off)
    held = struct.unpack_from('<I', d, off+48)[0]
    ids = struct.unpack_from('<4I', d, off+52)
    if held: print(f'window={ids[0]} held={held} duration={(after-before)} ticks')
    off += 104"
# → window=56 held=1 duration=23907 ticks   (~1 ms, release already waiting)
# → window=57 held=2 duration=114708473 ticks (~4.8 s "3 s timeout" — see step 6)
```

**What you see:** `held=1` means released externally, `held=2` means the
timeout fired and the call forwarded anyway. WindowServer never hangs.

**Lesson:** fail-open beats fail-safe when your crash kills the whole
session.

---

## Step 6 — The control channel was the weakest link

**Question:** what breaks when you actually use the gate?

**Look — every defect was observed live before it was fixed:**

| Defect (evidence) | Fix (commit `fc9b460`) |
| --- | --- |
| Response file mtime advancing every second on a *stale* `dump` request (watch it: `ws-gate-hardened-result-*/SUMMARY.md` §1) | Execute each distinct command once |
| Leftover `hold` file re-armed the gate after claim | (same fix) |
| Load-check-store claim — two calls could both hold | Single `atomic_exchange` |
| "3 s" timeout measured **4.78 s** (`held=2` above: 114.7M ticks) | `mach_absolute_time` deadline → re-measured **3.002 s** (72,043,732 ticks) |
| Bulk event copy could tear against the writer | Per-event seqlock + `torn` counter |
| A reader copied **0 bytes** of the response mid-rewrite | Write temp + `rename` |

**Verify the hardening yourself:**

```sh
cat artifacts/windowserver-vm-probe/ws-gate-hardened-result-20261101-140003/SUMMARY.md
```

**Lesson:** the interesting bugs are never in the hook; they're in the
plumbing around it.

---

## Step 7 — Visibility: the plot twist

**Question:** does the held window become *visible* before release?

**Look:**

```sh
# The sampler that replaced swift -e (whose compile latency missed everything):
head -30 tools/window-interception/visibility-sampler/main.swift

# The run where the trigger window never appeared at all:
cat artifacts/windowserver-vm-probe/ws-visibility-gated-20261101-131239/baseline2-run.console
# and note: window 74 has NO events in the dump — AppKit never even emitted
# the ordering call, because nothing pumped the run loop.
```

**What you see in the gated run** (`ws-visibility-gated-20261101-131239`):
row 145 of the sampler CSV started its query 63k ticks into the 618 ms hold
and **blocked for 656 ms**, returning only after the forward with
`onscreen=true`. The held call stalls the window-list service itself — no
observer can see post-ordering state during the hold.

**Lesson:** raw `SLSOrderWindow` on a never-ordered-in AppKit window does
nothing visible; AppKit on a non-pumped run loop does nothing *at all*. The
positive control (`orderFrontRegardless` + `runUntilDate:`) goes onscreen
~38.5k ticks (~1.6 ms) after the unheld call. You cannot measure a
mechanism you don't understand — we almost "proved" the gate against a
window that was never going to appear anyway.

---

## Step 8 — Pixels, or it didn't happen

**Question:** bookkeeping aside — did the compositor put the window's
pixels on screen during the hold?

**Look:**

```sh
cat artifacts/windowserver-vm-probe/ws-pixel-gate-20261101-135411/SUMMARY.md
head -8 artifacts/windowserver-vm-probe/ws-pixel-gate-20261101-135411/shoji-pixel-term-gated.frames.csv
```

**What you see:** ScreenCaptureKit's `displayTime` (WindowServer's own
display timestamp, same Mach clock as our events). Three gated runs, holds
of 601–622 ms, **zero complete frames inside the hold window**; first
complete frame 38–43 ms after each forward. Baseline: 119 ms unheld
(slow virtual-display cadence).

**The three failures preserved along the way** (SUMMARY.md §"Failed
intermediate attempts"): TCC consent attaches to Terminal not the binary;
`TCC.db` is data-vaulted even for root; `CGS_REQUIRE_INIT` abort without
`NSApplication.shared`; and our own request-dedup producing a stale dump.

**Lesson:** "the window list says invisible" and "the display never showed
it" are different claims. Now both are proven.

---

## Step 9 — The coverage map: what one hook actually owns

**Question:** what fraction of "appearing on screen" does the hook control?

**Look:**

```sh
cat tools/window-interception/windowserver-ordering-observer/COVERAGE.md
head -20 artifacts/windowserver-26A434/ghidra/coverage-map.txt   # 2,569 functions
```

**What you see:** 123 functions converge on our hook — the *entire* intra-
space z-order family. And 390 bypass it, in three clean families: **space
membership/switching**, **surface bind/opacity/bounds**, **window
bounds/transform**. All three are `PKGTransaction*` operations — and
`PKGTransactionCommit` has exactly four XPC callers
(`_SLSTransactionCommit`, `__XTransactionCommitSync/Async`,
`sls_transaction_commit_ca`), while none of the 59 mutators calls it
directly: the commit machinery dispatches indirectly.

**Lesson:** one of four visibility channels is fully gated — call, window
list, and pixels. The other three all flow through one commit machinery
whose dispatch table is the next investigation. That's the difference
between "we hooked a function" and "we know what we own."

---

## Where everything lives

| What | Where |
| --- | --- |
| The payload (hook + hold + control) | `tools/window-interception/windowserver-ordering-observer/` |
| Loader, bootstrap, PAC rules | `src/dock/loader_darwin.odin` |
| Inline patch + thread barrier | `src/experimental/window_server/` |
| Trigger / sampler / capture probe | `tools/window-interception/ordering-trigger`, `visibility-sampler`, `tools/harness/capture-probe` |
| Ghidra scripts + exports | `tools/window-interception/ghidra/`, `artifacts/windowserver-26A434/ghidra/` |
| All run evidence | `artifacts/windowserver-vm-probe/` (each run: console, CSVs, `response.bin`, SUMMARY) |
| The story | `windowserver-ordering-observer/BLOG.md` |
| The reference | `windowserver-ordering-observer/README.md`, `COVERAGE.md` |

Suggested reading order for the code: `loader_darwin.odin` (injection) →
`branch.odin` (patch plan) → `barrier.odin` (thread safety) →
`windowserver-ordering-observer/main.odin` (the hook and gate).
