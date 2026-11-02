# WindowServer ownership program — plan

Vision: Shoji takes real ownership of macOS window management. Not by
replacing the compositor (impossible: every app speaks private, versioned
protocols to it) but by **owning the seam** — a versioned, gated adapter
layer between Shoji and WindowServer that absorbs upstream change in one
place and fails closed everywhere else.

State at planning time (all evidenced, see TOUR.md):

- One of four visibility channels (intra-space z-order) is gated end to
  end: hooked, externally held/released, window-list and pixel proof, n=3.
- Hardened experiment rig: cctor13 payload, loader, barrier installer,
  trigger, visibility sampler, capture probe, Ghidra pipeline.
- Coverage map: the three ungated channels (space switching, surfaces,
  geometry) all flow through the transaction machinery
  (`PKGTransactionCommit`, four XPC endpoints, indirect dispatch).

## Phase A — Finish the compositor science

| # | Task | Acceptance |
| --- | --- | --- |
| A1 | **Dispatch analysis of `PKGTransactionCommit`**: find how commit invokes mutators (op table / vtable / jump table), locate the table, verify mutator addresses | Table location + mechanism recorded; decision: one-seam vs per-family hooks |
| A2 | Extend hooks to space-switch, surface, geometry channels (order: geometry first — Shoji's core pain) | Each channel: Ghidra model, fixture, barrier install, held/unheld evidence like the ordering gate |
| A3 | Per-build port pipeline: script extract → analyze → diff model vs previous build | One command produces a "what changed" report for a new macOS build |

## Phase B — From experiment to engineering

| # | Task | Acceptance |
| --- | --- | --- |
| B1 | Real IPC replacing the /private/tmp file channel: Mach/XPC, authenticated, versioned, one-shot | Only Shoji's process can issue commands; protocol versioned |
| B2 | Reentrancy/lock audit of the held call: which WindowServer locks are held during a hold, what stalls, worst case | Written audit; hold redesigned or bounded accordingly |
| B3 | Crash-safe lifecycle: watchdog, install-time kill switch (boot arg/env), refuse-and-degrade on unknown builds | Kill switch demonstrated; refusal path tested |
| B4 | Consent + UX for the WindowServer payload, paralleling the Dock payload story | Documented install/approval flow |

## Phase C — Shoji features on top

| # | Task | Acceptance |
| --- | --- | --- |
| C1 | **Frame-atomic layout application**: batch a full layout change behind a gate, release into one frame | Visual + capture evidence of single-frame application vs current cascade |
| C2 | Race-free focus/raise using gated ordering | No AX readback loop needed for the covered operations |
| C3 | Flicker-free space operations (needs A2 space channel) | Before/after capture evidence |
| C4 | Adapter API inside Shoji with graceful degradation to today's behavior | Shoji works unchanged when payload absent/refused |

## Phase D — Polish (ongoing)

| # | Task |
| --- | --- |
| D1 | Testing matrix: macOS builds, hostile apps (Chrome/Electron/JetBrains), multi-display, Stage Manager |
| D2 | User-facing diagnostics: install report + event ring export for bug reports |
| D3 | Per-release update story: refuse-unknown-build, port pipeline, release notes |

## Rules

- Every claim ties to a saved artifact; failed experiments are preserved.
- Exact-build gates everywhere: UUID + entry bytes or refuse.
- No live unhook until a safe path is proven; payload resident until
  WindowServer exit is the documented default.
- The disposable guest is the only experiment target. SIP settings on user
  machines are never touched by Shoji itself.

## Immediate

A1 is unblocked and shapes B's design. Start: export
`PKGTransactionCommit` + the four commit endpoints, hunt the dispatch
table, check for data references to mutator addresses.
