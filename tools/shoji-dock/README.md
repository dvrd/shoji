# Dock compatibility diagnostic

Build with `task dockscan`; run `./bin/shoji-dock --help`. This is a standalone Odin CLI for Apple silicon. It uses Apple's Command Line Tools for disassembly and system utilities for package download/extraction. It does not load Shoji's payload, restart Dock, apply a patch, or modify system security settings.

## Workflow

```sh
./bin/shoji-dock snapshot --out ./bin/dock-evidence/current
./bin/shoji-dock fetch --build 26A434 --out ./bin/dock-evidence/macos27
./bin/shoji-dock scan ./bin/dock-evidence/macos27 --out ./bin/dock-evidence/scan.json
./bin/shoji-dock compare ./bin/dock-evidence/current ./bin/dock-evidence/macos27 --out ./bin/dock-evidence/comparison
```

Output directories must be new. Commands create missing parent directories. Snapshot directories contain `Dock` and `manifest.json`, including the full input SHA-256, selected slice UUID/architecture, OS version/build, and metadata provenance. Fetch additionally records its catalog/product/download provenance and package SHA-256. Local input is accepted with:

```sh
./bin/shoji-dock snapshot --binary ./Dock --version 27.0.1 --build 26A434 --out ./bin/dock-evidence/manual
./bin/shoji-dock fetch --package ./InstallAssistant.pkg --build 26A434 --out ./bin/dock-evidence/extracted
```

Version/build flags for a manually supplied binary are user assertions, not independently verified OS identity. Installed snapshots read the local system plist. Extraction validates the requested build against `SystemVersion.plist` inside the extracted system image before publishing a snapshot.

## Acquisition

Fetch resolves the exact build from Apple's public software-update catalog. Use `--catalog HTTPS_APPLE_URL` for another public catalog, including a public beta channel. `--url HTTPS_APPLE_URL` accepts an explicit InstallAssistant package URL when its catalog entry has expired; the extracted system build still has to match. An unavailable build is never replaced with another version.

Packages are checked with `pkgutil --check-signature`, expanded without executing the installer, and searched for nested system disk images. Images are attached read-only with browsing and auto-open disabled, then detached. This first implementation handles InstallAssistant packages; it does not implement IPSW restoration or account-authenticated downloads. Extraction can require substantial temporary storage. Failed workspaces are retained and their paths are printed; successful acquisition removes its workspace after detaching images.

Interactive fetches show a single animated status line with the current stage, elapsed time, and received bytes during downloads. Catalog lookup also shows the number of products examined. Redirected output and `TERM=dumb` use plain stage messages; `--no-progress` explicitly disables animation. URLs and subprocess output go to the printed acquisition log, copied to `acquisition.log` in the completed snapshot. Errors clear the status line and include native diagnostics. Rebuilds replace the executable atomically, so an already running fetch keeps using its original binary.

To retry discovery after package extraction, use `fetch --build BUILD --out DIR --extracted /path/to/workspace/expanded`. This reuses the extracted files without downloading or expanding the installer again, and leaves that input directory intact. It verifies the discovered system's actual build; it does not recheck the original package signature or record a package digest. Image-mount and nested-package failures are reported with their native diagnostics instead of being silently treated as missing Dock binaries.

MobileAsset ZIPs inside SharedSupport are recognized. The scanner visits numbered `AssetData/payloadv2/payload.NNN` members one at a time and asks Apple's `aa` to extract only Dock and its system version metadata. It excludes firmware, patch and ECC files. Shoji includes a pinned, statically linked 0BSD decoder for `pbzm` / LZRAVEN. The Odin container reader validates sizes, processes one chunk at a time with a 64 MiB per-chunk limit, rejects corrupt streams and removes partial output. This successfully extracted build 26A434's Dock on macOS 15.6; no additional decoder installation is required.

**Validation limit:** download/package expansion and image mounting ran in the user's terminal; the new decoder was validated against the retained real MobileAsset ZIP. The agent environment cannot resolve Apple's download hosts or mount disk images. See [recorded evidence](../../docs/DOCK_SCANNER_VALIDATION.md) for the validation boundaries. Static scanning does not establish live injection compatibility.

