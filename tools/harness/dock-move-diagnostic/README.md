# Dock move diagnostic (disposable VM only)

This isolates the two calls combined by Shoji's `Window_Move` handler. The diagnostic payload logs `SLSMoveWindowWithGroup` and `SLSReassociateWindowsSpacesByGeometry` return values separately, together with bounds before and after each call. It preserves the original combined response. The patch replaces Dock discovery with a connection lookup so this diagnostic does **not** scan or patch Dock animation code. Its initialization and file writes are experimental and must not be installed on the host.

The move client verifies the WindowServer owner PID and the exact fixture executable path `/private/tmp/shoji-dock-move-vm/fixture` before sending a single 20-point move. The guest script starts and kills that fixture, refuses to overwrite a previous diagnostic log, and does not create or move Spaces. The payload writes `/tmp/shoji-dock-move-diagnostic_501.txt` inside the guest. This log is diagnostic, not authenticated IPC or a production feature.

## Prepared run (2026-10-28)

The resumed `Shoji Test` guest reports macOS 27.0.1 (26A434), UID 501, SIP disabled and Dock PID 418 at preflight. The separate `Shoji Test - Clean Recovery.vbvm` exists. The host runs macOS 15.6 (24G84); guest observations must not be treated as proof of host behavior.

The candidate and tools are staged in the guest's `/tmp/shoji-dock-move-vm`; the original diagnostic payload SHA-256 is `390b449a43f8330769ec378ecc28e9e6f53a972d0cd353bf9a45cacee96a4343`. A guest fixture launched from SSH and identified its own windows, and the client verified its owner and bounds. Before loading, the guest script correctly stopped with “Dock scripting addition is not loaded”. A non-root load attempt returned `cannot obtain Dock task port (5)`. The user loaded the diagnostic from the guest using:

```sh
sudo /tmp/shoji-dock-move-vm/shoji --load-sa /tmp/shoji-dock-move-vm/shoji-sa-diagnostic.dylib
```

The fixture moved from x=250 to x=230; `SLSMoveWindowWithGroup` returned 0, but the reassociation return register was 77399 and the combined handler returned `Operation_Failed`. Read-only disassembly established that the reassociation function starts with a bare return on both 24G84 and 26A434: the returned register is the incoming connection argument, not a defined error code, and the stub does no reassociation on those builds. [Baseline evidence](evidence/baseline-26A434.txt). The production source now declares that call without a return value, preserves the call for other OS versions, and returns the actual move status. Source check and 324 deterministic tests passed (the suite required local socket access outside the filesystem sandbox).

The original diagnostic was unloaded by restarting **guest** Dock; it relaunched as PID 3127. The corrected diagnostic is staged separately as `/tmp/shoji-dock-move-vm/shoji-sa-corrected.dylib` (SHA-256 `0522efe6799d660fc48f84b7eab4bccd2428533d5721077074bb04592b8e2418`). Its validation is pending the guest administrator loading it with `sudo /tmp/shoji-dock-move-vm/shoji --load-sa /tmp/shoji-dock-move-vm/shoji-sa-corrected.dylib`. Then run `zsh /tmp/shoji-dock-move-vm/guest-run.zsh`; the baseline log has already been moved aside. The corrected diagnostic logs before/after bounds and the real move code without claiming a reassociation status. A successful submission and bounds readback are not visual frame synchronization proof. The injected payload remains loaded until guest Dock exits; recovery is a guest Dock restart or restore from the clean VM copy, never a host restart.

## Resumed corrected diagnostic (2026-10-28, evening)

The saved `Shoji Test` VM was resumed. Fresh SSH preflight confirms
27.0.1 / 26A434, arm64, UID 501, SIP disabled and Dock PID 3127. Its Dock
and corrected-payload hashes match the prepared run above; strict signature
verification of the corrected payload passes. The addition was not loaded at
the initial check. Guest sudo requires an administrator password, so loading
the corrected payload remains a guest-terminal step.

A fresh `move-client-verified` build now exits nonzero on a payload error or
unexpected bounds, including changes to y/width/height. The guest copy's hash
is `c7981041a403f615ba536524af16a7d3c098b91d5ffb0c10bd5d00dc2905d93e`;
its strict signature check passes. `guest-run-verified.zsh` is staged separately
and verifies the exact guest version/build/architecture/UID before creating
the fixture. The original runner and baseline evidence are preserved.

After the guest administrator loads the corrected payload, use:

```sh
SHOJI_MOVE_CLIENT=/tmp/shoji-dock-move-vm/move-client-verified \
  /bin/zsh -f /tmp/shoji-dock-move-vm/guest-run-verified.zsh
```

The corrected fixture command **passed** after the user loaded the payload.
Window 108 moved from `(250,708,280,252)` to `(230,708,280,252)`, with an empty
response error string, native move result 0 and all bounds reads returning 0.
The verified client and SSH command exited 0. This closes the original false
`Operation_Failed` diagnostic for the recorded 27.0.1 guest.

The fixture was terminated/reaped and its absence checked. Guest Dock remained
PID 3127 after the test; it was then restarted to unload the diagnostic and
returned as PID 4709. The final handshake correctly reports no addition loaded.
WindowServer was PID 169 in both post-run checks. The host Dock was not touched.

See [the corrected result](evidence/corrected-26A434.txt). Local provenance,
command arrays, actual exit statuses and raw streams are retained under
`artifacts/dock-move-diagnostic/resume-20261028/`. The normal discovery path,
full-daemon acceptance, presentation synchronization and 27.2 remain untested
by this fixture.

## Rebuild

`payload.patch` captures the original pre-fix diagnostic; `payload-corrected.patch` applies to a temporary copy of the corrected source. These diagnostic patches are not production changes. Confirm that the selected patch applies to the intended source revision before building:

```sh
mkdir -p /tmp/shoji-dock-stage
cp -R src /tmp/shoji-dock-stage/src
cd /tmp/shoji-dock-stage
patch -p1 < /path/to/shoji/tools/harness/dock-move-diagnostic/payload-corrected.patch
```

Build `src/dock_payload` in that copy using Shoji's arm64e compiler, normalize with `bin/inspector normalize-arm64e`, and ad-hoc sign the diagnostic dylib. Build `tools/harness/dock-move-diagnostic` as a separate Odin executable; retain the source and hashes. Do not replace `bin/shoji-sa.dylib`. The current stage was built with warnings treated as errors and passed strict code-signature verification.
