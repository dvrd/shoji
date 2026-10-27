# Streams Apple accepts and we reject — on purpose

The mirror image of `../known-divergence/`. Those exist because we were once
too *permissive*; these record where we are deliberately too **strict**.

Apple's decoder decodes both of these to full, deterministic output. We reject
both with `LZRAVEN_E_CORRUPT`. That is the `stricter` class of `SPEC.md` §9, and
it is intended: this decoder parses data straight off Apple's CDN, a raven
stream carries no checksum of any kind, and rejecting a stream we cannot
validate is the safe direction to fail in.

| file | ours | Apple's |
| --- | --- | --- |
| `undrained-state-1.stricter` | rejects, `LZRAVEN_E_CORRUPT` | accepts, 4,096 B |
| `undrained-state-2.stricter` | rejects, `LZRAVEN_E_CORRUPT` | accepts, 1,170,128 B |

## The check they trip

The end-of-block **state-drain check** (`SPEC.md` §4.4, §5.5). A block's last 32
bytes are not entropy-coded: the encoder seeds the eight rANS states with
`(1 << 32) | word`, so once the coded region is exhausted the eight words fall
out of the states in slot order. Every state's high half must therefore be
exactly 1 at that point, and we require it of all eight:

- `undrained-state-1` — state 1 is `0xf979d1c9` (high half 0)
- `undrained-state-2` — state 7 is `0xffffffd4` (high half 0)

**Apple does not check this.** It writes the low halves out as the tail
regardless and returns success, so its output for these streams contains 32
bytes derived from a state that never drained.

The invariant itself is not in doubt — it holds on every block of every stream
Apple's own encoder has produced for us, which as of this writing is 30 committed
vectors re-encoded natively, 17 generated corpus payloads and every carved OTA
payload. What these fixtures establish is narrower and worth recording: it is an
invariant of Apple's *encoder*, not a rule enforced by Apple's *decoder*.

## Provenance

Our own data. Found by `tools/difftest.py` against freshly generated libFuzzer
output (`fuzz/build/c-scalar`, `fuzz/build/c-neon`) on macOS 27.0, comparing
against Apple's **native** `libcompression` rather than the emulated oracle —
about 1.5 M executions in. They are mutations of our seed corpus; no Apple data
is involved.

They are kept out of `tools/difftest.py`'s input sets by their extension, which
is why it is `.stricter` and not `.rav`: that tool walks `tests/vectors/**/*.rav`
and would classify these as `stricter` on every run, so its `--max-stricter 0`
gate — which exists to catch us becoming *unintentionally* strict — would be
permanently tripped by a divergence that is intentional. `tests/validate_symbols.py`
checks them instead, alongside the `reject/*` fixtures.

## Why they are not "fixed"

Relaxing the drain check to match Apple would mean accepting streams whose
entropy coder demonstrably did not end in a consistent state — trading a
detectable corruption for 32 bytes of silently wrong output. `SPEC.md` §9 is
explicit that integrity checking belongs at the `pbzm` layer and that this
decoder validates more than Apple's does; this is one of the places where it
does.