## Reading scan results

The scanner parses thin and universal 64-bit Mach-O images, selecting arm64e preferentially when both Apple silicon subtypes exist. Intel-only inputs are rejected. It scans executable sections and reports every match with its unslid virtual address, full-file offset and offset relative to the image's `__TEXT` base. The last coordinate is used by Shoji's runtime pattern tables; these coordinates must not be interchanged.

The scan profile is a set of existing version-specific Shoji patterns, not an assertion that the input OS is supported. A snapshot from an existing supported version uses its own profile. Unknown versions default to the latest existing profile, `26.6`; use `--profile 15.6` or another known version explicitly when useful. Comparison defaults to the baseline profile.

The explicit `27.0.1` offline profile matches all seven targets uniquely in build 26A434 and is selected automatically for that snapshot version. This does not enable the normal payload on macOS 27. `task addition:macos27` builds a separate opt-in candidate for runtime validation, at `bin/macos27/shoji-sa.dylib`, without installing or loading it. Later 27.x profiles are not inferred.

Statuses distinguish `matched`, `moved`, `ambiguous`, `missing`, `no_pattern` and `invalid_global_reference`. A decoded global reference is an address calculation, not proof of the pointed-to object's identity. Scan exits 1 if any target is unresolved or ambiguous; this is an analysis result, not a command failure. Usage, file, tool and download errors exit 2. Successful commands exit 0.

## Comparison and baseline ambiguity

A comparison produces `analysis.json`, `report.md`, and the exact pattern source used. It requires a unique old-pattern match for each target, or an explicit baseline address selection. Ambiguous baseline targets remain unresolved rather than silently selecting the first match:

```sh
./bin/shoji-dock compare BASELINE TARGET --out COMPARISON \
  --baseline-select dock_spaces=0xADDRESS \
  --baseline-select focus_window=0xADDRESS
```

Use addresses from that baseline's scan, and review its disassembly/reference evidence. Addresses depend on the input image; do not copy examples from another build.

Where a known pattern is missing, assistance compares 24-instruction windows. It normalizes certain relocation-sensitive ARM operands and ranks up to five candidates with a structural score of at least 0.60. Shared strings from directly decoded ADRP/ADD references contribute a small bonus. Function entry candidates use `LC_FUNCTION_STARTS`, falling back to pointer-authentication prologues when it is absent. Global-reference and animation-site candidates are searched within executable code.

This is bounded instruction comparison, not decompilation or a complete call-graph/selector-reference analysis. Extensive rewrites, register allocation changes, dynamic references and changed calling conventions can defeat it. Scores are heuristics, not probabilities. Missing evidence stays unresolved. Each candidate includes disassembly from its actual address, references, a proposed instruction pattern, and the number of matches for that pattern.

## Proposed patches

After reviewing candidates, explicitly choose them:

```sh
./bin/shoji-dock propose COMPARISON \
  --select add_space=candidate-2 \
  --select focus_window=candidate-1 \
  --out ./bin/dock-evidence/macos27.patch
```

The tool checks the target binary's digest again, verifies each selected pattern matches exactly once at the selected address, and checks that the pattern-table source has not changed. It emits a unified diff containing the selected patterns and scan starts. It does not apply the diff or change the supported-version gate. The target binary must still be accessible at its recorded path.

Proposals use the source table's existing OS version fields. The patch comment records the exact analyzed build/hash, but the emitted condition selects a version, not a build. Review the patch, instruction semantics, Swift context/arguments and object layout, then perform separate runtime validation before enabling support. No static scan certifies injection compatibility.

## Tests

`task test:dockscan` exercises malformed/truncated and universal Mach-O images, offset mapping, pattern ambiguity, normalized ranking with real disassembly, catalog/build metadata, snapshot tampering and patch evidence checks. Parsing is also exercised against 500 mutated Mach-O headers. CI runs these tests on Apple silicon.

`task test:raven` runs upstream native decoder vectors, corruption and mutation tests. The pinned source, license and provenance are in `vendor/liblzraven/`.
