# C2 focus/raise experiment

Status: fixture and session preflight implemented; focus acceptance and gated
ordering integration remain unproven. C1's resident payload is unchanged.

Build with `task build:focus-fixture`. The output is `bin/Shoji Focus Lab.app`.
Launch that app in the guest with arguments `fixture DIRECTORY`, where DIRECTORY
already exists and is writable. The fixture exits after 180 seconds. It writes
`ready.json` containing its PID and red, green and marker window IDs.

Write a complete newline-terminated command to `DIRECTORY/request`, preferably
by atomic rename. Each command needs a distinct request ID:

```
1 focus green
2 raise red
3 snapshot
4 shutdown
```

`focus` uses owner-side AppKit activation and makeKeyAndOrderFront as a baseline.
`raise` only orders the selected window forward. `snapshot` records key/main
window, app activation, foreground PID, window order and session state in
`response.json` and `events.jsonl`. Real keyboard events are recorded by the
window receiving them. Window notifications also enter the event log.

The binary's `session` mode reports lock/login/console state, exiting 3 if the
session is unsuitable. `activate PID WID` is a separate client-side native
activation probe. It refuses a locked/off-console session and targets outside
its own fixture executable. A zero native API status is **not** focus evidence.

## Evidence so far (2026-11-04)

SSH, GUI LaunchAgent and normal `open` launches all produced windows but failed
to activate while loginwindow owned the foreground. IOConsoleUsers confirmed
`CGSSessionScreenIsLocked=Yes`, with the user still logged in. The native
activation probe returned zero for both selected windows without changing the
foreground or key window. These runs cannot evaluate the activation API in an
unlocked session, or establish that GUI launch context was the cause.

The corrected preflight reports locked=true and rejects activation with exit 3.
Evidence: `artifacts/vm-probe/focus-raise-20261104/locked-session.txt`.
WindowServer remained PID 50224; the latest guest crash report remained the
previous 09:28 report. No resident payload replacement was performed for C2.

## Remaining acceptance

1. ~~Confirm the unlocked session passes preflight. Establish owner-side baseline
   focus changes and actual keyboard delivery through VirtualBuddy.~~ (done
   2026-11-04)
2. ~~Evaluate client-side activation against each fixture window.~~ (done
   2026-11-04: process activation returns 0 without selecting a window; it is
   not a focus implementation by itself.)
3. ~~Add a generation/target-bound ordering completion receipt to the
   experimental gate.~~ **Done 2026-11-05** (`Watch`=12/`WatchStatus`=13,
   `Receipt_Slot`): once-only, cancel via `Watch 0`, stale generation
   refused, callback forwards without sleeping. Live evidence:
   `artifacts/vm-probe/receipt-20261105/` (all five checks pass
   against this fixture).
4. Repeat alternating targets and cancellation/replay cases. Correlate ordering
   completion, activation and keyboard timestamps. No AX readback polling.
   (Partially done 2026-11-05: alternating red/green targets, cancel, and
   replay cases pass via the receipt. Keyboard-timestamp correlation still
   depends on the separate VirtualBuddy keyboard run; the receipt replaces
   the AX readback loop for ordering completion.)

Successful same-owner fixtures alone will not establish arbitrary-app, cross-owner,
Space-switching or production behavior.

## Unlocked baseline

After the user unlocked the guest, preflight reported locked=false,
login_done=true and on_console=true. Fixture PID 56325 focused green WID 200,
which received real key `a` with active=true, is_key=true and front_pid=56325.
Owner-side AppKit then focused red WID 199, which received real key `b` with
the same matching state. Key-window notifications and z-order agreed.

Between these two successful owner-side operations, client-side
SLPSSetFrontProcessWithOptions targeting red returned activation_status=0 but
left green as key/main and first in z-order. Thus screen locking explained the
earlier baseline failure, but this native call alone is insufficient to select
another window of the already-active fixture. It must not be wired into C2 as
a working focus implementation. Keyboard input was sent through VirtualBuddy
using computer-use controls, not synthesized inside the guest.

Evidence: `artifacts/vm-probe/focus-raise-20261104/unlocked-baseline.txt`.
The file contains receiver events and snapshots; the native API status was
observed separately in the probe output. WindowServer remained PID 50224.
Remaining steps 2–4 above are still open.
