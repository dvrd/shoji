# Mapped SkyLight inspection probe

This is an owned-process diagnostic. It never attaches to WindowServer or calls
the private candidate. Build with the project's arm64e compiler and run only in
the disposable guest, not on the host:

```sh
ODIN_ROOT="$PWD/.toolchain/Odin" bin/odin-arm64e build tools/window-interception/mapped-protection-probe -warnings-as-errors -target:darwin_arm64e -target-features:pauth -out:bin/shoji-ws-mapped-probe -o:speed -extra-linker-flags:"-F/System/Library/PrivateFrameworks"
./bin/inspector normalize-arm64e bin/shoji-ws-mapped-probe
codesign --force --sign - bin/shoji-ws-mapped-probe
```

`--observe` (also the default) reports the image UUID, slide, candidate,
innermost region protections and first 16 bytes without changing memory
protections or contents. The bytes are
observations, not a validated build-specific signature. An observe-only run on
the 26A434 guest succeeded; local raw output and binary hashes are recorded in
`artifacts/windowserver-vm-probe/observe-20261028/guest.log` (ignored artifacts).

`--protect` explicitly selects the older protection-transition experiment. It
requests copy-on-write writable protection and then read/execute protection,
without writing bytes. It requires the original protection to be read/execute
and verifies that protection after the transition. Use only in the disposable
guest. It does not prove isolation, alias propagation, or restoration of the
original mapping identity.

`--patch` and `--witness` are coordinated by `run-isolation.py`. Both reject
images other than the recorded 26A434 UUID, unslid candidate address and
16-byte entry signature. The patcher causes a copy-on-write fault, creates a
writable alias, changes one word to a NOP without calling it, and restores the
full page. The independently launched witness compares its whole page with its
own baseline before, during and after the modification. The controller waits
for each response; EOF asks the patcher to restore before exiting.

After building and copying the probe and controller into the disposable guest:

```sh
shasum -a 256 /Users/Shared/shoji-ws-mapped-probe /Users/Shared/run-isolation.py
python3 /Users/Shared/run-isolation.py /Users/Shared/shoji-ws-mapped-probe
```

A guest run passed with alias propagation, unchanged witness pages, full-page
restoration, current and maximum protection restoration, and alias release. A
previous run found that privatization increased maximum protection from 0x5 to
0x7; the patcher now explicitly requests the original maximum and verifies it.
A separate EOF test restored the page and exited with status 1. Logs and hashes are in the ignored local directory
`artifacts/windowserver-vm-probe/observe-20261028/`. This does not demonstrate
permissions inside WindowServer, safe concurrent execution or restoration of
the original mapping identity. Never use this probe as a production installer.

`run-isolation.py /Users/Shared/shoji-ws-mapped-probe --patch-alias` tests an
alias-first alternative that does not remove execute permission from the
original mapping. On the guest its writable-alias protection transition failed
with Mach error 2 before any byte write. The alias was released and the run
failed closed (`isolation-alias-first.log`). This is not an installer strategy.
