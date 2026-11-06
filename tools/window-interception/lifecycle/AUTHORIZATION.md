# Live signed-client authorization — 2026-11-04

Guest: Shoji Test, 26A434. WindowServer restarted from 50224 to 56578 during
explicit installation. The user subsequently signed in again. No new crash
report appeared; the latest remained the earlier 09:28 crash.

The installed observer pins controller CDHash
`63c9c868e5f9bcfee4cbf169ff6afac6be0206aa`.
Controller PID 56605 claimed ownership. Its status/arm/busy/release battery
passed. A second process with the same signed code was rejected with status 3.

For the negative identity test, a copy of the controller was ad-hoc re-signed
with a different identifier, producing CDHash
`7546bd32b4cccf59cf71417e4736107f29abbfa1`. The root helper gave this process
a send right to the same gate; HELLO was rejected with status 4 and no owner
identity returned. The original owner then answered status successfully.
The pinned executable was restored by a shell EXIT trap and its hash verified.
The running owner was not replaced or stopped during this negative test.

Evidence files:

- `artifacts/vm-probe/auth-20261104/install-and-health.txt`
- `artifacts/vm-probe/auth-20261104/unauthorized-client.txt`

Before installation, the environment kill switch returned exit 3 and left
WindowServer at PID 50224; the explicit installation that followed caused the
intended restart. This demonstrates installation prevention, not live unloading.

## Remaining authorization boundaries

~~The installed observer still has the legacy direct request-file fallback.~~
**Resolved 2026-11-04 (WindowServer 58578):** the Mach-only observer is
installed; writing `dump`/`hold` to the old request path produces no effect,
and `Dump` flows only through the gate. Negative identity (status 4, no
owner leak), claimant exclusion (concurrent status 3), owner-death
(non-recovery by design), and symlink refusal were all verified live.
Evidence: `artifacts/vm-probe/mach-only-20261104/`.

~~Owner-death recovery is not implemented.~~ **Resolved 2026-11-05 (C4):**
a verified-identity HELLO reclaims the gate only when `kill(pid, 0)` reports
ESRCH, and it clears any staged hold and watch.

**Runtime allowlist (2026-11-05):** Shoji is no longer pinned at payload
build time. The payload rereads the root-owned `clients` file on each HELLO
and ignores it unless both the file and its directory are root-owned and not
group- or world-writable. Live result: cleared or unsafe allowlist refused
with status 4, trusted allowlist serving. This is the no-cost substitute for
an Apple team identity: trust rests on root ownership of that file. See
[UPDATES.md](UPDATES.md).

The signed experiment controller also exposes a same-user file-command driver.
That remains an experiment harness, not an authorized production Shoji entry
point. Production integration must remove that command proxy and issue Mach
requests directly from the appropriately pinned Shoji process. Exact-artifact
ad-hoc pinning does not provide release provenance or team-signing policy.

Local tests cover malformed policy, hash mismatch, failed kernel queries and
a real received audit token whose modified PID version is rejected. Those
372 tests pass outside the sandbox; they do not substitute for guest tests of
the remaining bypass removal, pre-owner races or owner-death recovery.
