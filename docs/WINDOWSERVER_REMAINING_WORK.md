# WindowServer presentation gate: remaining work

## Goal and current boundary

Prevent one explicitly allowlisted fixture window from becoming visible or
interactive until Shoji approves its placement. Prove the result independently
before expanding to other applications or macOS builds.

**The presentation gate is not implemented. No WindowServer ordering hook has
been installed.** Successful loading, memory probes, and owned-process hook
tests are prerequisites, not evidence of first-frame prevention.

This is the handoff/backlog after the 20-million-call concurrency experiment.
All unchecked items below remain work, including steps previously announced
in conversation but not executed.

## Verified baseline

| Area | Evidence and limits |
| --- | --- |
| Environment | Disposable Shoji Test VM: macOS 27.0.1 / 26A434, arm64e. Guest SIP and library validation were disabled. Host settings were not changed. |
| Recovery | A powered-off clean recovery copy was created under `~/Library/Application Support/VirtualBuddy/Shoji Test - Clean Recovery.vbvm`. Recheck its availability before further experiments. |
| Loading | Existing Odin arm64e loader reached `dlopen` in WindowServer using a payload under `/Library/GPUBundles`. |
| Sandbox | Tested Unix socket bind and outbound connection were denied. One-shot two-way file exchange worked; it is not an authenticated control channel. |
| Executable allocation | WindowServer probe reported `execute-permitted` for a newly allocated page. It did not execute a trampoline or modify existing instructions. |
| Candidate analysis | Several ordering and transaction paths reach the candidate documented in `WINDOWSERVER_26A434_ORDERING.md`. A caller consumes its integer result. Coverage and full argument semantics remain incomplete. |
| Owned hook | Anonymous target, relay, and trampoline forward six integer arguments and a result in Odin. This is not the private SkyLight ABI. |
| Ownership | `Hook_State` retains one alias, rejects duplicate installation, restores/reclaims under caller-established quiescence, and preserves ownership on release failure. Conflict and retry tests passed. |
| Concurrency | Five VM runs, four callers and four million calls per run: only expected original/hooked results, matching call counts. All workers joined before teardown. |
| Mapped SkyLight | An owned-process probe changed the candidate page's protections to writable with copy-on-write and back. It did not modify bytes or verify cross-process isolation. |
| Project checks | Last recorded suite: 303 tests passed; self-test build and `git diff --check` passed. Re-run checks after relevant changes. |

## Ordered backlog

### 1. Shared-cache isolation in an owned process — completed for the recorded fixture

Files: `tools/window-interception/mapped-protection-probe/main.odin`,
`src/addition/windowserver/hook/branch.odin`.

The 26A434 guest's owned-process experiment passed with an independently
launched witness observing an unchanged full page before, during and after an
alias-propagated modification. The patcher verified its restored full page and
both current and maximum protections and released the alias. An earlier run
found that privatization increased maximum protection from 0x5 to 0x7; an
explicit maximum-protection transition restored 0x5 in the final passing run.
A separate controller-EOF test restored the page and exited with status 1. Raw output, binary hashes and exit statuses are
in ignored local files under `artifacts/windowserver-vm-probe/observe-20261028/`;
the build and guest run commands are in the probe README. This does not prove
WindowServer permissions, concurrent instruction safety, or restoration of the
original mapping identity.

- [x] Extend the probe with explicit observe-only and controlled patch modes.
- [x] Record the loaded image identity, slide, candidate address, full expected
  entry bytes, page size, and original protections.
- [x] Establish a genuinely private target page before changing its contents.
  A successful protection call alone does not prove that a subsequent shared
  alias write cannot affect another process.
- [x] Start an independent witness process before the experiment. Record its
  candidate bytes before, during, and after the test, including while the
  modified word remains present in the first process.
- [x] Verify alias propagation to the intended private executable mapping,
  exact restoration, alias release, and unchanged witness bytes.
- [x] Verify the whole affected page after restoration, not only the entry word.
- [x] Keep the private server function uncalled in this probe; no valid server
  connection/context has been established in the owned process.
- [x] Save commands, binary hashes, outputs, exit statuses, and witness results.

**Completion evidence:** overlapping two-process observation proves the intended
mapping changed and the witness did not; original bytes/protections are restored
and resources released. The final run is
`isolation-maximum.log`; the earlier maximum-protection discrepancy is in
`isolation-protections.log`. This still does not establish WindowServer
permissions.

### 2. Complete the installer and lifetime contract — next step

Depends on step 1 for shared-cache applicability.

