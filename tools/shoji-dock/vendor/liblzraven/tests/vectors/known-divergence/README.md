# Rejection fixtures — these must FAIL to decode

Streams that Apple's decoder rejects. Each one is here because **we once
accepted it**: a validation gap, which is a strictly worse failure mode than
rejecting something valid, because we are then more permissive than the codec we
are interoperating with.

They are not part of the byte-exact suite (there is no plaintext to compare
against — the right answer is "rejected"). They are checked by:

- `tests/validate_symbols.py` — the `reject/*` lines at the end of its output;
- `tools/difftest.py`, which walks `tests/vectors/**/*.rav`, so each one is
  expected to come back as `agree_reject`.

| file | ours | Apple's |
| --- | --- | --- |
| `accept-gap-1.rav` | rejects, `LZRAVEN_E_CORRUPT` | rejects (returns 0) |
| `accept-gap-2.rav` | rejects, `LZRAVEN_E_CORRUPT` | rejects (returns 0) |

## Provenance

Found by `tools/difftest.py --sets afl` against the raw AFL queues (they are
*not* in `corpus_min`, so the minimised set alone would have missed them). Both
are our own AFL-mutated data, not Apple's.

Both are 100 bytes: well-formed framing (one 84-byte coded block + terminator),
differing from each other by 2 bytes — same lineage.

## What they caught (fixed)

Both decoded to 2048 bytes / `LZRAVEN_OK` for us and were rejected by Apple
inside `_RavDecodeBlock` — the entropy/grammar layer, not the framing.

The missing rule: **a match may not run past the coded region.** A block's last
32 bytes are the uncoded tail (`SPEC.md` §3.3), and Apple checks
`pos + length <= coded_end` *before* copying, rejecting the block outright if it
would overshoot. We clamped the copy to the block end and carried on, on the
mistaken belief — inferred from the epilogue, never tested — that the tail
simply overwrote the overshoot.

Both fixtures trip it on their final match: `accept-gap-1` a 116-byte match at
output offset 1912, `accept-gap-2` a 340-byte match at 1900, against a
`coded_end` of 2016.

Specified in `SPEC.md` §4.5; the block decoder's full rejection set is in
`docs/notes/entropy-coder.md` §8.2.9.
