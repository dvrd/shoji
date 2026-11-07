# Experimental installation and recovery

This is an opt-in disposable-VM experiment, not a production installer. The
guest Mach owner uses first-HELLO-wins with audit-token PID and PID version.
Every command requires an authorized client CDHash, checked through
`csops_audittoken`, so the client cannot supply its own identity. Two sources
authorize a client: the experiment gate-client, pinned at build time, and the
root-owned `clients` allowlist beside the payload, written by
`trust-client.swift` and reread on every HELLO. Shoji is authorized only through
the allowlist, so a Shoji update needs no payload rebuild
([update story](UPDATES.md)). An owner that dies is reclaimed by the next
verified HELLO (ESRCH only).

`task build:windowserver-ordering-observer` builds and signs the gate-client
first and pins its CDHash. Deploy those two artifacts together. **The client
build is not bit-deterministic**: rebuilding the observer rebuilds the client
with a fresh CDHash, and a stale deployed client is refused with status 4.

Before installation, preserve guest crash reports and experiment artifacts,
confirm SSH works with the pinned host key, and keep the VM console available.
The user must understand that loading the payload can crash WindowServer and
end the graphical session. No host SIP setting is changed by these scripts.

`run-experiment.swift --preflight` checks root, exact guest OS build and VM status
without changing the installation. This is not ABI approval: the loader must
still verify UUID and entry bytes. Unknown arguments now refuse installation.

Set `SHOJI_WINDOWSERVER_DISABLE=1` in the installer environment, or create the
root-owned `/Library/GPUBundles/ShojiWindowServerProbe/DISABLED` sentinel, to
refuse installation before controllers, logs or WindowServer are touched.
The sentinel must live in a root-controlled directory. Environment propagation
through sudo must be configured explicitly; the persistent sentinel avoids
that ambiguity. The switch does not unload an already resident hook.

Recovery: preserve evidence, disable further installation, then restart the
disposable guest using its normal VM controls and sign in again. Do not unhook
live code or blindly retry injection. This experiment loads explicitly; it
does not install a boot-time injection service. Existing controller ownership
does not survive WindowServer exit, and a fresh handoff is required.

Remaining B3 requirements include a proven bounded watchdog/recovery policy
and live sentinel demonstration in the guest. Local preflight tests alone do
not demonstrate crash recovery. B4's production consent/settings UI remains
dependent on a supported installation and production identity design.

**Bounded watchdog/recovery policy (2026-11-04, all live-evidenced):** the
recovery design is layered and bounded at every level. (1) A claimed hold
fails open at its 3 s deadline (`held=2`, 3005.3 ms, original result) — a
dead or stalled controller can never pin a window. (2) The controller
detects its dead gate right (`mach_port_type` each poll) and exits instead
of racing a successor — proven during the 09:28 placement crash, where the
controller exited on its own. (3) The installer retires older controllers
before installing. (4) Owner death: the next verified HELLO reclaims the gate,
but only when `kill(pid, 0)` reports ESRCH (C4, 2026-11-05). (5) Installation refusal:
`SHOJI_WINDOWSERVER_DISABLE=1` (earlier evidence) and the root-owned
`DISABLED` sentinel both refuse before touching anything — the sentinel was
demonstrated live 2026-11-04 (exit 3, WindowServer PID unchanged, gate kept
answering afterwards; helper `lifecycle/sentinel.swift`). No live unload is
permitted: the payload is resident until WindowServer exit.

For a new macOS release, use `rea/port-build.swift` and `rea/diff-build.swift`, review exact
UUID/entry/table changes, run isolated ABI tests, then repeat VM acceptance.
Do not copy offsets forward or label a build supported from static analysis
alone. D1 requires additional machines/displays/apps beyond the current VM;
no compatibility claim is made for those configurations.

## Diagnostics

Live: `shoji --ws-report [DIR]` (see [UPDATES.md](UPDATES.md#4-diagnostics-for-bug-reports-d2)).

Run `tools/window-interception/lifecycle/report.swift PATH/response.bin`
to export a V3 observer ring as JSON with its SHA-256, retained events, target
IDs, results and timebase-correct durations. Truncated, torn and inconsistent
snapshots are refused. This reads saved files only and does not establish live
health. Do not include private SSH keys or credentials in a diagnostic bundle.
