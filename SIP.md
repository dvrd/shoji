# SIP and Dock setup

Shoji's optional Dock payload provides native Space operations and some window
effects. Basic window management does not require it. Loading the payload
requires changing macOS security settings; disabling System Integrity Protection
(SIP) reduces protections for the entire Mac. Only enable this if you accept that
tradeoff. Compatibility is version-specific; macOS 27 has not been fully
validated.

## Disable SIP

1. Start macOS Recovery. On Apple Silicon, shut down, then hold the power button
   until startup options appear; choose **Options** and **Continue**. On an
   Intel Mac, restart and hold Command-R.
2. In Recovery, open **Utilities → Terminal** and run:

   ```sh
   csrutil disable
   ```

3. Restart normally and check `csrutil status` in Terminal.

Apple documents [SIP configuration](https://developer.apple.com/documentation/security/disabling-and-enabling-system-integrity-protection)
and [Recovery on Apple Silicon](https://support.apple.com/guide/mac-help/mchl82829c17/mac).
To restore SIP later, return to Recovery, run `csrutil enable`, and restart.

## Enable the Dock payload

Build Shoji as described in the [README](README.md). Automatic loading uses
`sudo -n`, so configure sudo to permit only `shoji --load-sa`, which takes no
arguments: it loads `shoji-sa.dylib` from beside the executable (or from
`Contents/Resources` in `Shoji.app`). Run `sudo visudo -f /etc/sudoers.d/shoji`
and add a line in this form, replacing the username and path:

```text
YOUR_USERNAME ALL=(root) NOPASSWD: /absolute/path/to/shoji --load-sa
```

Use a path without spaces. Verify the permission with `sudo -n -l`. With the
default installation, the executable is `/usr/local/bin/shoji`. Anyone who can
replace the executable or the payload beside it gains root through this rule,
so keep both in directories only you (or root) can write.

For a new service, start it with the payload:

```sh
shoji service start --sa
```

If the service already exists, stop it and update its configuration first:

```sh
shoji service stop
shoji service install --sa
shoji service start
```

If your existing service uses a custom `--config` or `--binary`, include those
options again when running `service install`. The service runs as your user;
do not start it with `sudo`. If loading fails, check
`~/Library/Logs/shoji/shoji.err.log`. Loading modifies Dock's running process;
unsupported macOS versions can cause Dock to crash or restart.
