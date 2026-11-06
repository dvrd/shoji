# Exact-build ordering analysis

`ExportOrdering.java` exports instructions, direct-call references and decompiler
output for the recorded 26A434 SkyLight candidate, its direct callers and a
bounded set of ordering helpers. It does not execute SkyLight or install hooks.
Decompiler signatures are hypotheses, not ABI guarantees. External libraries
are not automatically imported; unresolved and indirect calls remain gaps.

The local toolchain uses Ghidra 12.1.4 and Temurin JDK 21.0.13+9, under the
ignored `.toolchain/` directory. The verified download SHA-256 values are:

- Ghidra ZIP: `ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db`
- JDK archive: `bf036b35b071bfb2f54f2c0af8ee8d88afa95ee6eb3dce02c0f94cfc2524d04a`
- Input SkyLight: `b7b3f079742fd1f2b34ea98c51affc59fc4360f12592ff36755a7f591f33c673`

This Ghidra release does not ship macOS native decompiler binaries. Build them
first using the release's supplied Gradle wrapper (run from its
`support/gradle` directory with the local JDK selected):

```sh
JAVA_HOME=/absolute/path/to/jdk/Contents/Home ./gradlew buildNatives --no-daemon
```

Then run from the repository root, choosing a fresh project name when an
interrupted import has left an incomplete project:

```sh
JAVA_HOME="$PWD/.toolchain/jdk-21.0.13+9/Contents/Home" \
  .toolchain/ghidra_12.1.4_PUBLIC/support/analyzeHeadless \
  "$PWD/artifacts/windowserver-26A434/ghidra" SkyLightOrderingNative \
  -import "$PWD/artifacts/windowserver-26A434/extracted/SkyLight" \
  -scriptPath "$PWD/tools/window-interception/rea/ghidra" \
  -postScript ExportOrdering.java "$PWD/artifacts/windowserver-26A434/ghidra/ordering.txt" \
  -log "$PWD/artifacts/windowserver-26A434/ghidra/analysis-native.log" \
  -scriptlog "$PWD/artifacts/windowserver-26A434/ghidra/script-native.log" \
  -max-cpu 4
```

Allow this command to finish; the initial import/analysis can exceed two
minutes. A completed shell command alone does not establish export success:
check analysis and script logs, the output header and decompilation errors.
Retain interrupted projects/logs as failed-run evidence rather than overwriting
them or reporting their partial analysis as complete.

## Missing cache stubs

The native run completed analysis and exported 49 selected functions. Its log
contains calls into memory outside the extracted SkyLight image. A targeted
cache inspection identified `0x1880dc3d0` as an authenticated stub whose pointer
slot is `0x1e7ff5020`; `ipsw dyld dump --addr` resolves that slot to
`0x1806766f0`, `_free` in `/usr/lib/system/libsystem_malloc.dylib`.

A full `ipsw dyld stubs` listing was terminated with exit 137 and produced an
empty output file. The cause of that termination was not established. Do not
treat `cache-stubs.txt` as a complete listing.

`resolve-stubs.swift` instead resolves a bounded list of warning addresses with
targeted disassembly, decoded pointer reads and destination image queries. It
only accepts the observed `adrp/add/ldr/braa` sequence; other forms remain
unresolved. Every result retains commands, exit statuses and raw output.

```sh
swift tools/window-interception/rea/ghidra/resolve-stubs.swift \
  artifacts/windowserver-26A434/dyld/dyld_shared_cache_arm64e \
  artifacts/windowserver-26A434/ghidra/unresolved-addresses.json \
  artifacts/windowserver-26A434/ghidra/resolved-stubs.json --limit 8
```

Resolving a stub identifies its destination; it does not itself import that
library into Ghidra or repair previous decompiler output. Only use libraries
from this recorded guest cache, never a host-build substitute.

The first eight warning addresses resolved to the following destinations. Raw
commands and both output streams are retained in `resolved-stubs-corrected.json`;
the initial report missed library metadata emitted to stderr and is retained as
`resolved-stubs.json` rather than silently replaced.

