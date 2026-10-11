# Shoji

An **incomplete Odin port** of [yabai](https://github.com/asmvik/yabai), pinned to
[`dd845723416f5fe92af49fad5ebab00369e07edd`](https://github.com/asmvik/yabai/tree/dd845723416f5fe92af49fad5ebab00369e07edd).
This repository builds a native macOS executable and implements the tiling core,
command socket, Accessibility backend, and part of yabai's command interface.
It is **not yet a replacement for yabai**. See [PORTING.md](PORTING.md) for the
remaining work and behavior differences.

The engine, macOS backend, payload, and Dock loader are Odin; no Objective-C or C
source remains. On Apple Silicon `shoji --load-sa` spawns the Odin arm64e loader
companion `bin/shoji-loader`, because the kernel refuses remote thread creation in
the arm64e Dock from a plain arm64 process; Intel Shoji injects in-process.
See [the arm64e notes](tools/ARM64E.md) for build instructions and verification limits.
The program does not invoke a yabai executable. Objective-C messages from Odin use
`base:intrinsics.objc_send`; C framework APIs use Odin foreign declarations.

## Build

Requires macOS, Xcode Command Line Tools, Odin, and Go Task. OLS and odinfmt are
optional development tools. This work was checked with Odin
`dev-2026-09:37d8ab08f` on Apple Silicon. This toolchain must support native `asm`
templates and `objc_send`; older Odin releases cannot compile this project.
The Taskfile enables `pauth` on arm64. The tested compiler emits two conservative
link-register liveness warnings at the indirect-call templates; `%x30` is explicitly
clobbered and the bridge tests run on both architectures.

The Apple Silicon payload and loader need the small arm64e compiler patch before building.
Build a separate compiler from the pinned Odin source checkout (the source checkout
is not modified):

```sh
python3 tools/build_odin_arm64e.py "$(odin root)"
```

```sh
task build          # bin/shoji and bin/shoji-sa.dylib
task debug          # bin/shoji-debug
task build:amd64    # bin/shoji-amd64 and bin/shoji-sa-amd64.dylib
task check          # compiler and unused-import/variable checks
task test           # bin/shoji-tests; no desktop window manipulation
task test:amd64     # Intel tests, using Rosetta on Apple Silicon
task test:tooling   # launchd/release tests; no actual service installation
task test:loader    # in-process self-test of the Odin arm64e loader
task build:universal # Apple Silicon host: universal app and payload in bin/universal/
task package VERSION=0.1.0-local # archive plus internal SHA256SUMS in dist/
task test:bootstrap # verify copied code has no external PC-relative references
task fmt            # format source/tests; excludes native asm files unsupported by odinfmt
task clean          # remove bin/
```

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
→ Accessibility. Restart it after granting access. `--inspect` and daemon startup
return an error if access is missing. The daemon refuses to run as root.

The default layout is `float`, matching yabai. From another terminal:

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
./bin/shoji -m signal --add event=window_focused 'action=echo "$YABAI_WINDOW_ID"'
```

`-c FILE` runs a config file through `/bin/sh` after the socket is ready. Without
`-c`, the daemon checks `$XDG_CONFIG_HOME/shoji/shojirc` (or
`$HOME/.config/shoji/shojirc`) and then `$HOME/.shojirc`. Put the executable in
`PATH`, or use its absolute path in configuration commands.

The socket is `/tmp/shoji_<uid>.socket`, mode `0600`. Clients must have the same
UID as the daemon. A file lock prevents two daemons from using the same socket.
Messages retain yabai's length-prefixed, NUL-separated argument framing and BEL
failure marker, but use a separate socket so Shoji does not replace a running yabai
instance's IPC endpoint.

## Layout

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

The daemon installs a session event tap after startup. Defaults match yabai:
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
Registered one-shot rules are excluded from reapply.

Scratchpads require the payload. Assign with `shoji -m window --scratchpad term`,
toggle with `shoji -m window --toggle term`, and recover ordered-out scratchpads
with `shoji -m window --scratchpad recover`. Labels must be unique.

## Service and release tooling

The separate Python 3 service tool generates a per-user launchd plist using absolute
paths and literal arguments. Installing does not start the daemon. These commands
are opt-in and were tested with a fake launchctl, not run against the desktop:

```sh
python3 tools/service.py plist --binary "$PWD/bin/shoji" # preview only
python3 tools/service.py install --binary "$PWD/bin/shoji"
python3 tools/service.py start
python3 tools/service.py status
python3 tools/service.py stop
python3 tools/service.py uninstall # retains log files
```

The release archive keeps `bin/shoji`, `bin/shoji-loader` and `bin/shoji-sa.dylib`
together. Keep that directory structure when installing. Native app/payload slices
are signed ad hoc, not notarized. The loader companion is the Odin arm64e helper
spawned by `--load-sa` on Apple Silicon; Intel Shoji injects in-process and does
not spawn it. Release packaging refuses to overwrite an existing version. The CI
workflow is provided but has not been exercised remotely.

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

The payload handles Space focus/create/destroy/move, window Space assignment,
opacity and timed fades, layers, sticky/shadow tags, focus, movement, ordering,
proxy swapping and scaling. Existing daemon commands for Spaces, opacity, layers,
sticky windows and shadows use its versioned socket protocol. Experimental
capture/proxy animation is now wired to `window_animation_duration` and
`window_animation_easing`. Opacity transitions use `window_opacity_duration`.
Animations default off and require Screen Recording permission in addition to
the loaded payload. Do not treat compilation or mock-renderer tests as live
validation; see [PORTING.md](PORTING.md) for recovery and compatibility limits.

`--check-sa` reports which private Dock entry points were found. Pattern tables
are ported for upstream's macOS 11–15 and 26 branches (arm64 starts at 12); this is
not a claim of live validation on all those releases. Missing signatures disable
the corresponding operations. Unknown major versions skip private discovery.
The payload socket is `/tmp/shoji-sa_<uid>.socket`, mode `0600`, with peer UID checks.

Dock restarts unload the payload; load it again afterward. Repeated loading of
an already loaded dylib does not update it: replacing a running payload requires
a Dock restart. Shoji does not restart Dock or inject automatically.

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
