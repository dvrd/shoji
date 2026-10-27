# macOS 27 runtime validation VM

## Artifact cleanup — 2026-10-27

Dock snapshots and VM/guest-kit records were relocated from `bin/` to
`artifacts/dock-evidence/`, `artifacts/macos27-vm/` and `artifacts/macos27-guest/`.
Historical paths below describe the original experiments. Project cleanup keeps
these records and does not touch the VirtualBuddy VM outside this repository.
The probe source and entitlements are now versioned under `tools/vm-preflight/`;
rebuild the optional executable with `task build:vm-preflight`.
See [artifact storage and recovery](LOCAL_ARTIFACTS.md).

## Setup Assistant responsiveness investigation — 2026-10-25

The user reported computer freezing during guest initialization. The scope
(host-wide versus guest-only) is awaiting clarification. At 20:09 local time,
a two-second host sample showed approximately 96% CPU utilization and a separate
`agent-browser` headless Chromium process (PID 21548, parent 21547) using 552%
CPU; subsequent process observations showed 722–779%. The Misty Pony VM process
(18214) was around 1% CPU in those later observations. This identifies concurrent
host CPU contention, but does not establish the cause of the earlier freeze.
Host memory compression was 11–13 GiB; swap usage and swap-in/out counts were
zero. Disk space was approximately 486 GiB available. Another Virtualization VM
process (2406) exists; its owning workload has not been identified.

VirtualBuddy's UI remained observable and the guest had advanced to the Apple
Account setup screen. No sign-in or setup submission was performed by the agent.
Keyboard and mouse capture were on. The user was asked whether another task
needs the CPU-heavy browser process before stopping it for an isolation test.
No process was stopped, VM resources changed, or guest security settings altered
during this investigation. Injection and runtime acceptance remain pending.

## First guest boot — 2026-10-25

Computer Use is responding again. Misty Pony was started and reached the macOS
Setup Assistant language screen. This establishes a guest GUI boot, but the
installed version/build and Dock hash have not yet been read inside the guest.
The user was asked to complete Setup Assistant with a local test account,
accept Apple's license themselves and enter the new account password themselves,
then stop at the desktop. Clean powered-off duplication and runtime checks remain
pending.

An isolated transfer kit is prepared at `bin/macos27-guest/`. The explicit 27
candidate and native live-test helper were rebuilt; the executable and loader
were copied from existing local builds. All four kit copies are ad-hoc signed and
pass strict signature verification. The host's ordinary executable and payload
were not replaced. `preflight.sh` passes shell syntax checking and checks the
exact guest version/build/architecture, Dock hash, kit checksums and signatures;
it has not been run in the guest. The kit requires no guest compiler or Python
for these initial checks. Its `provenance.json` records Git HEAD and working tree
status; it does not establish a fresh source build of the copied executable.
Like other `bin/` artifacts, the kit is removed by `task clean`.

## VM restore completed — 2026-10-25

Computer Use recovered after repeated service startup failures. The VirtualBuddy wizard advanced during interaction, and restore completed successfully from the verified local **27.0.1 / 26A434** IPSW. The observed VM is **Misty Pony** at `/Users/kakurega/Library/Application Support/VirtualBuddy/Misty Pony.vbvm`, outside `bin/`. Its saved configuration records **5 CPUs, 10 GiB RAM, a 108 GiB sparse disk**, and **no shared folders**. These differ from the original proposal but meet the image minimums; they are recorded from the actual configuration, not inferred from attempted UI edits.

The installer log shows ASR sending the restore payload. The UI subsequently reached **Finished / Your macOS Virtual Machine is Ready!**; Done was selected. Guest desktop boot/version/Dock hash, powered-off clean copy, guest security configuration, injection and behavior tests remain pending. Computer Use then repeatedly returned `-10005: timeoutReached` while returning to the library, including after a short wait and an Escape attempt. `sky.list_apps()` still succeeds and reports VirtualBuddy running, so the failure is narrower than the initial service startup issue. The user was asked whether VirtualBuddy is responsive and which screen is visible. No guest test result is claimed. Evidence: `bin/macos27-vm/vm-installation-progress.json` and the partial installer log `virtualbuddy-install-20261025.log` in the same directory.

## Resumed validation — 2026-10-25

The user resumed VM validation. The exact-image desktop preflight passes; guest restore has completed and runtime checks remain pending; **macOS 27 daily-use support is not ready**.