| Stub | Destination | Guest library |
| --- | --- | --- |
| `0x1881107b0` | `__ZdlPv` (operator delete) | `/usr/lib/libc++abi.dylib` |
| `0x1880e4260` | `_CFRelease` | CoreFoundation |
| `0x1880dc3d0` | `_free` | `/usr/lib/system/libsystem_malloc.dylib` |
| `0x1880e1e70` | `_kdebug_trace` | `/usr/lib/system/libsystem_kernel.dylib` |
| `0x1880dcc60` | `_objc_release` | `/usr/lib/libobjc.A.dylib` |
| `0x1880e6a40` | C++ mutex unlock | `/usr/lib/libc++.1.dylib` |
| `0x1880dd770` | `_objc_autoreleasePoolPop` | `/usr/lib/libobjc.A.dylib` |
| `0x1880e2270` | `_objc_msgSend` | `/usr/lib/objc/libobjcMsgSend.dylib` |

These are the most frequent warning targets, not all SkyLight dependencies.
The completed warning-address pass is in `resolved-stubs-all.json`: 71 of 130
addresses resolved through authenticated pointer stubs to 19 distinct libraries.
The other 59 all match `adrp x1; add x1; b 0x188000800`, classified separately
in `selector-stub-candidates.json`. Targeted cache lookup identifies that common
destination as `_objc_msgSend` in `/usr/lib/objc/libobjcMsgSend.dylib`. The first
example, `0x18807c1f0`, supplies `x1 = 0x1f4ccfa00`, whose bytes begin with the
selector `contextId`. These are selector-dispatch stubs, not 59 additional
libraries. The concrete receiver method remains dynamically determined; this
classification is not a recovered call graph of those methods.

Extracting the 19 confirmed images records results in
`library-extraction-all.json`. This still does not repair Ghidra's stub mappings.
Extracted files and their recorded SHA-256 values belong in the ignored local
`libraries/` directory and `library-extraction.json`, not in commits.

## Analysis-only stub reconstruction

`MapCacheStubs.java` consumes six-column TSV records: stub address, destination,
library path, symbol, 16 original instruction bytes in hexadecimal, and a scope
note. It checks the original executable SHA-256 and refuses to overwrite mapped
memory. The manifest was built from the recorded disassembly/pointer evidence,
not from guessed names. It adds read/execute analysis blocks and external thunk
links; it neither patches the extracted file nor modifies any running process.

The first mapped run used a copy of the original saved project,
`SkyLightOrderingMapped`, leaving `SkyLightOrderingNative` unchanged:

```sh
JAVA_HOME="$PWD/.toolchain/jdk-21.0.13+9/Contents/Home" \
  .toolchain/ghidra_12.1.4_PUBLIC/support/analyzeHeadless \
  "$PWD/artifacts/windowserver-26A434/ghidra" SkyLightOrderingMapped \
  -process SkyLight -noanalysis \
  -scriptPath "$PWD/tools/window-interception/rea/ghidra" \
  -postScript MapCacheStubs.java "$PWD/artifacts/windowserver-26A434/ghidra/cache-stub-manifest.tsv" \
  -postScript ExportOrdering.java "$PWD/artifacts/windowserver-26A434/ghidra/ordering-mapped.txt" \
  -log "$PWD/artifacts/windowserver-26A434/ghidra/analysis-mapped.log" \
  -scriptlog "$PWD/artifacts/windowserver-26A434/ghidra/script-mapped.log" -max-cpu 4
```

The mapping script is intentionally not rerunnable on already-mapped ranges.
Use another untouched project copy for a different reconstruction.

The completed run reports `MAPPED_CACHE_STUBS=130` and saves the modified project.
Both exports contain 49 selected functions. `halt_baddata` occurrences fell
from three to zero; warning comments fell from 81 to 78. No unavailable-function
markers appeared in either export. These counts measure output changes, not
correctness. External function signatures are not recovered by thunk links,
and the initial candidate still has an inferred `__swiftcall`/undefined-return
signature inconsistent with its known integer return consumer. It must not be
copied into a runtime hook declaration.

