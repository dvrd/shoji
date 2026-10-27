# Dock scanner design interview

Status: CLI implemented; local Dock snapshot/scan/comparison/proposal checks and ten tests pass. Real macOS 27 acquisition and comparison remain required for initial acceptance: shell download attempts failed resolving Apple's hosts, including outside the sandbox.

## Agreed scope

- Build the diagnostic in Odin.
- Include scanning and comparison assistance, rather than scanning alone.
- Find known instruction patterns, report all matches, and flag missing or ambiguous targets.
- Compare old and new Dock binaries with addresses and disassembly context to assist investigation of changed targets.
- Replacement patterns remain subject to maintainer review; pattern matches are not runtime compatibility certification.
- Include obtaining and extracting Dock binaries from Apple's downloadable macOS packages. Coupling to Apple's package formats is an accepted maintenance cost.
- Retain local-file analysis and installed-Dock snapshots for reproducible comparisons.
- Automated acquisition uses publicly downloadable Apple packages without Apple-account authentication. Restricted builds can be supplied as local files.
- Parsing, scanning, and comparison logic remain in Odin; disassembly uses Apple's Command Line Tools (`llvm-objdump` through `xcrun`).
- Produce an evidence report and a proposed compatibility-table patch. Generating a patch does not apply it or enable support for the target build.
- First-release analysis covers Apple silicon arm64/arm64e images, including architecture selection inside universal binaries. Intel comparison and patch generation are deferred.
- When known patterns disappear, rank replacement candidates using instruction structure and available references, and explain the evidence for each ranking. Require an explicit maintainer selection before a candidate is included in a proposed patch.
- Initial delivery must exercise the workflow against real binaries: snapshot the installed Dock, acquire a public macOS 27 build, scan and compare both, and produce evidence plus proposed patches for explicitly selected targets. Unresolved targets remain visible in the result.
- This delivery establishes static analysis and investigation assistance. Runtime injection compatibility requires separate validation.

## Acceptance criteria

- Snapshot identifies the installed Dock and records its build metadata and binary identity.
- Acquisition downloads and extracts a public macOS 27 package, retaining enough provenance to reproduce the analysis. An unavailable requested build is reported rather than silently substituted.
- Scanning selects the correct Apple silicon slice, reports all known-pattern matches with usable addresses, and identifies missing or ambiguous targets.
- Comparison supplies disassembly context and ranked replacement candidates with supporting evidence. Cases without sufficient evidence remain unresolved.
- Explicitly selected candidates can be used to generate reviewable proposed compatibility-table patches; the tool does not apply patches or enable a target build.
- The complete workflow is exercised on the current Dock baseline and acquired macOS 27 Dock. Reports distinguish static findings from runtime-tested compatibility.

## Implementation boundary

Acquisition, snapshots, static analysis, and report/patch generation are in scope. Apple-account authentication, Intel analysis, automatic patch application, and live injection testing are outside this first delivery. Scanner and comparison commands do not alter Dock or system security settings.

See [investigation procedure](../tools/DOCK_COMPATIBILITY.md) and [domain vocabulary](../CONTEXT.md).

## macOS 27 implementation evidence

Build 26A434 packages Dock inside a MobileAsset ZIP with pbzm/LZRAVEN payloads. The container reader and acquisition logic remain in Odin. Codec decoding uses the pinned, unmodified 0BSD C library documented in [`tools/shoji-dock/vendor/liblzraven/SHOJI.md`](../tools/shoji-dock/vendor/liblzraven/SHOJI.md), linked statically into the diagnostic. This avoids requiring macOS 27's newer Apple Archive decoder on the validation host. Real extraction and a seven-target unique static scan now pass; see [validation](DOCK_SCANNER_VALIDATION.md).

The user subsequently requested preparing the actual compatibility patch. Version-specific tables were added for 27.0.1, and a separate opt-in candidate payload can be built for target-OS validation. The scanner still never applies proposals or loads payloads, and the normal runtime OS gate remains unchanged.
