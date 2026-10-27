# Dock scanner validation

Date: 2026-10-25. Host: macOS 15.6 (24G84), Apple silicon.

## Verified

- `task dockscan`: standalone Odin diagnostic built with warnings as errors.
- `task check`: source, payload, tests and diagnostic pass unused import/variable checks.
- `task test`: 147 tests pass.
- `task test:dockscan`: 17 tests pass with memory tracking, in both normal and candidate-enabled configurations. Covers Mach-O mutations, offset/slice selection, ambiguity, ranking, metadata/proposal checks, progress, MobileAsset ZIPs and stored/compressed/truncated/corrupt pbzm chunks.
- `task test:raven`: all 33 upstream vectors pass, plus framing and deterministic mutations (53 checks total); all four known-corruption fixtures are rejected. Decoder tests also pass AddressSanitizer and UndefinedBehaviorSanitizer.
- Vendored source/header/vector Git blob hashes match upstream commit `700b88c4b2e1b1d96e499d172dfa0b8e5d9134ab`. Decoder code is unmodified, 0BSD-licensed, and statically linked. No Python runtime or external decoder executable is needed.
- `task addition:macos27`: isolated arm64e candidate payload built, ABI-normalized and ad-hoc signed. `codesign --verify --strict` passes. It is not installed or injected.

## Real acquisition

The user's terminal downloaded Apple's InstallAssistant for 27.0.1 / 26A434 and expanded it without running the installer. SharedSupport.dmg contains a MobileAsset ZIP, not a nested system-image tree. Numbered payloads inside the ZIP use pbzm/LZRAVEN. Stock aa and installed ipsw rejected them on this host.

Shoji now decodes pbzm in bounded chunks using the pinned native decoder, then asks aa to extract only Dock and SystemVersion.plist. Real extraction completed successfully on macOS 15.6. The system plist inside the decoded payload independently confirms 27.0.1 / 26A434.

The agent environment cannot mount disk images (unable to set up framework server / Device not configured); the user's terminal can. For this validation only, the installed 7zz copied the MobileAsset ZIP out of the retained image. The diagnostic then performed the ZIP/payload extraction. 7zz is not a runtime dependency. A fresh uninterrupted network-to-snapshot run is not claimed: validation crossed the retained package, image and ZIP boundaries. Recovery with --extracted preserves its source and does not assert package provenance it did not verify itself.

Target Dock SHA-256: `b704affba65f732ffd6676c3bb22c94abc737ee73af8bdf29a5ef02650cde33e`. Arm64e UUID: `3bdf6a3b866b3c07920ce9e7fb57b56b`. This matches the binary identity in the upstream 26A434 report referenced in [the investigation](../MACOS_27.md).

## Static port evidence

The explicit 27.0.1 profile is based on [fork commit 49c2d035](https://github.com/AhsanFazal/yabai/commit/49c2d035aa0a7d99f6ebf7f7d327972d6a707bb4). The original Dock-Spaces prefix has two hits referencing different globals. Shoji extends it through the following conditional test to isolate the first upstream target. The final scan finds one valid match per target:

| Target | Unslid address | __TEXT offset |
|---|---|---|
| Dock Spaces global reference | `0x100030a98` | `0x30a98` |
| Desktop pictures global reference | `0x1000509fc` | `0x509fc` |
| Add Space | `0x100228cbc` | `0x228cbc` |
| Remove Space | `0x10018b9a0` | `0x18b9a0` |
| Move Space | `0x10018c554` | `0x18c554` |
| Focus window | `0x1000192bc` | `0x192bc` |
| Animation site | `0x100227508` | `0x227508` |

Evidence: `bin/dock-evidence/macos27/manifest.json`, `macos27/acquisition.log`, `macos27-scan.json`, and `macos27-comparison/report.md`. These ignored artifacts are removed by task clean; archive them elsewhere for permanent retention. The comparison uses the old 15.6 profile and reports unresolved baseline ambiguity and changed-function matches; it does not independently rediscover every 27 target. The successful seven-target result is the separate explicit 27.0.1 scan.

Installed baseline: 15.6 / 24G84, SHA-256 `64d2c0ab92e878b758604a63696c94ed6ffd6ee74ba1159c2396c2a0d58081fe`, arm64e UUID `b55c604c022530beaa0f543a5b33cb08`. Its scan has three ambiguous targets. A self-comparison proposal passed git apply --check during initial CLI validation.

## Remaining runtime work

Runtime work resumed at the user's request on 2026-10-25; the desktop exact-image compatibility check now passes for 27.0.1 / 26A434; VirtualBuddy 2.2.1 completed the guest restore. Guest desktop build/Dock hash, clean recovery copy, injection and behavior checks remain pending. See [VM validation handoff](MACOS27_VM_VALIDATION.md) for the verified IPSW archive integrity, agent installation-service failure, desktop probe command, missing checks, and acceptance criteria. No guest runtime result has been obtained.

Static matching does not establish ABI, object identity, injection transport, or operation behavior. The normal payload still rejects macOS 27. An explicit `SHOJI_MACOS27_CANDIDATE=true` build accepts only 27.0.1 on arm64; task addition:macos27 writes it to `bin/macos27/shoji-sa.dylib`. No 27.2 or unknown-version fallback is enabled.

Additional scanner/acquisition validation remains separate from the runtime port: demonstrate a fresh uninterrupted fetch-to-snapshot run, and improve or investigate the old 15.6 profile's three ambiguous targets and unresolved cross-version comparison results. The explicit seven-target 27.0.1 scan does not close those comparison gaps.

Run the candidate on a separate 27.0.1 installation and validate handshake/capabilities, Space focus/create/remove/reorder, display transfers, window movement, layer/opacity/animation behavior and recovery before enabling daily-use support. This session did not install macOS, restart Dock, load the candidate, replace the working payload, or change SIP settings.
