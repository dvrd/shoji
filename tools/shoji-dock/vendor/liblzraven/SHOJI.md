# Vendored decoder (prebuilt)

Source: https://github.com/anat0m1a/liblzraven
Commit: `700b88c4b2e1b1d96e499d172dfa0b8e5d9134ab` (2026-07-30).
License: 0BSD; original LICENSE retained alongside.

We do **not** vendor the upstream source. This directory ships only the built
static archive `libshoji-raven.a` (LZRAVEN block decoding), which the Dock
scanner links directly (`scanner/acquisition.odin`). Encoder sources, C tests
and Python tooling are omitted. Shoji owns the bounded pbzm container reader and
invokes Apple's `aa` only on the decoded archive.

## Regenerate the archive

Run `task raven:regen`. It clones the pinned commit to a throwaway `.raven-src/`,
builds `model block stream bcj` with the same flags upstream uses, writes
`libshoji-raven.a` here, and deletes the clone. To bump the pin, change
`RAVEN_COMMIT` in the `raven:regen` task, regenerate, then re-run
`task test:dockscan`. The build assumes upstream's `src/` + `include/` layout at
that commit; adjust the task if upstream restructures.

The current archive is arm64 macOS. For another arch, regenerate on that target
(or add an arch flag to the task) and commit the per-arch archive.

## Verification

We do not re-run upstream's correctness suite. Our decode path is verified end to
end by `task test:dockscan` (`scanner/scanner_test.odin`), which decodes the
retained vector `scanner/testdata/zeros_4k.rav` through the linked archive.
Upstream disclaims ongoing maintenance; do not assume a fix arrives for a new
Apple format. When the format changes, compare decoded output against Apple's
implementation or a known-good extracted binary, and keep a reproducing vector.
