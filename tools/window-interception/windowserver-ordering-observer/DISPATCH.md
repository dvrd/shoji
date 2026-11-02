# PKGTransactionCommit dispatch analysis (A1, complete)

Static evidence on the exact 26A434 build. Raw artifacts:
`artifacts/windowserver-26A434/ghidra/transaction-commit.asm` (full
PKGTransactionCommit disassembly), `xtransaction-commit-sync.asm`, and
`transaction-dispatch-table.txt` (decoded by
`tools/window-interception/ghidra/decode-transaction-table.py`).

## Mechanism

`PKGTransactionCommit` iterates the transaction's op stream; for each op:

```
ldrb w28, [cursor]                  ; op type byte
sub  w8, w28, #1 ; cmp w8, #0x8b    ; bounds: op types 1..0x8c (140)
add  x25, x24, x28, lsl #4          ; entry = table + op*16
ldr  x20, [x25, #8]                 ; per-op metadata (logged in signpost)
ldr  x8,  [x25]                     ; PAC-signed handler pointer
add  x0, sp, #0x30                  ; &PKGTransactionContext
blraaz x8                           ; authenticated indirect call, disc 0
```

The table base is **materialized in code**, not supplied by callers:
`adrp x24, 0x1e873d000; add x24, x24, #0x430` → unslid **0x1e873d430**,
a static global. (The caller-supplied arguments select the op stream and
count only; see the `csel` at 0x1874515ac.)

## Table

140 entries × 16 bytes, op types 0x01–0x8c. Entry = { signed handler
pointer, metadata }. For this build, handler addresses decode as
`0x187000000 | (signed & 0xFFFFFF)`; the signed form carries a PAC
signature in the high bits, authenticated at the call site by `blraaz`
with discriminator 0.

**139 of 140 ops decode to named `PKGTransaction*` mutators**, all with the
same signature `(PKGTransactionContext*)` — the full map is in
`transaction-dispatch-table.txt`. Op 0x58 is an unnamed gap (reserved or
removed op; do not assume semantics). Every visibility channel confirmed by
the coverage map is here: ordering (0x01–0x02, 0x59–0x5d, 0x68), spaces
(0x18–0x2b, 0x75, 0x79, 0x82–0x83, 0x85), surfaces (0x33–0x37, 0x54, 0x5e,
0x5f), geometry (0x0f–0x13, 0x16, 0x41–0x42, 0x7b).

## Consequences for the adapter

- **One seam exists, and it is a table.** A single write of 16 bytes per op
  replaces any handler — no trampoline, no prologue relocation, no
  instruction patching. This is mechanically far simpler than the inline
  hook used for `CGXOrderWindowListSpaceSwitchOptions`.
- **Per-op gating is natural.** Because every handler takes the same
  `(PKGTransactionContext*)`, one generic gate shim can wrap any subset of
  ops uniformly, with the original handler called through after
  release/timeout — exactly the proven hold/release semantics, generalized.
- **PAC is not an obstacle.** Replacement pointers must be signed with key
  A and discriminator 0, which the payload can do itself (`paciza`, the
  same instruction the commit path uses at 0x1874515d4).
- **The table lives in a const-protected segment**; patching it needs the
  same permission dance and thread barrier as the inline hook, and the
  runtime gate must verify table bytes (or the decoded op→handler map)
  against the static model before patching.
- Ordering-hook caveat: some paths reach the ordering function without a
  transaction (e.g. `__XOrderWindow` directly). The existing inline hook
  remains the right tool there; the table seam covers the transaction
  channels.

## Context and op stream (A1.5, resolved)

Reconstructed from `PKGTransactionSetWindowAlpha` (op 0x03) and
`PKGTransactionSetWindowLevel` (op 0x06) plus the reader helper at
0x187138bf0 (`transaction-setwindowalpha.asm`, `transaction-tlv-reader.asm`):

```
_PKGTransactionContext (as built on the commit stack frame):
  +0x00  u32  connection id
  +0x08  *    connection object
  +0x10  *    op-stream cursor   (shared with the dispatch loop)
  +0x18  u64  op-stream remaining bytes
```

Op stream format: `[op-type byte][arg TLVs…]`. The dispatch loop consumes
the type byte and advances the shared cursor; each handler then decodes
its own arguments from the same cursor. Arguments are TLV-encoded
integers (tag byte: ≤0x0f small inline value, else tag>>4 = byte count,
little-endian, bounds-checked against remaining) or tag-typed payloads
(e.g. tag 0x48 → inline float32 for the alpha). Window id is always the
first argument (one TLV; `SetWindowLevel` reads a second TLV for the
level).

Consequences for the gate shim:

- The shim needs **no stream surgery**: peek the window id by decoding one
  TLV at `ctx+0x10` (or save/restore the cursor around the shared reader),
  decide, and either wait-then-forward or forward immediately. The
  original handler consumes the stream exactly as if unwrapped.
- One universal shim covers every op; the op type is known from the table
  slot the shim was installed into.
- Op 0x58 is an empty slot (zero entry) — reserved/removed; safe to use as
  a payload-owned slot if ever needed.
- Note: there is no `PKGTransactionSetWindowBounds`; plain geometry
  changes flow through `SetWindowOriginRelativeToWindow` (0x41),
  `MoveWindowWithGroup` (0x16), `SetWindowShape` (0x0b),
  `Set/ClearWindowLockedBounds` (0x12/0x13), or non-transaction paths.

## Residual unknowns

- Semantics of the per-op `meta` field (logging name/diversity; not needed
  for dispatch, and `blraaz` authenticates with discriminator 0).
- Runtime corroboration pending: table bytes + a decoded op entry must be
  verified in the live WindowServer before any patch, per the standing
  gate discipline.