Failure-state review note: `teardown_quiescent` leaves `installed` true if
verification fails after it writes the original word. A later retry currently
requires both mappings to contain the branch, so it cannot complete if the
first write took effect and both mappings subsequently contain the original.
The pure decision test and an owned-process regression now exercise the exact
already-restored state through the real teardown path. The guest passed that
regression and four million concurrent calls; see `teardown-retry.log`. This is
a modeled state, not an injected read-back fault inside the installer. Partial
and unexpected words still preserve ownership.

An alias-first shared-cache experiment requested a writable copy-on-write alias
without first making the original mapping writable. The protection transition
failed with Mach error 2 before any byte write; its alias was released and the
controller failed closed (`isolation-alias-first.log`). This rules out that
shortcut for the recorded mapping, not every possible remapping mechanism.

- [ ] Gate installation by exact supported image identity/build, executable
  range, and a sufficiently specific byte sequence. `PACIBSP` alone is not an
  identity check; never apply the known address to another image/build.
- [ ] Validate readable/executable ranges before dereferencing candidate bytes.
- [ ] Make target-page privatization and its permission transitions safe for
  concurrent execution. Alias writing avoids one transition but does not solve
  the earlier privatization step.
- [ ] Establish the architectural instruction-publication/cache-coherency
  requirements for alias writes. The stress test is empirical evidence, not a
  complete proof for arbitrary cores, mappings, or instruction sequences.
- [ ] Finalize nearby relay/trampoline allocation, bounded search in both
  directions, branch reach checks, and instruction/return-address handling.
- [ ] Cover allocation, remap, protection, and verification failures. Confirm
  which states are unmodified, partially installed, or awaiting cleanup.
- [ ] Preserve ownership after every post-write failure; a false return cannot
  be interpreted as permission to free potentially reachable code.
- [ ] Serialize installers and teardown; do not copy live `Hook_State` values.
- [ ] Bound relay, trampoline, alias, and observer storage together, not just
  the alias page. Verify no growth across repeated failed attempts.
- [ ] Decide the initial lifetime policy: resident until process exit is
  acceptable for the VM experiment. Never unload the payload while a branch,
  callback, worker, or in-flight return can reference it.
- [ ] If live teardown is required later, implement an actual barrier preventing
  new entries and draining old calls. An active-call counter reaching zero is
  insufficient by itself. Fixture `pthread_join` is not a WindowServer barrier.

**Completion evidence:** checked installer preconditions and failure-state
tests, plus documented safe installation and code-lifetime strategy for the
exact target process.

### 3. Recover the full ABI and presentation paths

Can proceed alongside steps 1–2 using the exact guest artifact.

A build-specific static ABI ledger is now recorded in
`WINDOWSERVER_26A434_ORDERING.md`, including six argument roles, 32-bit array
indexing, the count-dependent state allocation, and observed status values.
Its evidence is exported to the ignored local
`artifacts/windowserver-26A434/rea-ordering-evidence-v3.json`. Array ownership,
nonzero boolean representation, thread/lock/reentrancy behavior, and runtime
presentation boundaries remain unresolved; this does not complete step 3.

- [ ] Verify each argument's type, width, array length, ownership, and lifetime,
  including boolean representation and integer error semantics.
- [ ] Confirm native-to-Odin replacement calls and Odin-to-original trampoline
  calls preserve the native ABI, pointer authentication, and register state.
- [ ] Determine caller threads, locks held, reentrancy, recursive calls, and
  whether arguments can be retained beyond the synchronous call.
- [ ] Trace creation, initial ordering, group ordering, transaction commit,
  level changes, restored windows, and lower-level ordering paths that bypass
  the candidate.
- [ ] Identify the latest safe boundary before composition and before input/
  focus eligibility. Decide whether one hook can enforce both requirements.
- [ ] Establish safe replay/release context and error handling; do not assume
  an arbitrary worker can invoke a server entry point later.

**Completion evidence:** build-specific ABI and path map with unresolved paths
explicitly listed and a concrete runtime observation plan.

### 4. Forwarding-only WindowServer observer

Depends on steps 1–3. No hold or altered return values in this stage.

- [ ] Repeat necessary memory-permission tests inside WindowServer's sandbox;
  anonymous executable allocation does not prove shared-cache remap permission.
- [ ] Resolve and validate the candidate in the running exact-build image.
- [ ] Install the forwarding-only observer with bounded startup and explicit
  diagnostic status. Keep unsupported targets untouched.
- [ ] Forward original arguments and preserve the original integer return.
- [ ] Record fixed-size events into a bounded concurrent queue. Define overflow,
  recursion, sequence, timestamp, and dropped-event behavior.
