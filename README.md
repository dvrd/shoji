# Shoji

An **incomplete Odin port** of [yabai](https://github.com/asmvik/yabai), pinned to
[`dd845723416f5fe92af49fad5ebab00369e07edd`](https://github.com/asmvik/yabai/tree/dd845723416f5fe92af49fad5ebab00369e07edd).
This repository builds a native macOS executable and implements the tiling core,
command socket, Accessibility backend, and part of yabai's command interface.
It is **not yet a replacement for yabai**. See [PORTING.md](PORTING.md) for the
remaining work and behavior differences.

All application source is Odin under `src/`; all tests are under `tests/`.
There are no C, Objective-C, or standalone assembly source files, and the program
does not invoke a yabai executable. Objective-C messages use Odin's
`base:intrinsics.objc_send`, including correct compiler-selected calling conventions.
C framework APIs use Odin foreign declarations. The Dock loader and payload use
Odin-native `asm` templates for Swift context registers and pointer authentication;
the remote bootstrap is compiled from Odin procedures.

## Build

Requires macOS, Xcode Command Line Tools, Odin, and Go Task. OLS and odinfmt are
optional development tools. This work was checked with Odin
`dev-2026-09:37d8ab08f` on Apple Silicon. This toolchain must support native `asm`
templates and `objc_send`; older Odin releases cannot compile this project.
The Taskfile enables `pauth` on arm64. The tested compiler emits two conservative
link-register liveness warnings at the indirect-call templates; `%x30` is explicitly
clobbered and the bridge tests run on both architectures.

```sh
task build          # bin/shoji and bin/shoji-sa.dylib
task debug          # bin/shoji-debug
task build:amd64    # bin/shoji-amd64 and bin/shoji-sa-amd64.dylib
task check          # compiler and unused-import/variable checks
task test           # bin/shoji-tests; no desktop window manipulation
task test:amd64     # Intel tests, using Rosetta on Apple Silicon
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
and edge drops insert north/east/south/west. Cross-Space drops, drag previews,
gesture suppression and Mission Control integration remain unported.

Event callbacks only record/coalesce drag state. The daemon performs window
operations outside the callback. Mouse tests use synthetic events passed directly
to the callback; no test events are posted to the desktop. Live event-tap behavior
has not been verified in this session.

Additional window commands now include all edge/corner `--resize` handles,
`--raise [WINDOW]`, `--lower [WINDOW]`, `--toggle pip`, `--toggle shadow`, and
`--sub-layer below|normal|above`. Ordering, PiP and shadow changes require the
Dock payload. Window selection also supports `largest`, `smallest`, `sibling`,
`first_nephew`, `second_nephew`, `uncle`, `first_cousin`, `second_cousin`, and
`stack.N` (one-based).

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
sticky windows and shadows use its versioned socket protocol. The proxy and fade
handlers are available at the protocol level; animation rendering and additional
CLI commands are still separate work (see PORTING.md).

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
close, minimize, or resize desktop windows. The native executable's live window
inspection could not be verified in this session because Accessibility permission
was absent. Tests establish core behavior, native message dispatch, and local IPC;
they do not establish complete yabai compatibility or macOS-version coverage.
Dock injection has not been exercised against the running Dock. The live loader currently reports `cannot start remote thread (2)` on macOS 15.6;
that issue remains open. Both architecture
builds, native bridge tests (amd64 under Rosetta), and relocated-bootstrap tests
pass; private Dock ABI and arm64e interoperability still require live validation.

## License

The upstream MIT copyright and license are preserved in [LICENSE](LICENSE).
