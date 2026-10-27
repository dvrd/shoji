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