- [ ] Keep allocation, blocking locks, filesystem/socket I/O, logging, and
  Accessibility calls out of the hook callback.
- [ ] Drain observations outside the callback using a sandbox-permitted path.
- [ ] Correlate fixture creation, show/hide, ordering, destruction, and repeated
  launches with observed events. Resolve window owner identity, not just IDs.
- [ ] Compare baseline and observer runs for visual behavior, errors, response
  latency, CPU usage, and WindowServer stability.

**Completion evidence:** fixture lifecycle events correlate with forwarding
observations, original behavior is preserved, and missing paths are explained.

### 5. Authenticated, bounded control channel

Transport design can proceed in parallel with ABI work. It must be complete
before accepting placement/release decisions.

- [ ] Select and verify file-backed or Mach-compatible IPC under the actual
  sandbox. Do not reuse the denied socket design as if it were working.
- [ ] Define trusted endpoint provisioning and mutual controller/payload
  identity. UID-owned marker files and echoed random requests are insufficient.
- [ ] For files, address symlinks, hard links, replacement races, ownership,
  modes, partial writes, stale endpoints, and atomic publication using verified
  handles rather than trusting path names alone.
- [ ] Define versioned messages, strict size limits, session nonce, sequence
  numbers, freshness, replay rejection, acknowledgements, and timeout behavior.
- [ ] Tie messages to controller/server sessions and a generation-safe window
  identity. Reused PIDs/window IDs must not accept an old approval.
- [ ] Bound queue size, disk/memory consumption, polling cost, and retry rate.
- [ ] Test malformed input, unauthorized writers, stale messages, disconnects,
  controller restart, server restart, and unavailable storage/transport.
- [ ] Update `--check-ws` and capability reporting to distinguish loaded,
  observing, channel-ready, and hold-enabled states accurately.

**Completion evidence:** authenticated round trips and failure/replay tests in
the VM with no control-channel work performed in the hook callback.

### 6. Fixture-only presentation hold state machine

Depends on observer evidence, presentation-boundary analysis, and working IPC.

- [ ] Define an explicit fixture allowlist tied to verified process identity.
- [ ] Model observed, held, approved, released, cancelled, expired, and destroyed
  states, with monotonic deadlines and idempotent transitions.
- [ ] Bound held-window count and pending decisions; define fail-open behavior
  on capacity exhaustion, queue overflow, invalid messages, and internal errors.
- [ ] Hold before first composition without falsely reporting incompatible
  success or blocking a WindowServer request thread indefinitely.
- [ ] Prevent focus, activation, pointer, and keyboard eligibility while held.
- [ ] Establish ownership or safe copies for any deferred data. Never retain
  borrowed stack pointers or assume an ordering request can be blindly replayed.
- [ ] Handle grouped requests containing both allowed and unrelated windows
  without violating transaction atomicity or delaying unrelated applications.
- [ ] Release only from the verified execution context, preserving required
  transaction/order semantics and avoiding recursive re-holding.
- [ ] Cancel on destruction, connection loss, relaunch, session change, and
  stale generations. Test timeout/release/destroy races and duplicate approval.
- [ ] Implement autonomous expiry/fail-open recovery that still functions when
  Shoji or the transport stops responding.

**Completion evidence:** transition and race tests plus VM demonstration of
bounded holds, correct release, cancellation, and autonomous recovery.

### 7. Shoji placement integration

Depends on steps 5–6.

- [ ] Deliver early window identity to Shoji and correlate it with its existing
  window model without requiring the window to have already become visible.
- [ ] Determine when placement APIs become usable for held windows.
- [ ] Compute and apply the approved frame/workspace while held, then verify the
  change was applied before issuing release approval.
- [ ] Define fallback when metadata, layout, or placement is unavailable or late.
- [ ] Avoid duplicate layout/opening handling when ordinary notifications arrive.
- [ ] Reconcile focus, animation, cancellation, and window destruction with
  Shoji's existing engine. Record which component owns each transition.
- [ ] Keep the experiment opt-in and expose actionable diagnostics rather than
  silently claiming a hold when only a load probe is available.

**Completion evidence:** a fixture reaches its approved placement before release
and normal lifecycle handling remains consistent afterward.

### 8. Independent visual and input proof — fixture milestone

Depends on step 7; capture tooling can be prepared earlier.

- [ ] Build a conspicuous fixture with a recognizable initial wrong position,
  visible content, delayed approval, repeated opening, and destruction modes.
- [ ] Capture independently of Shoji/payload state, beginning before launch and
  continuing through release. Prefer a VM-display observation path that cannot
  accidentally exclude the target window.
