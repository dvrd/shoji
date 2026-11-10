# Shoji

Shoji is a macOS window manager with BSP and scrolling layouts, window controls,
and optional native Space management.

## Install

Shoji is currently installed from source; there is no published installer yet.
The target is macOS 27.2 (26B123) on Apple Silicon. Earlier validation ran on
macOS 15.6 (24G84); other versions are not validated.

Install Xcode Command Line Tools, [Odin](https://odin-lang.org/) (with its source
checkout), and [Task](https://taskfile.dev/). Then, from this repository:

```sh
task install
```

This builds and installs Shoji into `/usr/local/bin`, requesting administrator
access if needed. It also creates a persistent local signing identity on first
install; macOS may ask for Keychain access. See [setup](SETUP.md) for details.

## Start

```sh
shoji service start
```

If Accessibility permission is missing, Shoji opens the relevant settings and
waits for approval. After two minutes it asks whether to keep waiting or stop
startup. In non-interactive use, approve it and run the command again. The
first start installs the user service automatically, and it will start at login.
Use `shoji service status`, `shoji service restart`, or `shoji service stop`
to manage it. Run only one window manager at a time.

## Configure

Shoji starts with floating windows by default. It reads
`~/.config/shoji/shojirc` at startup; this file is a shell script. Create the
directory with `mkdir -p ~/.config/shoji`, then create or edit `shojirc`.
For example, to use scrolling columns that fill the screen:

```sh
#!/bin/sh
SHOJI=/usr/local/bin/shoji

"$SHOJI" -m config scroll_default_column_width ratio:1.0
"$SHOJI" -m config window_gap 4
"$SHOJI" -m config layout scroll
```

Use the installed executable's absolute path: the service does not inherit your
terminal's PATH. Restart with `shoji service restart` after editing the file.
Replace `scroll` with `bsp` for a splitting layout, `stack` for stacked
windows, or `float` to leave windows floating. Commands run in a terminal take
effect immediately, but add them to `shojirc` to keep them after a restart.
`shoji -m config SETTING` prints the current value. Names, defaults, and which
windows are tiled are in the [configuration reference](docs/CONFIGURATION.md).

## Use

With Shoji running and at least two windows open, try:

```sh
shoji -m window --focus west       # focus the window to the left
shoji -m window --focus east       # focus the window to the right
shoji -m window --toggle float    # float or tile the focused window
shoji -m query --windows          # inspect known windows and their IDs
```

In the scroll layout, each column can hold several windows. Focus a column
with another column to its right, then try:

```sh
shoji -m window --consume                  # bring a window from the right column into this one
shoji -m window --column-display tabbed    # show one window at a time as tabs
shoji -m config tab_indicator_position top  # put tab indicators at the top
shoji -m window --expel                    # move the last window into a new column
```

Use `--column-display normal` to show the windows in the column as rows.
A window opened while the focused column is tabbed joins that column, to the
right of the active tab. To put the next new window into a normal column, run
`shoji -m window --insert stack` before opening it. An east or west insert
still opens a new column. Use `shoji -m window --toggle column-full-width` to
toggle the focused column's full-width setting.

For optional trackpad navigation, add these settings to `shojirc`:

```sh
"$SHOJI" -m config three_finger_horizontal on
"$SHOJI" -m config stack_swipe on
```

Horizontal three-finger swipes navigate scrolling columns; on a tabbed column
each swipe moves one tab, continuing into the adjacent column past the first or
last tab. In BSP they switch native Spaces when the Dock payload is enabled. Vertical three-finger swipes
navigate BSP stacks. Disable conflicting macOS trackpad gestures in System
Settings if they take over the swipe.

### Keyboard shortcuts

Shoji accepts commands but does not bind keys itself. Use a hotkey application
such as [Hammerspoon](https://www.hammerspoon.org/) to run them. For example,
add this to `~/.hammerspoon/init.lua` and reload Hammerspoon:

```lua
local shoji = "/usr/local/bin/shoji"
local function run(args)
  return function() hs.execute(shoji .. " " .. args) end
end

hs.hotkey.bind({"ctrl", "alt"}, "h", run("-m window --focus west"))
hs.hotkey.bind({"ctrl", "alt"}, "j", run("-m window --focus south"))
hs.hotkey.bind({"ctrl", "alt"}, "k", run("-m window --focus north"))
hs.hotkey.bind({"ctrl", "alt"}, "l", run("-m window --focus east"))
-- A tabbed column already takes the next new window. This bind is for a normal column.
hs.hotkey.bind({"ctrl", "alt", "shift"}, "t", run("-m window --insert stack"))
```

Choose bindings that don't conflict with your applications. See [setup](SETUP.md)
for more configuration and troubleshooting details.

## Spaces and SIP

Basic window management does not require disabling System Integrity Protection
(SIP). Native Space operations and some window effects use an optional Dock
payload, and single-frame layout changes use an optional WindowServer gate. Both
require additional system setup; see [privileged setup](SIP.md) before enabling
them.

## Project status

See the [production-readiness checklist](docs/PRODUCTION_READINESS.md) for remaining work and
validation.

## Documentation

- [Configuration](docs/CONFIGURATION.md): settings, defaults, tiling, and rules.
- [Development](docs/DEVELOPMENT.md): source map, tools, tests and local files.
- [Scroll layout](docs/SCROLL_LAYOUT.md) and [Niri parity](docs/NIRI_PARITY.md).
- [WindowServer roadmap](docs/WINDOWSERVER_ROADMAP.md) and the
  [gate payload](src/payloads/windowserver/README.md).
- [Dock compatibility](tools/DOCK_COMPATIBILITY.md) and [arm64e notes](tools/ARM64E.md).
