# Per-release update story (D3)

Two things change independently: **Shoji** (frequent) and **macOS** (the
WindowServer payload is pinned to one exact build). Each has its own path, and
neither ever leaves a user with a broken desktop: every unsupported state
degrades to Shoji's native paths.

## 1. Shoji update (no payload change)

The payload no longer pins Shoji's CDHash at build time. It rereads a
root-owned allowlist on every HELLO:

```
/Library/GPUBundles/ShojiWindowServerProbe/clients   root:wheel 0644, one 40-hex CDHash per line
```

Update steps (root, part of the installer):

1. Install the new `shoji` binary.
2. `sudo swift lifecycle/trust-client.swift /path/to/new/shoji`. It replaces the list
   (pass every binary that must stay trusted) and refuses unsigned binaries.
3. Restart the Shoji daemon. Its first HELLO is accepted. A dead previous
   owner is reclaimed (ESRCH), so no WindowServer restart or logout is needed.

The payload ignores the file unless the file **and** its directory are
root-owned and not group- or world-writable (`gate_allowlist_trusted`). In
that case only the build-time pins (the experiment client) authorize. Trust
comes from root ownership, not from an Apple team identity: anything that can
write the file already has root. The Accessibility grant survives updates
because Shoji is signed with the stable local certificate, so TCC keys on the
certificate rather than the CDHash.

Live evidence 2026-11-05 (`c4-live.swift trust`, 4/4):

| Check | Expected | Result |
|---|---|---|
| cleared allowlist | refused (status 4) | refused (status 4) |
| group-writable allowlist | ignored, status 4 | ignored, status 4 |
| trusted allowlist | serving | serving |
| ring export | JSON written | JSON written |

## 2. macOS update (payload must be re-ported)

Exact-build gates make an OS update fail safe:

- `run-experiment.swift` refuses any guest whose build is not the ported one.
- The loader and payload verify the SkyLight image UUID and the hooked entry
  bytes (`target.odin`). A mismatch installs nothing.
- After an update the old payload is simply not resident. Shoji's adapter
  finds no gate (`Absent`) and uses native paths. `shoji --ws-report` shows
  `payload supports 26A434: no`.

Porting a new build:

1. `rea/port-build.swift BUILD DYLD_CACHE` produces `model.json` (UUID, entry bytes,
   dispatch table, op map). No Ghidra is needed unless the diff shows changes.
2. `rea/diff-build.swift REF_TAG NEW_TAG` prints `PORT CLEAN` or
   `PORT NEEDED` with the changed fields. Never copy offsets forward on
   static analysis alone.
3. Update the build constants (`target.odin`, `WS_SUPPORTED_BUILD`, the
   status/ring file suffix) and run `task test` and the isolated ABI selftests.
4. VM acceptance on the new build: `c4-live.swift install`, then `trust`, `run`
   and `daemon`. Save the evidence under `artifacts/windowserver-vm-probe/`.
5. Mark the build supported only after step 4 passes. Otherwise it stays
   refused, and users keep native behavior.

## 3. Release notes template

```
## WindowServer integration (experimental, opt-in: SHOJI_WS_ADAPTER=1)
- Supported macOS build(s): <BUILD> (exact). Other builds: native paths, no action needed.
- Payload: <changed | unchanged> (sha256 <…>). Changed payload ⇒ reinstall + WindowServer restart (logs out).
- Shoji update only ⇒ run `sudo swift trust-client.swift <shoji path>`; no restart.
- Evidence: <artifact README links> (install, trust 4/4, daemon C1/C2/C4).
- Known limits: <e.g. locked screen breaks AX window identity; single display tested>.
- Kill switch: `sudo touch /Library/GPUBundles/ShojiWindowServerProbe/DISABLED` (takes effect at next install/WindowServer start).
- Bug reports: attach `shoji --ws-report ~/Desktop/shoji-ws` output and its folder.
```

## 4. Diagnostics for bug reports (D2)

- `shoji --ws-report [DIR]` prints: macOS build vs supported build, kill
  switch, payload sha256 and residency, this binary's CDHash, allowlist trust
  and whether this binary is listed, and the gate state.
- With `DIR`, it also exports the event ring (`ws-ring.bin` plus decoded
  `ws-ring.json`). It goes through the running daemon (`debug ws dump`) when
  the daemon owns the gate, otherwise it claims the gate briefly.
- `lifecycle/report.swift` decodes saved rings offline, using the same format and
  the same refusal rules.
