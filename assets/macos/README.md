# Shoji macOS icon

`Shoji.png` is the transparent master artwork. `Shoji.icns` contains native
16–1024 pixel representations for macOS. Artwork was created with the built-in
image generation tool from the supplied lattice reference.

Generation prompt: Preserve the reference's symmetric rectilinear shoji lattice
and double frame; render it front-facing in champagne gold with ivory insets,
physical thickness, rounded bevels, top-left highlights, a restrained shadow,
and a transparent outer background. No text or additional background tile.

Run `task build:app` to build and package `bin/Shoji.app`. To package the existing
signed executable without rebuilding, run `task build:app` (or `tools/macos/bundle.swift`).
The bundle uses the persistent local signing identity and the existing
`tech.shoji.window-manager` identifier. It is a background app with no Dock tile.

For the icon to appear for the daemon, launch the executable inside the bundle:
`bin/Shoji.app/Contents/MacOS/shoji`. Grant **Shoji.app** Accessibility access in
System Settings → Privacy & Security → Accessibility before switching services.
Existing executable permission may need to be approved again for the bundle.
The bundle carries the Dock payload in `Contents/Resources/shoji-sa.dylib`;
`--load-sa` and `--ws-attach` take no arguments, so each sudo rule pins only the
bundled executable. Use `sudo visudo -f /etc/sudoers.d/shoji`. For this
checkout the rules are:

```sudoers
kakurega ALL=(root) NOPASSWD: /Users/kakurega/dev/projects/shoji/bin/Shoji.app/Contents/MacOS/shoji --load-sa
kakurega ALL=(root) NOPASSWD: /Users/kakurega/dev/projects/shoji/bin/Shoji.app/Contents/MacOS/shoji --ws-attach
```

The second rule is needed only for `config windowserver_gate on`; see
`task install:windowserver`. Keep the existing config when reinstalling the
service:

```sh
./bin/shoji service stop
./bin/shoji service install --binary "$PWD/bin/Shoji.app/Contents/MacOS/shoji" \
  --config "$HOME/.config/shoji/shojirc" --sa
./bin/shoji service start
```

Rebuild the bundle with `task build:app` for subsequent updates and restart the
service. The plain `task build` only updates the command-line executable.

The icon is declared using Apple's
[`CFBundleIconFile`](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleiconfile).
