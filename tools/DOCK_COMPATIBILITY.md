# Investigating Dock compatibility

This describes Shoji's current implementation and a repeatable process for a new macOS build. Source inspection date: 2026-10-25. It does not certify any additional OS version. See [arm64e implementation details](ARM64E.md).

## How Shoji injects

The normal daemon runs outside Dock. On Apple silicon, an explicit `shoji --load-sa` invocation (payload resolved beside the executable) delegates to the separate arm64e `shoji-loader` executable. The daemon's `--sa` recovery path can invoke loading through the configured noninteractive sudo command. The normal window manager does not become a root daemon.

The loader locates the user's running Dock, obtains its task port with `task_for_pid`, and allocates memory in that process for bootstrap code, a stack and shared data. It copies the relocation-independent bootstrap and payload path there, makes the code executable, and creates a remote Mach thread. The arm64 implementation signs the initial thread-state pointers and converts the state for the target before starting it. These steps require the system's injection permissions; a normal Accessibility grant is insufficient.

The Mach thread calls `pthread_create_from_mach_thread` to start a proper pthread. That worker calls `dlopen` on `shoji-sa.dylib` **inside Dock**. A raw Mach thread lacks the pthread runtime context needed for general library work. The library's initializer starts its local socket server and dispatches discovery and operations onto Dock's main queue.

The loader reads completion flags and library-load errors back from remote memory. It reclaims stack/data only when completion is known; uncertain paths retain allocations. A small copied code allocation remains mapped until Dock exits because a worker may still be returning through it. This is not unloading/replacing a running library on each build.

The payload uses Dock's own WindowServer connection, internal objects and functions. Shoji sends commands to `/tmp/shoji-sa_<uid>.socket`; the server checks the connecting user's UID and validates the protocol. Ordinary AX window management stays in Shoji.

Relevant source:

| Responsibility | Source |
| --- | --- |
| CLI entry and loader delegation | [main](../src/main.odin), [injector](../src/inject/loader.odin) |
| Code copied into the target | [bootstrap](../src/inject/loader.odin) |
| arm64e thread-state handling | [state](../src/inject/state_arm64.odin) |
| Library initialization and requests | [server](../src/payloads/dock/payload.odin) |
| Finding private Dock objects/functions | [discovery](../src/payloads/dock/payload.odin), [patterns](../src/dock/patterns_arm64.odin) |
| Swift calling-convention bridge | [bridge](../src/inject/calls_arm64.odin) |

This is runtime code injection, not an Apple-supported extension point. It does not replace WindowServer or edit Dock's executable on disk. Discovery can additionally patch an animation instruction **in Dock's memory** when its signature resolves and memory protection changes succeed; that is separate from loading the library.

## What community patches changed

