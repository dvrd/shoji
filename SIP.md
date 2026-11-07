# Privileged setup: SIP, Dock and WindowServer

Shoji has two optional payloads. Basic window management needs neither.

- The **Dock payload** provides native Space operations and some window effects.
- The **WindowServer gate** lands layout changes in a single frame.

Loading either requires disabling System Integrity Protection (SIP), which
reduces protections for the entire Mac, plus one narrow sudoers rule each. Only
enable them if you accept that tradeoff. Both are exact-version: on an
unsupported build they refuse to load and Shoji uses its native paths.

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

## Enable the WindowServer gate

Supported on macOS 27.2 (26B123) only. Install the payload root-owned:

```sh
task install:windowserver
```

It prints the sudoers line for `shoji --ws-attach`, which also takes no
arguments. Add it to the same `/etc/sudoers.d/shoji` file:

```text
YOUR_USERNAME ALL=(root) NOPASSWD: /absolute/path/to/Shoji.app/Contents/MacOS/shoji --ws-attach
```

Then enable it from shojirc:

```sh
shoji -m config windowserver_gate on
```

The daemon attaches in the background and retries transient failures;
`shoji service status` shows the `gate` row and its cause. The payload stays
loaded until WindowServer exits. Logging out does not restart WindowServer, so
installing a new payload takes effect after `sudo killall -9 WindowServer`
(this logs you out).

Kill switch: `sudo touch /Library/GPUBundles/ShojiWindowServerProbe/DISABLED`
refuses every later attach. It does not unload a payload that is already
loaded. Details, recovery and diagnostics (`shoji --ws-report`) are in the
[payload README](src/payloads/windowserver/README.md).
