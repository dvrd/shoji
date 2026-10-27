# Vendored decoder

Source: https://github.com/anat0m1a/liblzraven
Commit: `700b88c4b2e1b1d96e499d172dfa0b8e5d9134ab` (2026-07-30).
License: 0BSD; original LICENSE retained.

Unmodified decoder sources and headers, decoder/rejection C tests and their
upstream vectors are included. Encoder sources and Python tooling are omitted.
This library provides only LZRAVEN block decoding. Shoji owns the bounded pbzm
container reader and invokes Apple's aa only on the decoded archive.

`task test:raven` runs the upstream C correctness/rejection tests on this host.
Tests do not replace comparison against real extracted binaries and manifests.

## Maintenance ownership

Shoji maintainers own the vendored decoder's maintenance, defect triage and
compatibility fixes. Upstream explicitly disclaims ongoing maintenance; an
upstream update must not be assumed to arrive for a new Apple format or bug.

Keep the pinned revision and original license recorded above. For a source change,
record the reason and revision here, retain a reproducing vector, and run
`task test:raven` plus `task test:dockscan`. Compare decoded output with Apple's
implementation or a retained known-good extracted binary when the format changes.
Keep divergence/rejection vectors; do not loosen rejection merely to accept a new
input without understanding its encoding and bounds. Decoder changes belong to
the standalone Dock tool and do not require loading a payload or restarting Dock.