- The local IPSW is now 26,637,307,067 bytes. Python's ZIP reader opens its central directory (1,630 entries), and both `BuildManifest.plist` and `Restore.plist` identify **27.0.1 / 26A434**, including `VirtualMac2,1` in supported product types. This establishes archive metadata, not compatibility through Apple's image loader or a successful transfer exit.
- All 1,630 ZIP entries pass CRC validation. IPSW SHA-256: `2f016638293c3e641b8b25391a76fbc16563b3711915a5551cf8aa0f5598a5c1`. Evidence: `bin/macos27-vm/archive-integrity.json` (ignored; removed by `task clean`). No Apple-published checksum comparison is claimed.
- Strict signature verification of `bin/shoji-vm-preflight` passes. Inside the sandbox it reports virtualization unavailable. Outside the sandbox it reports virtualization supported, then fails to load the exact image with `VZErrorDomain` **10004**, “Unable to connect to installation service.” This is not an incompatible-configuration result. Run the same exact-image probe in the user's desktop Terminal before choosing an installation path.
- The user ran the exact-image probe in desktop Terminal: virtualization supported **yes**, selected guest **27.0.1 / 26A434**, compatible configuration **yes**, minimum **2 CPUs / 4,294,967,296 bytes RAM**. User-provided output is retained at `bin/macos27-vm/desktop-preflight.json`. This closes the exact-image compatibility check on the existing 15.6 host; Device Support and actual restore behavior still need installation validation.
- Desktop automation was attempted again, but the Computer Use service still fails to start. The user subsequently installed VirtualBuddy **2.2.1 (430)** at `/Applications/VirtualBuddy.app`; its version and build were verified locally. Normal desktop control still fails after resetting the automation session. Explicit user authorization has been requested for an AppleScript/System Events fallback.
- Direct GitHub access also fails DNS resolution outside the sandbox. Release documentation remains available through the web research tool.
- The [VirtualBuddy 2.2 beta 2 README](https://github.com/insidegui/VirtualBuddy/blob/2.2-b2/README.md#system-requirements) specifies Apple silicon and macOS 13 or later, and supports local IPSW selection, recovery boot, and APFS VM duplication. This satisfies the app's documented host minimum; it does not prove exact-image installation support. The [maintainer's macOS 27 guidance](https://github.com/insidegui/VirtualBuddy/discussions/683) still requires Device Support; its linked Apple download requires developer sign-in. Do not substitute an unverified third-party package.

Next dependent step: use the installed VirtualBuddy to select the verified local IPSW and create the isolated guest with **4 CPUs, 8 GiB RAM, and a 100 GiB sparse disk**. Record any restore error before deciding whether additional Apple Device Support is needed. Complete guest setup, record its build and Dock hash, then retain a powered-off clean copy before injection testing.

The current official stable release is [VirtualBuddy 2.2.1 (430)](https://github.com/insidegui/VirtualBuddy/releases/tag/2.2.1). The Homebrew cask requires Apple silicon and macOS 14 or later, which this host satisfies. The agent attempted `HOMEBREW_NO_AUTO_UPDATE=1 brew install --cask virtualbuddy`; Homebrew failed during download with `malloc: possible integer overflow (18446744073709551615*4)` and `Download failed for virtualbuddy`. That attempt did not install VirtualBuddy; the user subsequently installed it successfully. Original installation commands:

```sh
brew install --cask virtualbuddy
open -a VirtualBuddy
```

If Homebrew fails there too, download the DMG from the official release page. In VirtualBuddy, choose a local macOS restore image and select:

```text
/Users/kakurega/dev/projects/shoji/bin/macos27-vm/UniversalMac_27.0.1_26A434_Restore.ipsw
```

Name the VM `Shoji macOS 27.0.1 26A434`. Keep its library outside `bin/` so `task clean` cannot remove it. Use the resources above and no shared host home folder. If restore succeeds, complete setup with a local test account, then run inside the guest:

```sh
sw_vers
shasum -a 256 /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock
```

Expected version/build: **27.0.1 / 26A434**. Expected Dock hash: `b704affba65f732ffd6676c3bb22c94abc737ee73af8bdf29a5ef02650cde33e`. Shut down the guest and duplicate the clean VM before proceeding to injection. A different hash requires binary review first.



### Installed app inspection

VirtualBuddy's bundled `vctool ipsw inspect file:///Users/kakurega/dev/projects/shoji/bin/macos27-vm/UniversalMac_27.0.1_26A434_Restore.ipsw --vm` succeeds. Its VM build identities specify **26A434 / 27.0.1**, minimum host **13.0.0**, **2 CPUs**, **4096 MB RAM**, and `mobileDeviceMinVersion = 1853.0.0`. `vctool mobiledevice version` reports **1860.41.3** on this host, numerically above the manifest minimum. These metadata checks do not establish restore success or exclude a need for newer Device Support. Evidence: `bin/macos27-vm/virtualbuddy-ipsw-inspect.log` and `virtualbuddy-installation.json`.

The bundled CLI supports catalog manipulation, IPSW inspection, MobileDevice version reporting and blur hashes; its top-level help exposes no VM creation/install command. Guest creation therefore currently depends on desktop interaction.

## Deferred work — handoff on 2026-10-25

At the original handoff, runtime validation was deferred at the user's request while other Shoji work continued. **macOS 27 daily-use support is not ready.** Static extraction/scanning and the isolated candidate build pass; no macOS 27 VM or candidate injection has been validated.

The initial IPSW transfer stopped at 6.4% with curl error 56 (receive timeout). A resumable download helper was then prepared. At handoff, the local IPSW is approximately 11 GB, larger than the original 1.6 GB partial file, but there is no successful download or exact-image preflight result. Do not treat its existence or size as completion. Documentation work does not cancel a download started separately by the user.

| Missing work | Completion evidence |
|---|---|
| Finish the 27.0.1 / 26A434 IPSW download | Successful curl exit followed by successful loading of the local image through Apple's API. |
| Check the exact image on the 15.6 host | Probe reports 27.0.1 / 26A434 and a compatible configuration. Latest-supported 15.6.1 results do not satisfy this. |
| Resolve device support and VM app requirements | Establish a supported installation path on this host; install any required Apple Device Support package deliberately. Do not assume a host OS upgrade is necessary. |
| Create the test VM and recovery copy | Guest boots, guest version/build is recorded, and a powered-off clean copy is retained. |
| Confirm guest Dock identity | Hash/build match the scanned artifact, or acquire and review the different binary before testing. |
| Validate injection and capabilities | Candidate loads inside the guest and the expected handshake/capability report succeeds. |
| Validate Space and window behavior | Recorded checks cover the acceptance sequence below, including failures and recovery. Identify checks requiring physical displays or hardware. |
| Decide whether to enable ordinary macOS 27 support | Review runtime evidence, record limitations, and deliberately change the default gate only if justified. |

### Resume from the project root

```sh
task build:vm-preflight
./tools/vm-preflight/download.zsh
```

The helper resumes the existing file, makes up to 10 transfer attempts using a fresh curl process for each attempt, and runs the signed exact-image probe only after a successful transfer. It retains partial data after failure. If the download has already finished successfully, run the check directly:

```sh
task build:vm-preflight
./bin/shoji-vm-preflight artifacts/macos27-vm/UniversalMac_27.0.1_26A434_Restore.ipsw
```

Save the final probe output before selecting the next installation step. The optional executable is a local diagnostic, not release tooling. `task clean` can remove the executable but preserves the relocated research inputs. Its source and entitlements are versioned; the equivalent rebuild commands are:

```sh
clang -Wall -Wextra -Werror -mmacosx-version-min=15.0 \
  -framework Foundation -framework Virtualization \
  tools/vm-preflight/main.m -o bin/shoji-vm-preflight
codesign --force --sign - \
  --entitlements tools/vm-preflight/entitlements.plist bin/shoji-vm-preflight
codesign --verify --strict bin/shoji-vm-preflight
```

The original InstallAssistant package and expanded SharedSupport image were removed during the authorized disk cleanup. The extracted Dock, manifests, scan reports, and isolated candidate remain under `bin/`; retrying the old package workspace is no longer an available shortcut.

## Host preflight — 2026-10-25

- Host: macOS 15.6 / 24G84, MacBookPro18,2, arm64.
- Physical RAM: 32 GiB; CPU count: 10.
- Free space after cleanup: approximately 527 GiB.
- A locally compiled, ad-hoc signed probe with the `com.apple.security.virtualization` entitlement reports `VZVirtualMachine.isSupported = true`.
- The probe's `VZMacOSRestoreImage.fetchLatestSupported` call fails from the agent session with `VZErrorDomain` code 10001, “The restore image catalog failed to load.” The same signed binary succeeds in the user's Terminal and returns **15.6.1 / 24G90**, with a compatible configuration requiring at least 2 CPUs and 4 GiB RAM. This confirms an agent-session limitation; it does not establish compatibility or incompatibility with the exact macOS 27 image.
- Installed MobileDevice framework reports `1860.41.3.100.1`; package receipts include MobileDeviceOnDemand 1900A22, 1940D10, and 2000A42. These identifiers alone do not establish macOS 27 support.
- An exact-build metadata query with `ipsw download ipsw --macos --build 26A434 --urls` cannot reach `mesu.apple.com` from the agent session (DNS lookup failure). Run that metadata-only command in the user's Terminal before downloading an image. No restore URL should be guessed from the InstallAssistant URL: they are different acquisition formats.
- No VM, device-support package, or host OS update has been installed by this preflight.

The temporary probe is `/tmp/shoji-vm-preflight`, with source and entitlements beside it. It queries metadata only, does not download the restore image, and times out after 30 seconds. Temporary files may disappear after a reboot. Even a successful latest-supported lookup does not establish compatibility with a different, explicitly selected image.

The extended, signed probe is now `bin/shoji-vm-preflight`, with diagnostic source and entitlements beside it in ignored `bin/`. Pass a local IPSW path to check that image instead of querying the latest-supported catalog. It rejects missing files, unsupported configurations, and versions/builds that differ from 27.0.1 / 26A434. The compiler's warnings-as-errors check and strict signature verification pass; exact-image loading awaits download. Neither probe installs a VM.

The user's metadata query returned this Apple restore URL:

```text
https://updates.cdn-apple.com/2026FallFCS/59241290-5d51-4ca8-9df4-31624b9a4eac/UniversalMac_27.0.1_26A434_Restore.ipsw
```

The agent's HTTP HEAD request fails to resolve `updates.cdn-apple.com`. Download from the user's Terminal into `bin/macos27-vm/`, then run `./bin/shoji-vm-preflight` against the completed IPSW. Use curl's failure handling and resumable download, and only invoke the probe if curl succeeds. Build identity must come from Apple's image loader, not the filename alone.

## Compatibility evidence

[Apple's restore-image API](https://developer.apple.com/documentation/virtualization/vzmacosrestoreimage) exposes the supported configuration for a particular image. Confirm that the exact target image has a non-null `mostFeaturefulSupportedConfiguration` before proceeding with installation. Apple requires the virtualization entitlement for this API.

[VirtualBuddy's maintainer documents a macOS 27 installation workaround](https://github.com/insidegui/VirtualBuddy/releases/tag/2.2-b2) for macOS 26 hosts. It is not evidence that the same workaround is needed or sufficient on this 15.6 host. The [maintainer's discussion](https://github.com/insidegui/VirtualBuddy/discussions/683) includes firsthand reports of macOS 27 beta installations on 15.7.7 with Apple's macOS 27 Device Support package; these reports do not verify 15.6 or the final 27.0.1 image. Check the selected VirtualBuddy release's host requirements before installing it.

## Proposed VM and acceptance sequence

Start with 4 virtual CPUs, 8 GiB RAM, and a 100 GiB sparse disk, increasing these if the exact restore image requires it. The target is **27.0.1 / 26A434**, matching the extracted Dock and the narrowly gated candidate. A different build requires its own acquisition, scan, and candidate review.

1. Resolve restore-image compatibility and device-support requirements on the existing host.
2. Install an isolated VM using Apple's restore image; complete guest setup. Keep project sharing read-only and avoid sharing the host home directory.
3. Record the guest build and Dock hash. Compare them with `docs/DOCK_SCANNER_VALIDATION.md` before loading the candidate.
4. Make a powered-off copy of the clean VM before injection testing. Configure any required SIP relaxation inside the guest only; establish the VM's recovery procedure first.
5. Build/copy Shoji and the candidate into the guest. Grant Accessibility inside the guest. Validate the addition handshake and capability report before exercising operations.
6. Exercise Space creation, focus, return, reorder, removal, display transfers where virtual displays permit, window movement, ordering, opacity, animation, and recovery. Save logs and test evidence with the exact guest build and binary hashes.
7. Document VM limitations and any remaining hardware-only checks. Promote daily-use support only after the relevant runtime checks pass.

The existing static results remain in [Dock scanner validation](DOCK_SCANNER_VALIDATION.md). A successful scan or VM installation alone is not a successful injection or behavior test.