The original warning list is not an exhaustive list of external calls. The
mapped candidate still has five anonymous stub destinations; a separate focused
resolution pass uses `candidate-unresolved-addresses.json`. Resolving these and
recovering function prototypes is needed before trusting its allocator,
logging and error-path pseudocode. Dynamic Objective-C receivers remain unknown.

That follow-up resolved the five remaining candidate calls to
`_os_log_type_enabled`, `__os_log_impl`, `__platform_memset`,
`_malloc_type_malloc`, and `___stack_chk_fail`. The disjoint five-row
`candidate-stub-manifest.tsv` was applied to the mapped project and exported as
`ordering-mapped-v2.txt`. No anonymous `func_0x...` destinations remain in the
candidate pseudocode; this does not assert that every call has a correct
prototype. The additional library, `libsystem_trace.dylib`, was extracted from
the same cache, bringing the extracted-library count to 20. Comparison counts
and export hashes are recorded in `mapped-analysis-summary.json`.

## Prototype validation pass

The 78 remaining warning comments in the mapped export comprise 44 overlapping
global-symbol notices, 12 unsettled type-propagation notices, nine non-returning
path notices, three indirect-jump-as-call notices, six unreachable-block notices,
three jump-table recovery notices, and one unknown-calling-convention notice.
They are not 78 missing libraries. Non-returning paths can be legitimate and
overlapping symbols must not be deleted simply to suppress warnings.

The initial importer chose the Swift compiler specification. A new, independent
`SkyLightOrderingC` import explicitly selects
`-processor AARCH64:LE:64:AppleSilicon -cspec default`. The AppleSilicon language
definition maps `default` to `AARCH64_apple.cspec` (`__cdecl`), rather than the
Swift register model. This is an analysis-model correction for the C++ candidate,
not a claim that every Swift function in SkyLight uses C conventions.

`SetOrderingPrototypes.java` applies an explicitly labeled six-argument candidate
model with a signed 32-bit return; the handler consumes `w0` at `0x187528054`.
It also models six resolved C externals: `free`, `memset`, `malloc_type_malloc`,
`os_log_type_enabled`, `_os_log_impl`, and `__stack_chk_fail`. The last is marked
non-returning. Allocation/logging declarations were checked against the host
SDK's `malloc/_malloc_type.h:30,51` and `os/log.h:425-438`; these headers are
reference declarations, not extracted guest source. Stub destinations themselves
were independently resolved against the guest cache. The script does not infer
private structure layouts, borrowed-pointer lifetimes, accepted nonzero boolean
values or runtime thread safety. The candidate signature is an applied hypothesis
and must not be represented as an independently recovered decompiler signature.

The first C-model import failed the script's record-count assertion: Ghidra had
eight matching external records for six distinct names because `_free` and
`___stack_chk_fail` also existed in its placeholder namespace. That provisional
output is retained as `ordering-c-model.txt`. Validation now counts distinct
names and logs every qualified external location. The corrected run completed
without a script error, recorded six names/eight records, and saved
`ordering-c-model-validated.txt`. Both exact-cache mappings and the applied
signature model remain analysis-only; the recovered original binary is unchanged.

The validated export contains all 49 functions and no bad-data or unavailable
markers. Relative to `ordering-mapped-v2.txt`:

- Type-propagation notices fell from 12 to one, in the candidate.
- Jump-table recovery notices fell from three to one, in `start_order_window`
  at `0x1873e8ba0`.
- One locked-storage/unknown-convention notice remains in `disable_pip_zoom`.
- 44 overlapping-global notices remain; these were not suppressed by deleting
  or renaming symbols.
- The known non-returning stack-check failure model introduced 44 informative
  `Subroutine does not return` comments. Total warning comments increased from
  78 to 106, so total warning count is not a useful stand-alone quality metric.

