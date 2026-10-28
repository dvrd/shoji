# WindowServer loading probe

Status: **experimental load probe only**. The separate payload proves neither
ordering interception nor first-frame prevention. It installs no private
function hook, changes no window state, and attempts only a versioned
handshake.

## VM result: loading succeeds, handshake blocked

On the disposable Shoji Test guest (macOS 27.0.1 / 26A434, arm64), the
explicit loader reached `dlopen` after SIP was disabled. With library
validation enabled, the kernel rejected the ad-hoc payload as a non-platform
library. After the guest's `DisableLibraryValidation` preference was set and
the guest rebooted, kernel logs confirmed library validation was disabled,
but WindowServer's sandbox denied `file-map-executable` under `/Users/Shared`.
The guest's `/System/Library/Sandbox/Profiles/com.apple.WindowServer.sb`
explicitly allows executable mapping under `/Library/GPUBundles`. Loading the
same probe from a dedicated root-owned folder there returned success from
`dlopen`; the server remained running. The constructor attempted to bind
`/private/tmp/shoji-ws_501.socket`, but sandbox logs recorded `network-bind`
denial and `--check-ws` failed. This distinguishes successful library loading
from a working handshake. The probe has not observed or held any window, and
the guest has not demonstrated first-frame prevention. No host security setting
was changed.

A separate VM-only file probe subsequently created
`/private/tmp/shoji-ws-file-probe-27-0-1` from its WindowServer constructor.
The guest observed the expected 22-byte marker owned by UID 88, while
WindowServer PID 169 remained running. The marker is a one-way filesystem
capability observation, not an authenticated channel, a hold/release protocol,
or evidence of a presentation boundary. The fixed path and readable marker are
unsuitable for production communication.

An additional outbound socket probe was loaded with a
desktop-user Unix listener at `/private/tmp/shoji-ws-connect-probe.sock`.
The listener received no message and the guest kernel logged
`WindowServer(169) deny(1) network-outbound` for that path. This rules out
the tested socket direction under this sandbox; it does not rule out every
possible Mach or file-based IPC mechanism. No hooks or window changes were
performed.

A later one-shot file exchange used a 33-byte random request owned by the
desktop UID 501. A separate payload loaded inside WindowServer read that file
and created a response owned by UID 88. The request and response compared
equal, and WindowServer PID 169 remained running. This demonstrates the tested
filesystem operations in both directions, not mutual process authentication,
atomic delivery, resilience to replacement, or suitability for a production
protocol. The fixture intentionally hard-codes UID 501 and fixed paths.

## Safeguards

- `--load-ws` requires a positive PID and verifies that `proc_pidpath` returns
  exactly `/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer`.
- Loading also requires `SHOJI_WINDOWSERVER_EXPERIMENT=1`. Use it only in the
  recoverable test VM. The setting is not an assertion that the VM's security
  policy permits task-port acquisition or library loading.
- Apple Silicon uses the existing arm64e remote bootstrap through a new helper
  argument path. Dock discovery, automatic Dock reload, and the Dock payload are
  unchanged.
- `bin/shoji-ws.dylib` checks its own process path before starting. Its
  `shoji-ws-1` protocol and `/tmp/shoji-ws_DESKTOP_UID.socket` endpoint are
  independent of `shoji-sa-2` and the Dock endpoint.
- WindowServer runs as UID 88 rather than the desktop user. The experimental
  socket therefore permits cross-UID connection at the filesystem level, then
  accepts only the console user's peer UID. The client independently requires
  the server peer to be UID 88. This is load-probe authentication, not the final
  authenticated placement protocol.
- The probe never removes an existing endpoint before binding. A stale socket or
  conflicting file prevents startup rather than being replaced. Investigate and
  remove a stale endpoint manually in the disposable VM only after confirming
  that no probe is listening and that the path is safe to remove.
- The payload advertises only `Load_Probe`. `Ordering_Observer` and
  `Presentation_Hold` are reserved capabilities, not implemented features.

## Prepare the VM

Finish the disposable macOS VM setup and preserve a powered-off clean recovery
copy before loading. Record the guest version/build, architecture, SIP
configuration, WindowServer signature/entitlements, and recovery instructions.
Keep those results with the injection result; Dock compatibility is not
WindowServer compatibility.

The probe does not change SIP, library validation, code signatures, boot
arguments, entitlements, or process permissions. Vanish's stated requirement to
disable SIP and library validation on its supported target is evidence for that
implementation, not a configuration this project applies automatically.

## Build

On Apple Silicon, from the repository root:

```sh
task build addition:windowserver
```

This builds the normal executable and arm64e loader plus the isolated
`bin/shoji-ws.dylib`. It does not load either payload. The WindowServer probe is
not included in release archives or automatic startup.

## Load in the disposable VM

Run the desktop in the VM, identify the intended session's WindowServer PID,
and set `WINDOWSERVER_PID` to that value. The loader repeats the exact-path
check before requesting a task port.

```sh
sudo env SHOJI_WINDOWSERVER_EXPERIMENT=1 \
  ./bin/shoji --load-ws "$WINDOWSERVER_PID" "$PWD/bin/shoji-ws.dylib"
./bin/shoji --check-ws
```

A successful handshake reports the `Load_Probe` capability. Interpret failures
separately:

| Result | What it establishes |
| --- | --- |
| Exact-path rejection | The selected PID is not the intended system process; no task port is requested. |
| Task-port error | Remote attachment was not permitted; no library-load result has been established. |
| Remote thread/`dlopen` error | The bootstrap reached a distinct later stage; inspect the reported stage without assuming library validation was the only possible cause. |
| Load success, handshake failure | `dlopen` returned, but the constructor/endpoint did not produce a compatible load probe. |
| `Load_Probe` handshake | The separate payload loaded and answered. No ordering or presentation behavior is implied. |

## Disable and recover

Not setting the opt-in prevents new load attempts. A loaded dylib cannot be
hot-unloaded or replaced safely. Reboot the disposable VM to return to a fresh
WindowServer, or restore the powered-off clean copy after a failure. Restarting
WindowServer terminates the desktop session; do not use the active host as the
test environment. Keep Shoji's Dock payload disabled during this experiment so
its recovery behavior cannot obscure the result.

## Next gate

Do not add a hold on the basis of this handshake. First recover the exact
SkyLight build's ordering ABI and callers, then add a build-gated,
forwarding-only ordering observer for one fixture. Its callback must use a
bounded in-memory queue and must not perform socket I/O, Accessibility queries,
logging, or filesystem work. Only after independent observation establishes a
pre-composition boundary should a per-window hold, expiry, cancellation, and
fail-open release be implemented. Screen capture must prove the absence of an
early frame; API state and counters cannot.
