# macOS 27 and Shoji's Dock addition

Investigated 2026-10-25. Research and source inspection only: no OS update, injection, Dock restart, or security-setting change was performed.

## Decision

Update: the real 27.0.1 / 26A434 Dock has now been extracted on the 15.6 host using Shoji's new pbzm/LZRAVEN reader. All seven targets match uniquely in the explicit 27.0.1 static profile. `task addition:macos27` builds a separate candidate payload; the normal build still rejects 27. Target-OS runtime validation remains outstanding. See [current validation evidence](docs/DOCK_SCANNER_VALIDATION.md).

Resumed, 2026-10-25: VM validation is active again. The local IPSW manifests identify 27.0.1 / 26A434, but Apple's exact-image loader cannot connect to its installation service from the agent session. The user's desktop-terminal exact-image probe now passes for 27.0.1 / 26A434 (compatible configuration, minimum 2 CPUs / 4 GiB); VirtualBuddy 2.2.1 completed the guest restore. Guest desktop build/Dock hash, clean recovery copy, injection and behavior checks remain pending. The [VM validation handoff](docs/MACOS27_VM_VALIDATION.md) records what is missing and how to resume. VM restore completion is recorded; no Shoji guest runtime success is claimed.

Treat the existing Shoji build as unsupported on macOS 27. The available evidence does **not** show that Apple universally blocked Dock injection. It shows that an adapted upstream fork can load its addition on stable 27.0.1, while Shoji currently rejects this OS before discovering Dock functions. A port is plausible, but an upgrade of this daily-use installation should wait for a build-specific port and validation.

## What version is available?

Apple lists **27.0.1 as the current public release**, dated September 28, 2026. Its developer release entry identifies build **26A434**. This is distinct from **27.2 RC, build 26B118**, released for testing October 19. Compatibility evidence must name the build, not merely “macOS 27.” [Apple security releases](https://support.apple.com/en-us/100100), [27.0.1 release](https://developer.apple.com/news/releases/?id=09282026c), [27.2 RC release](https://developer.apple.com/news/releases/?id=10192026c)

## Evidence from the implementation Shoji follows

The initial failure report concerns developer beta **26A5353q** on M4 Pro. Its author observed that enabling the version path let the payload run in Dock, but native Space operations still failed because its internal targets did not resolve. Merely treating 27 as 26 was insufficient. This distinguishes an OS gate and payload-discovery failure from a transport ban. [Upstream issue 2800](https://github.com/asmvik/yabai/issues/2800)

The separate compatibility thread records these results:

| Build | Evidence and limit |
|---|---|
| 26A5353q, first developer beta | Fork supplies seven target signatures and adjusted scan starts; two signatures changed. |
| 26A428, stable 27.0 | September 25 user report says the fork patch works. |
| 26A434, stable 27.0.1 | October 8 M1 report says all seven signatures from `49c2d03` resolve, addition loads, and immediate Space focus works; author explicitly did not test every operation. Dock SHA-256: `b704affba65f732ffd6676c3bb22c94abc737ee73af8bdf29a5ef02650cde33e`. |
| 26B5091g, reported as 27.2 beta | September 24 report says the preceding values fail; no detailed failure diagnosis. |
| 26B118, 27.2 RC | No build-specific success confirmation found in that thread. |

These are contributor observations rather than Shoji tests or an Apple compatibility guarantee. [Upstream issue 2802](https://github.com/asmvik/yabai/issues/2802)

The actual fork patch adds explicit OS handling and arm64 scan data, alongside unrelated installation and window-management changes. Port the relevant code deliberately instead of adopting its installer or copying the entire diff. [Fork commit 49c2d035aa0a7d99f6ebf7f7d327972d6a707bb4](https://github.com/AhsanFazal/yabai/commit/49c2d035aa0a7d99f6ebf7f7d327972d6a707bb4)

At inspection time, upstream master still has no explicit 27 branch in `verify_os_version` or its arm64 pattern selection. Its README names support through Tahoe, and the changelog has a 26.6 pattern fix under Unreleased above 7.1.25. Therefore a working community fork must not be described as merged official 27 support. [Payload version gate](https://github.com/asmvik/yabai/blob/master/src/osax/payload.m), [arm64 patterns](https://github.com/asmvik/yabai/blob/master/src/osax/arm64_payload.m), [README](https://github.com/asmvik/yabai/blob/master/README.md), [changelog](https://github.com/asmvik/yabai/blob/master/CHANGELOG.md)

## What Apple documents

The macOS 27 release notes discuss Dock/Mission Control fixes, quarantined launchd plist loading, and new `arm64e.x1`/CPA2 hardware support on M6 and newer Macs. None establishes that Shoji's existing loader works on 27, and the hardware note must not be generalized to older Apple silicon. Apple does not provide a supported Dock-injection interface in these notes. [Apple release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes)

The 27 security bulletin includes WindowServer secure-input handling and other system security fixes, but it does not identify a Dock scripting-addition prohibition. Absence from a bulletin is not proof of unchanged behavior. Apple lists no published CVE entries for 27.0.1. [27 security content](https://support.apple.com/en-us/149035), [security releases](https://support.apple.com/en-us/100100)

## Shoji source implications

These findings come from this working tree, not external compatibility claims:

| Layer | Current source | Consequence on 27 |
|---|---|---|
| Injection transport | `src/addition/loader/inject_darwin.odin` uses a separate arm64e helper and a 14.4-or-later bootstrap path. | Its broad version branch is not proof of compatibility. Shoji's own remote bootstrap, pointer handling, signing, and helper still need validation. |
| OS acceptance | `src/addition/patterns/scan.odin:supported` accepts arm64 major versions 12–15 and 26. | 27 is rejected. |
| Function discovery | `src/addition/payload/discovery_darwin.odin:discover` returns after that rejection. | No Dock globals/functions are discovered and advertised through that path. |
| Scan data | `src/addition/patterns/patterns_arm64.odin` selects exact known majors. | A standalone change to the supported-version gate leaves 27 without valid scan data. |
| Operations | Payload handlers and backend route native Space operations through the addition. | Successful injection or a responding socket alone does not prove create/remove/reorder/focus/window movement works. Other window effects need their own tests. |

Do not alias every future major to 26 or 27. The 27.2-beta report is already a reason to retain explicit compatibility checks and capability reporting.

## Work needed before recommending an upgrade

1. Obtain the intended target build's Dock binary for offline analysis; record version, architecture, SHA-256 and image UUID. Start with stable 26A434 if that is the intended upgrade.
2. Add explicit 27 support only after matching the correct globals and function entry points. Check scan uniqueness, instruction decoding and expected data/function shapes; finding a byte sequence alone is insufficient.
3. Compile and inspect Shoji's arm64e helper and payload for the target toolchain. Preserve the current working installation while testing on a separate installation.
4. Validate transport, socket handshake, capability discovery, and each operation separately: focus/create/remove/reorder Spaces, transfer between displays, window-to-Space movement, sticky/layer/opacity/transform behavior, and About This Mac ordering. Keep disposal/restoration bounded and evidence-producing.
5. Test start/restart and failure reporting, including refusal of an unsupported target. Do not use Dock restart as an automatic recovery experiment.

The source port looks bounded rather than a new injection architecture, but its size and reliability remain unverified until a target Dock binary and runtime tests are available. Continue the SIP-enabled backend investigation separately: a working 27 injection port would still retain injection's security-setting dependency.
