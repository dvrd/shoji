# Shoji

An **incomplete Odin port** of [yabai](https://github.com/asmvik/yabai), pinned to
[`dd845723416f5fe92af49fad5ebab00369e07edd`](https://github.com/asmvik/yabai/tree/dd845723416f5fe92af49fad5ebab00369e07edd).
This repository builds a native macOS executable and implements the tiling core,
command socket, Accessibility backend, and window-management commands.
Full feature coverage is still in progress. See [PORTING.md](PORTING.md) for the
remaining work and behavior differences.

The active validation target is **macOS 15.6 (24G84) on Apple Silicon**.
[VALIDATION.md](VALIDATION.md) tracks the checks required for that milestone.
Configuration, Hammerspoon bindings and service setup are in [SETUP.md](SETUP.md).

`task dockscan` builds the standalone Odin `bin/shoji-dock` diagnostic for
snapshotting, scanning and comparing Dock binaries and proposing compatibility
patches. See [the CLI workflow and validation limits](tools/shoji-dock/README.md).

The engine, macOS backend, payload, and Dock loader are Odin; no Objective-C or C
source remains. On Apple Silicon `shoji --load-sa` spawns the Odin arm64e loader
companion `bin/shoji-loader`, because the kernel refuses remote thread creation in
the arm64e Dock from a plain arm64 process; Intel Shoji injects in-process.
See [the arm64e notes](tools/ARM64E.md) for build instructions and verification limits.
Objective-C messages from Odin use
`base:intrinsics.objc_send`; C framework APIs use Odin foreign declarations.

## Build

Requires macOS, Xcode Command Line Tools, Odin, and Go Task. OLS and odinfmt are
optional development tools. This work was checked with Odin
`dev-2026-09:37d8ab08f` on Apple Silicon. This toolchain must support native `asm`
templates and `objc_send`; older Odin releases cannot compile this project.
The Taskfile enables `pauth` on arm64. The local toolchain applies `tools/odin-asm-calls.patch` to correct ARM64 call
fallthrough and link-register liveness in Odin’s assembly checker. The fix removes
the false `blr` warnings while retaining real dead-write and terminal-branch
diagnostics. Both the standard and arm64e compiler setup paths apply it.

The Apple Silicon payload and loader need the small arm64e compiler patch before building.
Build a separate compiler from the pinned Odin source checkout (the source checkout
is not modified):

```sh
task build:dev
./bin/dev build-arm64e "$(odin root)"
```

If the shared Odin source checkout has advanced beyond the installed compiler,
isolate its pinned libraries first with `task toolchain` (requires the pinned Git
revision locally). Task commands automatically use `.toolchain/Odin` when present.
The shared source checkout is left intact. If the isolated compiler was built
before the checker fix, rebuild it with
`./bin/dev toolchain --build-compiler`, then rebuild the arm64e compiler. The arm64e compiler can then be built
with `./bin/dev build-arm64e "$PWD/.toolchain/Odin"`.
If the compiler executable has also advanced, build the matching standard compiler
with `./bin/dev toolchain --build-compiler`. Task commands and the live
animation harness prefer `.toolchain/Odin/odin` when it exists. The harness also
accepts an `ODIN` environment variable naming a compiler executable.

```sh
task build:tools     # dev, inspector and harness CLIs; requires Odin
task signing:setup  # one-time local Keychain signing identity
task build          # bin/shoji and bin/shoji-sa.dylib
task debug          # bin/shoji-debug
task build:amd64    # bin/shoji-amd64 and bin/shoji-sa-amd64.dylib
task check          # compiler and unused-import/variable checks
task test           # bin/shoji-tests; no desktop window manipulation
task test:amd64     # Intel tests, using Rosetta on Apple Silicon
task test:compiler  # native compiler regression checks for ARM64 calls
task test:harness   # launchd/release tests; no actual service installation
task validate       # build/test logs, binary hashes, desktop prerequisites
task test:loader    # in-process self-test of the Odin arm64e loader
task build:universal # Apple Silicon host: universal app and payload in bin/universal/
task package VERSION=0.1.0-local # archive plus internal SHA256SUMS in dist/
task test:bootstrap # verify copied code has no external PC-relative references
task fmt            # format source/tests; excludes native asm files unsupported by odinfmt
task clean:preview  # list disposable build outputs
task clean          # remove outputs; keep installed runtime and compiler
```

`bin/` holds build outputs. `artifacts/` holds ignored local research inputs,
compressed investigation records and rollback copies; `task clean` preserves
these and the installed `shoji`, payload, loader, native development, inspector and harness tools and arm64e compiler. Unknown
files and symlinks are preserved. See [local artifact storage](docs/LOCAL_ARTIFACTS.md)
for the current layout and recovery instructions.

`ODIN`, `ODINFMT`, and `BINARY` can be overridden as Task variables, for example:

```sh
task build ODIN=/path/to/odin
```

The executable links Apple's CoreFoundation, CoreGraphics, ApplicationServices,
Cocoa/Foundation, and private SkyLight framework. It has no third-party runtime
library dependency. Debug and test builds use a single LLVM module to avoid
cross-module debug-symbol warnings from the tested compiler/toolchain.

## Run

```sh
./bin/shoji --help
./bin/shoji --version
./bin/shoji --inspect        # read-only display/space/window JSON
./bin/shoji                  # foreground daemon; Ctrl-C to stop
```

The executable needs Accessibility access in System Settings → Privacy & Security
→ Accessibility. Restart it after granting access. Local builds reuse a persistent
code-signing certificate so updates retain their identity; see [SETUP.md](SETUP.md)
for the one-time transition from ad-hoc builds. `--inspect` and daemon startup
return an error if access is missing. The daemon refuses to run as root.

The default layout is `float`. Windows confirmed by Accessibility to have a fixed
size float automatically, preserving their native geometry; an explicit
`manage=on` rule can override that choice. Unknown resize capability does not
exclude a standard window from tiling. Accessory apps, including system utility
panels, are observed and float by default. Their window panels use an automatic
above-document layer; explicit management and layer rules retain precedence.
With an older loaded payload, document windows use the normal native sublevel
until a payload supporting corrected layer keys is loaded. This compatibility
mode avoids a Dock restart and keeps utility panels above document windows.

An opt-in `scroll` layout adds stable-width columns, fixed and weighted rows,
width/height presets, focus reveal, centering policies, consume/expel actions,
column movement and native tab stacking. Modifier-assisted horizontal panning
settles with velocity-based snapping and a shared camera spring; BSP swipes
cycle through native Spaces. See [scrolling layout](docs/SCROLL_LAYOUT.md) for commands,
validation, remaining compositor limitations and rollback.

From another terminal:

```sh
./bin/shoji -m config layout bsp
./bin/shoji -m config window_gap 10
./bin/shoji -m config top_padding 10
./bin/shoji -m query --windows
./bin/shoji -m query --windows --window
./bin/shoji -m window --focus east
./bin/shoji -m window --swap west
./bin/shoji -m window --toggle float
./bin/shoji -m space --rotate 90
./bin/shoji -m rule --add 'app=^System Settings$' manage=off
./bin/shoji -m signal --add event=window_focused 'action=echo "$SHOJI_WINDOW_ID"'
```

Signals export `SHOJI_WINDOW_ID`, `SHOJI_RECENT_WINDOW_ID`, `SHOJI_PROCESS_ID`,
`SHOJI_SPACE_ID`, `SHOJI_RECENT_SPACE_ID`, `SHOJI_DISPLAY_ID`, and
`SHOJI_RECENT_DISPLAY_ID` to their shell actions.

`-c FILE` runs a config file through `/bin/sh` after the socket is ready. Without
`-c`, the daemon checks `$XDG_CONFIG_HOME/shoji/shojirc` (or
`$HOME/.config/shoji/shojirc`) and then `$HOME/.shojirc`. Put the executable in
`PATH`, or use its absolute path in configuration commands.

The socket is `/tmp/shoji_<uid>.socket`, mode `0600`. Clients must have the same
UID as the daemon. A file lock prevents two daemons from using the same socket.
Messages use length-prefixed, NUL-separated argument framing and a BEL
failure marker. The daemon collects requests and sends responses without
blocking desktop event processing, with up to 32 pending clients and fixed
request/response deadlines. Command handlers still execute serially.

## Layout

See the [subsystem source map](docs/SOURCE_MAP.md) for where each behavior lives.

- `src/engine/`: BSP/stack trees, configuration, selectors, queries, rules,
  signals, command dispatch, IPC encoding.
- `src/macos/`: Odin framework declarations, Objective-C runtime calls,
  Accessibility observers, display/space discovery, socket server/client,
  process spawning, event delivery, daemon lifecycle.
- `src/addition/`: loader, Dock payload, protocol, signature tables, native ABI bridges.
- `src/main.odin`: command-line entry point.
- `tests/`: deterministic tree and command tests, POSIX regex tests, native
  Objective-C/CoreFoundation smoke tests, Unix socket integration tests.

## Mouse controls

The daemon installs a session event tap after startup. Default bindings:
`fn` + left-drag moves, `fn` + right-drag resizes, with focus-following disabled.
A modifier-click without a drag is replayed as a normal click.

```sh
./bin/shoji -m config mouse_modifier alt
./bin/shoji -m config mouse_action1 move
./bin/shoji -m config mouse_action2 resize
./bin/shoji -m config mouse_drop_action swap
./bin/shoji -m config focus_follows_mouse autoraise
./bin/shoji -m config mouse_follows_focus on
```

`mouse_modifier` accepts `alt`, `shift`, `cmd`, `ctrl`, or `fn`. Button actions
accept `move`, `resize`, or `none`. Focus follows mouse accepts `off`, `autoraise`,
or `autofocus`; `autofocus` needs the Dock payload to focus without raising.
Floating drags use Accessibility. Tiled resizing adjusts adjacent BSP splits;
tiled movement applies the drop on release. Center drops swap or stack windows,
and edge drops insert north/east/south/west. Cross-Space drops, insertion/drag
previews, Mission Control suspension and horizontal desktop-swipe suppression
are implemented, with live behavior still unverified.

Event callbacks only record/coalesce drag state. The daemon performs window
operations outside the callback. Mouse tests use synthetic events passed directly
to the callback; no test events are posted to the desktop. Live event-tap behavior
has not been verified in this session.

Additional window commands now include all edge/corner `--resize` handles,
`--raise [WINDOW]`, `--lower [WINDOW]`, `--toggle pip`, `--toggle shadow`, and
`--toggle windowed-fullscreen`, `--toggle expose`, and
`--sub-layer below|normal|above|auto`. Ordering, PiP and shadow changes require the
Dock payload. Window selection also supports `largest`, `smallest`, `sibling`,
`first_nephew`, `second_nephew`, `uncle`, `first_cousin`, `second_cousin`, and
`stack.N` (one-based).

Queries support comma-separated property projection, for example
`shoji -m query --windows id,title,space --space`.
Rules support selective reapply by rule index/label and inline properties:
`shoji -m rule --apply my-rule` or `shoji -m rule --apply 'app=^Terminal$' manage=off`.
Registered one-shot rules are excluded from reapply. Reapply preserves trees and
split ratios when membership is unchanged. Failed creation-rule effects are logged
and retried during reconciliation; a pending one-shot remains reserved for its
original window while it still matches, until success or window destruction.

Scratchpads require the payload. Assign with `shoji -m window --scratchpad term`,
toggle with `shoji -m window --toggle term`, and recover ordered-out scratchpads
with `shoji -m window --scratchpad recover`. Labels must be unique.

## Service and release tooling

The native `shoji service` command generates a per-user launchd plist using absolute
paths and literal arguments. Installing does not start the daemon. See
[SETUP.md](SETUP.md) for configuration and Accessibility requirements:

```sh
./bin/shoji service plist --binary "$PWD/bin/shoji" # preview only
./bin/shoji service install --binary "$PWD/bin/shoji"
./bin/shoji service start
./bin/shoji service status
./bin/shoji service stop
./bin/shoji service uninstall # retains log files
```

The release archive keeps `bin/shoji`, `bin/shoji-loader`, `bin/shoji-sa.dylib`
and the `bin/dev`, `bin/inspector` and `bin/harness` CLIs together. Keep that directory structure when installing. Native app/payload slices
use the configured signing identity for the executable; local payload/loader
signatures remain ad hoc. CI artifacts use explicit ad-hoc signing and are not
notarized. The loader companion is the Odin arm64e helper
spawned by `--load-sa` on Apple Silicon; Intel Shoji injects in-process and does
not spawn it. Release packaging refuses to overwrite an existing version. The CI
workflow is provided but has not been exercised remotely.

All maintained build, signing, service, release and validation workflows run
without Python. See [development tool boundaries](docs/DEVELOPMENT_TOOLS.md) and the
[migration record](docs/PYTHON_MIGRATION.md).

## Dock scripting addition

Build with `task build`. On a machine already configured to permit Dock injection:

```sh
sudo ./bin/shoji --load-sa "$PWD/bin/shoji-sa.dylib"
./bin/shoji --check-sa  # run as the desktop user, not root
```

Use matching Intel binaries on Intel macOS. Loading is explicit and requires
permission to obtain Dock's task port and load the library under the system's SIP,
code-signing, and library-validation configuration. This project does not change
those settings. A rejected load reports an error. The payload is a direct dylib;
there is no system-wide scripting-addition bundle installer.

To enable automatic loading at daemon startup and after Dock restarts:

```sh
./bin/shoji --sa "$PWD/bin/shoji-sa.dylib"
# Or include it in the launchd service configuration:
./bin/shoji service install --binary "$PWD/bin/shoji" --sa "$PWD/bin/shoji-sa.dylib"
```

`--sa` can be combined with `-c CONFIG`. The daemon checks the payload before
loading, starts the loader through `sudo -n`, then verifies the handshake as your
desktop user. Your existing sudo policy must allow the exact executable,
`--load-sa` argument and absolute dylib path without a password for unattended
recovery. Shoji does not edit sudo permissions or display password prompts.
Failures are logged and retried with exponential backoff from 1 to 30 seconds.
Checks and loads run in subprocesses so recovery does not block window management.
A successful load with a failed handshake retries verification without repeatedly
injecting the same Dock. Recovery resets when Dock's PID changes; an in-flight
load finishes independently if the daemon exits. Without `--sa`, loading remains
manual. Do not also configure a `dock_did_restart` signal that loads the payload
when using this option.

The payload handles Space focus/create/destroy/move, window Space assignment,
opacity and timed fades, layers, sticky/shadow tags, focus, movement, ordering,
proxy swapping and scaling. Existing daemon commands for Spaces, opacity, layers,
sticky windows and shadows use its versioned socket protocol. Experimental
capture/proxy animation is now wired to `window_animation_duration` and
`window_animation_easing`. Opacity transitions use `window_opacity_duration`.
Animations default off and require Screen Recording permission in addition to
the loaded payload. Do not treat compilation or mock-renderer tests as live
validation; see [PORTING.md](PORTING.md) for recovery and compatibility limits.

Native inactive tabs are retained when their window still exists in WindowServer,
even if the application omits them from `AXWindows`. Ordered-out tabs are excluded
from tiling, dragging and visible-window queries. Switching tabs reconciles tree
removals before insertions, including full stacks. Query failures preserve the last
observation; destruction or ownership changes release the retained reference.
This handles tab visibility without inferring groups from matching window frames;
explicit native tab-group commands are not provided.

Animation recovery now runs in two places. The payload watches registered proxies
and restores the real window's system alpha when its proxy disappears, including
when the daemon is killed. Before hiding a window, Shoji atomically writes and
syncs a mode-0600 journal at `/tmp/shoji-animation_UID.json`. Startup reads the
journal and retries restoration when the payload is available; `--sa` can reload
it after Dock restarts. Window and proxy connection owners are checked before
replay. Failed writes prevent hiding; failed restores keep their recovery entry.
If both Dock and Shoji stop, journal recovery waits for Shoji and the payload to
run again. This does not protect against WindowServer failure or power loss.

A live test harness uses only disposable owned windows:

```sh
./bin/harness live animation
./bin/harness live animation --dock-restart
```

Run it from your desktop terminal as your normal user with the matching payload
loaded. The second command restarts your Dock and reloads the payload through
sudo before testing journal replay. This tests recovery after payload state loss;
it does not certify automatic reload permissions. Fixture lifetimes are bounded,
and cleanup closes only test processes. A session without a WindowServer
connection fails before hiding a window.

The updated payload uses protocol `shoji-sa-2`. After upgrading from an older
loaded payload, Dock must restart and the rebuilt payload must load before
animations can run. A protocol mismatch is rejected before a window is hidden.

`--check-sa` reports which private Dock entry points were found. Pattern tables
are ported for upstream's macOS 11–15 and 26 branches (arm64 starts at 12); this is
not a claim of live validation on all those releases. Missing signatures disable
the corresponding operations. Unknown major versions skip private discovery.
The payload socket is `/tmp/shoji-sa_<uid>.socket`, mode `0600`, with peer UID checks.

Dock restarts unload the payload; load it again afterward or use `--sa`. Repeated loading of
an already loaded dylib does not update it: replacing a running payload requires
a Dock restart. Shoji does not restart Dock; automatic loading requires `--sa`.

## Experimental WindowServer load probe

A separate, opt-in loading path now exists for the recoverable test VM:

```sh
task build addition:windowserver
sudo env SHOJI_WINDOWSERVER_EXPERIMENT=1 \
  ./bin/shoji --load-ws "$WINDOWSERVER_PID" "$PWD/bin/shoji-ws.dylib"
./bin/shoji --check-ws
```

The loader verifies the exact system WindowServer path before requesting its
task port and uses the arm64e helper on Apple Silicon. The independent payload
uses protocol `shoji-ws-1`, checks its host process, and answers a cross-UID
handshake with only the `Load_Probe` capability. It does **not** hook ordering,
hold windows, or prove first-frame prevention, and no live WindowServer load has
been validated. It is excluded from automatic startup and release archives.
See [the VM runbook, failure boundaries, and recovery steps](docs/WINDOWSERVER_EXPERIMENT.md)
before attempting a load. The project does not change the required security
configuration.

## Verification limits

The test suite runs without Accessibility permission and does not move, focus,
close, minimize, or resize desktop windows; its injector self-test performs the
full remote-thread/pthread/`dlopen` sequence against the test process only, on
both architectures (amd64 under Rosetta). Live window inspection, daemon startup,
and payload-backed Space focus/create/destroy plus window opacity operations
against Dock were verified on 2026-10-05 after Accessibility permission was
granted on the test machine. The Odin arm64e loader passed live Dock injection
on 2026-10-05 (macOS 15.6, Apple M1 Max); an in-process attempt from the plain
arm64 executable on 2026-10-10 was rejected by the kernel with
`KERN_PROTECTION_FAILURE`, confirming the loader companion is required, and the
spawned-loader path was re-validated live the same day. Both architecture
builds, native bridge tests (amd64 under Rosetta), and relocated-bootstrap tests
pass. Private Dock ABI coverage is still not certified on every macOS release.

## License

The upstream MIT copyright and license are preserved in [LICENSE](LICENSE).
