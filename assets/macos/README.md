# Shoji macOS icon

`Shoji.png` is the transparent master artwork. `Shoji.icns` contains native
16–1024 pixel representations for macOS. Artwork was created with the built-in
image generation tool from the supplied lattice reference.

Generation prompt: Preserve the reference's symmetric rectilinear shoji lattice
and double frame; render it front-facing in champagne gold with ivory insets,
physical thickness, rounded bevels, top-left highlights, a restrained shadow,
and a transparent outer background. No text or additional background tile.

Run `task build:app` to build and package `bin/Shoji.app`. To package the existing
signed executable without rebuilding, run `task build:app` (or `swift tools/macos/bundle.swift`).
The bundle uses the persistent local signing identity and the existing
`tech.shoji.window-manager` identifier. It is a background app with no Dock tile.

For the icon to appear for the daemon, launch the executable inside the bundle:
`bin/Shoji.app/Contents/MacOS/shoji`. Grant **Shoji.app** Accessibility access in
System Settings → Privacy & Security → Accessibility before switching services.
Existing executable permission may need to be approved again for the bundle.
Update any noninteractive sudo rule for `--load-sa` to match the bundled
executable's absolute path before switching a service that uses `--sa`.
Use `sudo visudo` (or `sudo visudo -f /etc/sudoers.d/FILE` for the file containing
the existing Shoji rule) and replace only the executable path in that rule.
For this checkout, the updated rule is:

```sudoers
kakurega ALL=(root) NOPASSWD: /Users/kakurega/dev/projects/shoji/bin/Shoji.app/Contents/MacOS/shoji --load-sa /Users/kakurega/dev/projects/shoji/bin/shoji-sa.dylib
```

Keep the existing config and payload paths when reinstalling the service:

```sh
./bin/shoji service stop
./bin/shoji service install --binary "$PWD/bin/Shoji.app/Contents/MacOS/shoji" \
  --config "$HOME/.config/shoji/shojirc" --sa "$PWD/bin/shoji-sa.dylib"
./bin/shoji service start
```

Rebuild the bundle with `task build:app` for subsequent updates and restart the
service. The plain `task build` only updates the command-line executable.

The icon is declared using Apple's
[`CFBundleIconFile`](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleiconfile).
