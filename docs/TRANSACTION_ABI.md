# SkyLight transaction return-value investigation

Target: macOS 15.6 (24G84), arm64; investigation date 2026-10-25. No window effects, injection, Dock restart or transaction calls were performed for this investigation.

## Conclusion

Shoji must not interpret the return registers of `SLSTransactionOrderWindowGroup`, `SLSTransactionSetWindowSystemAlpha` or `SLSTransactionCommit` as `CGError` on this target. Their normal paths return after a **void cleanup operation**, without assigning a status to `w0`. A nonzero value observed through an integer declaration can be an incidental pointer or another leftover register value; it does not establish native failure.

Calling these functions through void-returning declarations matches their observed caller-visible behavior. This is not a claim that Apple's unavailable private source headers explicitly spell their return types `void`. It is a target-specific finding that no defined error result is furnished by the inspected implementation.

Argument conventions remain unchanged:

| Function | Observed arguments |
| --- | --- |
| Order window group | `x0`: transaction pointer; `w1`: window ID; `w2`: order; `w3`: relative window ID |
| Set system alpha | `x0`: transaction pointer; `w1`: window ID; `s0`: 32-bit float alpha |
| Commit | `x0`: transaction pointer; `w1`: synchronous selector |

## Local evidence

A read-only program opened SkyLight, resolved the three symbols, and copied executable bytes to temporary assembly. LLVM disassembly examined the resulting object. It also decoded the relevant authenticated import stubs and read their pointer slots; it never invoked their targets. Temporary artifacts are `/tmp/shoji-transaction-abi.c`, `/tmp/shoji-transaction-abi.s`, `/tmp/shoji-transaction-abi.o` and `/tmp/shoji-transaction-abi-disasm.txt`. These paths are session artifacts, not a permanent reproducibility package.

### Ordering and alpha setters

The ordering function serializes a command and its three integer operands, then invokes a shared helper at setter offset `-0x74`. After that call at ordering offset `+0x140`, the remaining instructions check the stack guard, restore registers and return. They never write `x0` or `w0`.

The alpha setter likewise serializes a command, window ID and float value, invokes the same helper at alpha offset `+0x15c`, then performs a stack check and returns without writing the return register.

The helper appends a copied callback to the transaction's callback collection and finishes with a tail call to `_Block_release`. The import pointer resolved to exactly the same address as `dlsym(RTLD_DEFAULT, "_Block_release")` in the investigating process. This is stronger evidence than guessing a function from an adjacent symbol or from a return value that happens to resemble a pointer.

Apple's installed SDK declares `_Block_release` as void in `usr/include/Block.h:34`. LLVM's corresponding declaration agrees. Consequently, there is no defined integer status for these setter epilogues to forward. [LLVM Block.h](https://github.com/llvm/llvm-project/blob/main/compiler-rt/lib/BlocksRuntime/Block.h)

### Commit

The commit implementation submits its serialized transaction and invokes a final cleanup helper at commit offset `+0x208`, forwarding transaction, submission result and buffer-ownership information to that helper. The outer function then checks the stack guard, restores registers and returns without assigning a return value.

The cleanup helper processes the submission result internally and clears transaction state. Its normal final call, at commit-relative offset `+0x4a8`, resolves through its authenticated import pointer to `os_unfair_lock_unlock`, confirmed with `dladdr`. The helper and outer commit return without replacing `x0` afterward. Thus a submission result used inside commit is **not propagated as a caller-facing CGError**.

Apple's installed SDK declares `os_unfair_lock_unlock` as void in `usr/include/os/lock.h:155`. Apple's source headers provide the same contract. [Apple lock.h](https://github.com/apple-oss-distributions/libplatform/blob/main/include/os/lock.h)

These offsets refer to the inspected build only. Recheck after OS changes; the temporary copied assembly concatenates independent function bodies, so its synthetic addresses must not be mistaken for their original relative placement when decoding cross-function branches.

## Why upstream declarations are insufficient

Yabai's reverse-engineered declarations use `CGError` for all three functions. However, its proxy swap and ordering implementations discard all three results. That code therefore establishes argument usage, but does not validate reading a status result. Shoji introduced observable false failures when it started accumulating those registers as native error codes. [Upstream declarations](https://github.com/asmvik/yabai/blob/master/src/misc/extern.h), [Upstream transaction usage](https://github.com/asmvik/yabai/blob/master/src/osax/payload.m)

## Verification requirements

Removing invalid status checks must not become an unconditional claim that the requested effects succeeded. Validate transaction allocation, window ownership and continued existence separately. After submission, read independently observable state and check actual rendering/order where possible. System alpha is distinct from ordinary application alpha, so an ordinary-alpha readback alone cannot prove system-alpha restoration. Report unavailable verification explicitly.

Recovery must attempt real-window restoration and dispose of temporary proxy windows even after verification fails. Preserve recovery records until restoration is established. These changes should first build as an isolated candidate; modifying source does not update an already injected payload, and applying that payload requires a separately authorized loading workflow.

## Isolated correction and live evidence

The correction declares the three transaction calls without results and removes all integer-error accumulation from their return registers. A non-null transaction and valid ownership still gate submission. An OK response acknowledges the submitted transaction; it is not independent visual proof. Recovery similarly acknowledges its restoration request after ownership validation. This must be checked live after the payload is applied, rather than presenting a returned register as evidence of restoration.

`task addition:transaction-fix` builds only `bin/transaction-fix/shoji-sa.dylib`; it does not replace or load the installed addition. The arm64e candidate passes warnings-as-errors compilation, ABI normalization and strict signature verification. Candidate SHA-256: `ddf81f63155edbc3f2a26241be0259f54fee53ef1c66b779965642541eaa3fbf`. Installed payload remains SHA-256 `5bafad78e7e11fa047db7ef0e7d2a08066791ebf273adf6551a6ba111386c248`, backed up at `bin/transaction-fix/shoji-sa.before.dylib`.

Source checks passed. All 30 selected addition/proxy/animation/recovery/reload tests passed. The full suite ran 159 tests and reported one failure in `native_edge_drag_resizes_the_split_without_animation` (`tests/native_resize_test.odin:18`). That test is not evidence for this payload correction; do not describe the latest full run as entirely passing.

A disposable owned-window control was launched through LaunchServices using the extended `tools/live-animation` helper's `transaction-alpha-control` mode. Requested system-alpha values were 1, 0, 0.5, 1; both `SLSGetWindowAlpha` and fresh `SLSWindowIteratorGetAlpha` observations stayed 1. See [raw results](evidence/transaction-24G84/owned-alpha-control.jsonl) and [requested values](evidence/transaction-24G84/owned-alpha-control.txt). This ordinary-process control does not establish whether the system-alpha writes took effect or whether either getter measures effective composed visibility. Neither getter is therefore used as proof of successful restoration.

The live controller was restarted with animation disabled to release its failed proxy. The journal remains preserved for recovery through the corrected addition. No manual journal deletion, Dock restart, reinjection, or installed-payload replacement was performed while preparing this correction. Applying the staged payload and repeating real animation/recovery checks remains pending explicit Dock-restart approval.

Update: the user approved the Dock restart, the correction was applied, and Shoji reloaded it. The pending journal cleared. Real Ghostty animation commands and a later two-window floating-fixture test completed without the former Proxy_Order error; the fixture test finished with an empty journal and no remaining fixture windows. See [live validation](SCROLL_LIVE_VALIDATION.md). The ordinary alpha getter limitations above remain unchanged; successful submission and cleanup do not certify visual frame pacing.