The candidate now explicitly returns `local_4cc` and models its heap allocation
as a pointer-returning call. `prototype-comparison.json` records category counts
and output hashes. The candidate's unresolved private structure types and the
`start_order_window` indirect target are still meaningful analysis gaps.

## Residual investigation

The display-manager virtual call has a concrete static target chain, recorded
with commands in `geometry-virtual-target.json`: the singleton factory constructs
`CAWSManager`, its constructor installs address point `0x1e87410d0`, and virtual
slot `0x128` decodes to `0x1874d53fc`, `invalidate_geometry_seed()`. See the
build-specific ordering document for the instruction addresses. No call-flow
override was applied: this is a shipped-factory/vtable inference, not observation
of a running receiver or proof against runtime replacement.

`RefineOrderingState.java` adds a separately named partial 32-byte ordering-state
type with explicit unknown slots, models the two ordering helpers, and assigns
the Apple C/C++ convention to the zero-argument `disable_pip_zoom()` helper.
The latter removes the locked-storage/unknown-convention notice. The partial
structure did **not** remove the candidate's last unsettled-type warning; do not
invent additional fields to make the output look clean.

The completed export `ordering-refined.txt` still contains 49 functions, no
bad-data/unavailable markers, one unsettled-type warning, and the deliberately
retained indirect-flow warnings. `refined-summary.json` records its hash and
warning categories. Reference annotations and partial types are not source
declarations, ABI tests, or evidence of a presentation hold.

## Type-propagation resolution

`ExportCandidateDebug.java` captures one candidate's standalone-decompiler save
state without modifying the project. It explicitly installs `DecompileOptions`;
the initial null-options failure remains in `analysis-export.log`. A separate
ignored debug build under `typeprop-debug/cpp/` uses Ghidra's `CPUI_DEBUG`
support. Only that copy excludes unavailable BFD-only modules and accepts a
non-terminal stdin; the installed Ghidra source and binaries were not changed.
The original exported XML is also preserved. Its standalone copy moves the
existing `undefined` declaration before its first reference solely to satisfy
the restore parser; it does not change a type or the analyzed bytes.

The successful `typeprop-trace-v3.log` covers passes zero through seven. Across
the late passes, the only changing event is varnode
`u0x00023800(0x0001873f6728:293b)`, the `_os_log_impl` buffer argument at
`0x1873f6728`. It alternates between `undefined4 *` and `undefined8 *`. This is
not evidence for another private ordering-state field. The SDK declaration at
`os/log.h:436-437` specifies `uint8_t *buf`; `SetOrderingPrototypes.java` now
uses that exact pointer type instead of a generic pointer.

The model was applied in the separate `SkyLightOrderingLogBuffer` project,
leaving `SkyLightOrderingC` and all earlier exports unchanged:

```sh
JAVA_HOME="$PWD/.toolchain/jdk-21.0.13+9/Contents/Home" \
  .toolchain/ghidra_12.1.4_PUBLIC/support/analyzeHeadless \
  "$PWD/artifacts/windowserver-26A434/ghidra" SkyLightOrderingLogBuffer \
  -process SkyLight -noanalysis \
  -scriptPath "$PWD/tools/window-interception/rea/ghidra" \
  -postScript SetOrderingPrototypes.java \
  -postScript RefineOrderingState.java \
  -postScript ExportOrdering.java "$PWD/artifacts/windowserver-26A434/ghidra/ordering-log-buffer.txt" \
  -log "$PWD/artifacts/windowserver-26A434/ghidra/analysis-log-buffer.log" \
  -scriptlog "$PWD/artifacts/windowserver-26A434/ghidra/script-log-buffer.log" -max-cpu 4
```

The completed `ordering-log-buffer.txt` contains all 49 functions, no
bad-data/unavailable markers and no type-propagation warning. The indirect-flow
warnings remain intentionally present despite the static target inference;
44 overlapping-global notices also remain. `log-buffer-summary.json` records
before/after categories and hashes. Resolving this decompiler warning does not
validate private structure ownership, runtime receivers, accepted nonzero
booleans, thread/lock behavior, or the native/Odin ABI.
