# Shoji setup

The target is macOS 27.2 (26B123), Apple Silicon. Basic window management and
Space operations have passed live checks. Experimental animations default off.

## Configuration

Run `task install` to build and install Shoji into `/usr/local/bin`. The
commands below also describe development builds in the checkout's `bin`
directory; substitute `/usr/local/bin/shoji` when using the installed copy.
Set `INSTALL_DIR` on the task to choose a different absolute installation path.

For a manual development build, run `task signing:setup` first.
This creates a self-signed code-signing certificate in your default user keychain
and records its fingerprint in `~/.config/shoji/signing.json` (respecting
`XDG_CONFIG_HOME`). macOS may request Keychain authorization during setup. Trust
is limited to code signing in your user account; no system or SSL trust is changed.
The private key stays in Keychain; only a public certificate and configuration
are saved alongside your Shoji config.

Build with `task build`. Grant the executable access in System Settings → Privacy &
Security → Accessibility once. When switching from an older ad-hoc build, remove
and re-add the executable once to establish the certificate-based identity.
Subsequent `task build` updates use the same certificate and identifier, verify
the candidate signature, then atomically replace the executable. Restart the
service with `./bin/shoji service restart` to use the new build.

Keep the signing certificate and private key in Keychain. Deleting or replacing
the identity, using a different identifier, or installing an ad-hoc build changes
the identity macOS approved. A locked or unavailable signing key makes the build
fail; it does not silently fall back to ad-hoc signing.

To select an existing valid certificate instead of creating a local one:

```sh
./bin/dev signing setup --identity CERTIFICATE_SHA1 --keychain /path/to/keychain-db
```

Use `task signing:check` to check configuration without making changes. Keep the
installed executable at the same path. Debug builds use a separate identifier
and require their own Accessibility approval. CI explicitly uses
`SHOJI_ADHOC_SIGNING=1`; those artifacts do not preserve your local permission.
Re-sign an externally built update with your configured identity before installing
it, using a candidate in the destination directory:

```sh
./bin/dev signing sign bin/shoji.new --install bin/shoji
```

[Apple’s code-signing requirements note](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
explains why ad-hoc signatures identify a particular build, while certificate
requirements can identify successive versions.

The local certificate is for this laptop's development builds, not a notarized
public release. Certificates eventually expire; selecting a replacement requires
a new Accessibility grant.

Create `~/.config/shoji/shojirc` with commands using the absolute executable path:

```sh
#!/bin/sh
set -eu
SHOJI_BIN=/absolute/path/to/shoji/bin/shoji
shoji() { "$SHOJI_BIN" "$@"; }
shoji -m config layout float
shoji -m config window_animation_duration 0
shoji -m config window_gap 4
shoji -m config top_padding 4
shoji -m config bottom_padding 4
shoji -m config left_padding 4
shoji -m config right_padding 4
shoji -m config mouse_modifier fn
shoji -m config mouse_action1 move
shoji -m config mouse_action2 resize
shoji -m config mouse_drop_action swap
shoji -m rule --add 'app=^System Settings$' manage=off
# Add application exclusions before enabling tiling.
shoji -m config layout bsp
```

Preserve your existing configuration when updating. Service startup runs this file
through `/bin/sh`; use `sh -n ~/.config/shoji/shojirc` to check shell syntax.

## Service

Run these commands in your laptop's terminal, from the repository directory.
Use only one window manager at a time. The first start creates a launchd plist
automatically; use `service install` to customize an existing configuration:

```sh
./bin/shoji service start
./bin/shoji service status
./bin/shoji -m config layout
./bin/shoji -m config window_gap
./bin/shoji -m rule --list
```

`--sa` requires the exact noninteractive sudo permission described in
[SIP.md](SIP.md). The daemon waits for a verified
payload handshake before running the config. Normal service operations do not
restart Dock.

The launchd label is `tech.shoji.window-manager`. If status shows repeated exits,
inspect the error log before continuing:

```sh
tail -30 "$HOME/Library/Logs/shoji/shoji.err.log"
./bin/shoji service restart
```

## Hammerspoon

Point existing bindings directly at Shoji. Back up your Hammerspoon configuration
before editing it. For example:

```lua
local SHOJI = "/absolute/path/to/shoji/bin/shoji"
local function shoji(args)
  return function() hs.execute(SHOJI .. " " .. args) end
end
hs.hotkey.bind({"cmd"}, "h", shoji("-m window --focus west"))
hs.hotkey.bind({"cmd"}, "j", shoji("-m window --focus south"))
hs.hotkey.bind({"cmd"}, "k", shoji("-m window --focus north"))
hs.hotkey.bind({"cmd"}, "l", shoji("-m window --focus east"))
```

Service bindings should execute the absolute path to `bin/shoji` with arguments
`service start`, `service stop`, or `service restart`. Reload Hammerspoon
and check focus, float/grid, resizing, Space navigation, and fn mouse controls.
Check service restart and login startup during daily use.

## Isolated live checks

Stop Shoji and any other window manager before the owned-window test. It creates
its own daemon restricted to disposable windows and stops only its own children:

```sh
./bin/shoji service stop
./bin/harness live desktop
./bin/harness live spaces --load-payload
./bin/shoji service start
```

The Space test tracks the exact disposable Space ID, restores original focus, and
destroys only the Space it created. Neither check restarts Dock. Review the printed
evidence directory if a check fails.