- [ ] Run a positive baseline proving the capture method detects the original
  flash. Record capture frame rate, timing uncertainty, and dropped frames.
- [ ] Correlate capture frames with observed/held/placed/released timestamps.
- [ ] Check every captured frame for pre-release visibility and incorrect
  initial placement; retain raw captures and analysis, not just a screenshot.
- [ ] Test pointer hit-testing, click-through behavior, keyboard focus, app
  activation, and focus restoration during and after the hold.
- [ ] Verify app responsiveness and unaffected windows while approval is delayed.
- [ ] Repeat across cold launches, rapid openings, transactions, cancellation,
  controller failure, transport loss, timeout, and queue saturation.
- [ ] Record memory/CPU/latency bounds and recovery after every failure scenario.

**Completion evidence:** no observed early frame within the documented capture
coverage, no input/focus eligibility while held, correct placed release, and
bounded fail-open recovery. State the measurement limits; finite capture cannot
prove absence of every possible sub-frame presentation.

### 9. Expansion and maintained tooling

Only after the fixture milestone; these are not prerequisites for claiming that
narrow milestone, but remain necessary for wider use.

- [ ] Extend coverage to restored windows, sheets/dialogs, child windows,
  fullscreen/Spaces, multiple displays, scale changes, and representative apps.
- [ ] Establish per-build compatibility evidence and rejection of unknown builds.
- [ ] Evaluate deployment/security prerequisites separately from the modified VM.
- [ ] Add reproducible build/run/check tasks for probes and evidence collection.
- [ ] Replace hard-coded guest paths, UID assumptions, and stale PID assumptions
  with explicit configuration and runtime validation.
- [ ] Consolidate successful experiments into maintained Odin code; retain useful
  probes as documented diagnostics and clearly label obsolete socket probes.
- [ ] Update README, experiment instructions, capability reporting, and recovery
  guidance so loading is never confused with interception or prevention.
- [ ] Keep temporary SSH credentials and extracted proprietary artifacts out of
  commits; record artifact identities and reproducible local evidence paths.

## Dependency summary

```text
1 shared-cache isolation ──> 2 installer/lifetime ─┐
3 ABI and presentation-path analysis ────────────┴─> 4 observer
5 authenticated IPC ────────────────────────────────┐
3 + 4 ──────────────────────────────────────────────┴─> 6 hold
6 + 5 ──> 7 placement integration ──> 8 independent proof ──> 9 expansion
```

No production readiness or first-frame guarantee follows from completing steps
1–5 alone. If the candidate cannot enforce both presentation and input semantics,
return to step 3 rather than compensating with a post-show move or hide.

## Working files and evidence

- `src/addition/loader/loader_darwin.odin`: remote bootstrap and raw-symbol ABI handling.
- `src/addition/payload/payload_darwin.odin`: existing Dock patching reference.
- `src/addition/windowserver/hook/branch.odin`: branch planner and alias ownership.
- `src/addition/windowserver/payload/payload_darwin.odin`: existing socket load probe.
- `src/addition/windowserver/protocol/protocol.odin`: load-probe protocol, not hold IPC.
- `src/addition/windowserver/target/target.odin`: exact process-path validation.
- `tools/window-interception/hook-selftest/`: owned-process lifecycle/concurrency tests.
- `tools/window-interception/mapped-protection-probe/`: next shared-cache experiment.
- `tools/window-interception/fixture/`: starting point for the visual fixture.
- `tests/windowserver_hook_test.odin`, `tests/windowserver_test.odin`: current unit tests.
- `docs/WINDOWSERVER_26A434_ORDERING.md`: static and runtime evidence boundaries.
- `docs/WINDOWSERVER_EXPERIMENT.md`: loading, sandbox, and recovery history.
- `artifacts/windowserver-26A434/`: ignored exact-build artifacts and analysis evidence.
- `artifacts/windowserver-vm-probe/v2/`: local VM probe binaries/scripts.

## Resume procedure

1. Read this document and inspect the current working tree; unrelated user work
   is present and must be preserved.
2. Confirm guest identity, current WindowServer PID, SSH connectivity, recovery
   copy, and exact artifact hashes. Historical PID 169 is not a configuration.
3. Rebuild with `task build:windowserver-hook-selftest`; run the resulting binary
   in the disposable VM. Run `task test` after relevant library/test changes.
4. Implement step 1 and save two-process evidence. It has been proposed, but not
   implemented or run as of this handoff.
5. Update this backlog only against recorded evidence. For each experiment retain
   commands, exit status, build/image identity, raw logs, and known limitations.