The macOS 27 contributor compared the new Dock with the previous implementation. Five target signatures survived; two needed changes. Scan starts also needed adjustment. The reported instruction differences included a branch target and a conditional-branch displacement, so the patch wildcarded those variable bytes while retaining identifying context. Explicit OS handling was added too. [Compatibility discussion](https://github.com/asmvik/yabai/issues/2802), [patch](https://github.com/AhsanFazal/yabai/commit/49c2d035aa0a7d99f6ebf7f7d327972d6a707bb4)

Their checker classifies targets as matching within the expected search window, found elsewhere, or missing. It scans for existing signatures; it does not discover the meaning of an unknown function. Missing signatures require disassembly. Multiple matches require investigation. [Contributor's checker source](https://gist.github.com/AhsanFazal/d18a54b9dc0f259b49e21b8ed70078d2)

This is usually a patch to **our compatibility tables**, rather than a patch to Apple's on-disk library. Source changes alone are not validation: a signature match must identify the intended operation with the correct ABI.

## Procedure for a future macOS build

1. **Capture a baseline.** Preserve a known working build and record OS version/build, hardware, architecture, SIP configuration, signing state, Dock SHA-256 and Mach-O UUID. Collect the same metadata for the target. Copy target binaries from a test installation for offline work; do not upgrade the only working environment just to obtain them.
2. **Classify the failure.** Separate task-port/thread/bootstrap errors, `dlopen` rejection, protocol mismatch, missing capabilities and incorrect operation behavior. A responsive socket proves neither function discovery nor functional compatibility. An unsupported-version message is a gate failure, not proof that Apple blocked injection.
3. **Scan offline.** Select the correct Mach-O architecture, map its segments and test every known signature. Report all matches, the scan range and each candidate's virtual address. Shoji's offsets are starts within the in-memory `__TEXT` mapping; they are not hard-coded absolute addresses. The external checker's raw file offsets must be mapped correctly before using them. Account for ASLR through the loaded image base.
4. **Investigate moved or changed targets.** Use Ghidra or another disassembler to compare old/new functions. Search references to Objective-C selectors, class names and related strings, then follow callers and data references to the desired operation. Shoji's existing source mentions `doBindingCommand:display` as a lead for the Dock Spaces global. Check prologues, surrounding instructions, branches and global-address construction. For globals, validate decoded ADRP/ADD references and object usage. Do not accept the first matching prologue merely because it resembles the old one.
5. **Verify the calling convention.** Inspect arguments, return values, object lifetime and implicit Swift context. Our add/move bridge passes context in `x20`; a matching function with a changed convention could still crash Dock. Confirm whether each target is a function entry, global reference or instruction patch site. Wildcard relocation-sensitive operands only when there is enough remaining context to distinguish candidates.
6. **Patch explicitly.** Add the intended version's gate, scan starts and patterns, plus any actual object-layout or ABI changes. Do not map every future release to the latest known version. Record exact build evidence and provenance alongside the changes. Keep unsupported operations unavailable.
7. **Verify without Dock first.** Build and run the loader's self-test and bootstrap checks on the test OS. These exercise our own process and copied code, not Dock's permissions or private objects. Add meaningful scanner checks for unique candidates and instruction decoding against the captured target. Current pattern tests verify parser/decoder behavior; they do not certify a new Dock binary.
8. **Validate on a separate GUI installation.** Test loading, the protocol and advertised capabilities first, then each operation using disposable windows and tracked disposable Spaces. Check actual OS state after completion, including asynchronous effects. Cover focus/create/remove/reorder, cross-display movement, layering, opacity, transforms and dialogs. Capture errors/crash reports. A working focus command does not validate destruction or reordering.
9. **Record a compatibility result.** Identify OS build, Dock hash/UUID, hardware, compiler/helper/payload versions, capabilities and operations tested. Treat later point releases as new targets. Preserve an accessible recovery path; do not make Dock restart an automatic experiment.

Useful read-only collection commands, run on the target installation:

```sh
sw_vers
uname -m
csrutil status
shasum -a 256 /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock
xcrun dwarfdump --uuid /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock
xcrun lipo -info /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock
xcrun otool -l /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock
```

Do not copy a universal binary's raw offsets into a selected slice or assume file offsets equal runtime offsets. Private framework code may reside in the dyld shared cache; analysis of SkyLight can require matching cache images/symbols in addition to the Dock executable.

## Transaction return values

`SLSTransactionOrderWindowGroup`, `SLSTransactionSetWindowSystemAlpha` and
`SLSTransactionCommit` return through a void cleanup call (`_Block_release`,
`os_unfair_lock_unlock`) without assigning `w0`, so their return registers are
not a `CGError` (disassembled on 24G84, 2026-10-25). Yabai declares them
`CGError` but discards the results; reading them produced false failures in
Shoji. The payload declares them without results. Validate the transaction,
window ownership and existence before submitting, and treat an OK response as
an acknowledgment of submission, not visual proof. Recheck on a new build.

Argument conventions:

| Function | Arguments |
| --- | --- |
| Order window group | `x0` transaction, `w1` window ID, `w2` order, `w3` relative window ID |
| Set system alpha | `x0` transaction, `w1` window ID, `s0` f32 alpha |
| Commit | `x0` transaction, `w1` synchronous selector |

## Tooling gap

Shoji now has a standalone Odin diagnostic built with `task dockscan`. It parses offline Dock images, selects the Apple silicon slice, reports all seven target matches, and provides comparison assistance and explicitly selected patch proposals. See [the CLI guide](shoji-dock/README.md). Local scans and fixture tests have been exercised; real macOS 27 acquisition/extraction and runtime compatibility remain unverified. The diagnostic is separate from `--load-sa` and never applies its proposed patches.
