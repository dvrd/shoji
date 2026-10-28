# WindowServer ordering: macOS 27.0.1 / 26A434

Remaining implementation and validation work:
[WindowServer presentation gate backlog](WINDOWSERVER_REMAINING_WORK.md).

Static analysis of SkyLight extracted from the disposable VM's arm64e dyld
shared cache. Extracted image SHA-256:
`b7b3f079742fd1f2b34ea98c51affc59fc4360f12592ff36755a7f591f33c673`.
The guest WindowServer launcher SHA-256 is
`51a949ae77519ecca2efe2d9176cf85636a9fd91e2ba5b70817616c3b315ed7b`.
The extracted image, cache files, and REA evidence bundle are local ignored
artifacts under `artifacts/windowserver-26A434/`. REA used Hopper. Static
references do not establish runtime execution or exhaustive coverage.

## Observed

- The candidate
  `__ZL36CGXOrderWindowListSpaceSwitchOptionsP13CGXConnectionPKjPK10CGSOrderOpS2_jb`
  is at unslid `0x1873f6260` in this extracted image. Hopper infers six
  arguments and an integer return. Crucially, the `_XOrderWindow` handler
  calls it at `0x187528040` and stores `w0` into the response at
  `0x187528054` (evidence
  `ev_e3438d0f06d902e62e36e4b254af8a024988aed76c4d69eb7c800d8e96495b2f`).
  This is stronger than the inferred return type alone: a replacement must
  preserve that result. Vanish's `void` declaration must not be copied as an
  ABI guarantee for this build.
- `_XOrderWindowList` reaches the candidate through `__CGXOrderWindowList`
  (`ev_593e7f748a8e23431afb2a97654838833a74383ffe5aedebefb94b7ece0bf21c`,
  `ev_84deb28f4099c4451980d566fcf7f8d9e079b7cbf01efb0d13317ce4f6bbec2f`).
  `_XOrderWindowListWithOperation` reaches it through
  `CGXOrderWindowListWithOperation`
  (`ev_6e4b2edb943a2aa4a70df6c2a51cac59e960a55f78ae8b11fc5574f8a3a40495`,
  `ev_82254bb856939c1c7506062378d9a23b3dc9c2136c5b992f03d8476cfcfa0944`).
  `_XOrderWindowListWithGroups` reaches the group helper, which calls the
  candidate (`ev_0835413c3bbb0b7076eaa219b66b5f897eef133e32874400202685e720605dd8`,
  `ev_3233c792a3e54e58bcc2ab5f2281a7d4a3c7ab65864f24a5a0ea4e1e77304dea`,
  `ev_0b31bdc3bdd9b011283e38f95f3c5eadbd1d434623b94bbf871f88f7f4452f04`).
- `PKGTransactionOrderWindow` calls the candidate directly
  (`ev_ea326aff211dc9ec6d9dffd575b3606f5bea1d6335e257661b8e4df82f514a2a`).
  `PKGTransactionOrderWindowGroup` and `PKGTransactionSafeOrderWindowGroup`
  call the group helper (`ev_0aec7f0fed950f1cd6ac3a339f321d2650ee4da6a81317b53b293b1bfc035e2e`,
  `ev_d843420046655e119ada45f750eb39442b238543c518ca4f0af43c2f79d9a80b`).
  These are specific statically observed transaction paths, not a claim that
  every transaction or presentation path converges here.
- `start_order_window` has callers besides the candidate, including level
  changes, and calls `WSWindowUpdateOrderedIn`
  (`ev_8f3a418e6a492840d5137c4099f7d32c43a1ebc6dcf54235c08b05c3cf0286b5`).
  That does not prove those other callers present a first frame, but it rules
  out assuming that the candidate covers every invocation of the lower-level
  ordering operation.

## Candidate ABI ledger (static, not runtime validation)

The exact extracted artifact's handler and candidate instructions support this
working calling-convention map (`ev_c04d71d01ad8795082b17638f95bf0aa8c0420dda81d6ac03d041940103d3901`,
`ev_380ec5f5f764495c5bffead01f7c1b81b3f551f42fb9b1844a6bc951563c8fce`,
`ev_5a57e0bd3d46b9c8ce044b24abb13a6b4bd1d83e2edc7acbc375761d984fe1b6`,
`ev_c61da97f45758e0abb1eae5dc281cf946a1ec323e8841b87025a81cffc94731d`):

| Register | Observed role and limits |
| --- | --- |
| `x0` | `CGXConnection *`; the `_XOrderWindow` handler obtains it from the request's connection port. |
| `x1` | Window-ID array; indexed as 32-bit elements. `_XOrderWindow` supplies one on-stack ID. |
| `x2` | Order-operation array; also indexed as 32-bit elements. `_XOrderWindow` supplies one operation at the same stack address as its ID array. |
| `x3` | Relative window-ID array; indexed as 32-bit elements. `_XOrderWindow` supplies one on-stack ID. |
| `w4` | Element count. A zero count takes an error path; counts above 32 use a dynamically allocated array of 32-byte states. The ownership and success semantics of that allocation remain unresolved. |
| `w5` | Space-switch boolean, stored from its low 32 bits and passed as `w2` to switch-eligibility calls. Exact normalization and accepted nonzero representations remain unknown. |
| `w0` | Integer status consumed by `_XOrderWindow`. Its decompilation reports 1000 for missing-window/rights failures, 1001 on observed candidate validation errors, and -304 for malformed requests. These are observed paths, not a complete error table. |

`_XOrderWindow` passes a count of one and a false space-switch flag and checks
window rights before calling the candidate. This is one caller's stack lifetime,
not proof that every caller keeps the three arrays alive only synchronously or
that the count describes each array identically. The candidate calls
`finish_order_windows` before its observed display-update and cleanup paths;
this does not yet establish the last pre-composition or input-eligibility
boundary. Hopper does not expose complete body ranges or reliable reference
kinds here, so its broad caller inventory must not be treated as exhaustive or
as proof that every named caller is genuine.

## Still unknown

Function pointers, exact argument semantics and reentrant behavior must be
validated before installing a hook. Hopper's inferred signatures and
references are not source declarations; its public API does not report
complete function-body ranges or reference kinds. Indirect and unsymbolized
paths may be absent. Restored windows, Space transitions, input eligibility,
composition timing, and release semantics remain unproven. No runtime hook,
first-frame hold, or capture-based proof has been performed.

## Hook feasibility experiments

In an owned arm64e test process on the guest, the Odin self-test allocates
anonymous target and trampoline pages near its replacement, emits the observed
`PACIBSP` entry and a branch back, and forwards six integer arguments plus a
return value successfully. This does not exercise the private function itself.
An explicit transition of an anonymous executable page to writable and
executable returned `KERN_PROTECTION_FAILURE` (2). Therefore changing a live
target page to writable without a mechanism to keep all executing threads out
of that page is not safe.

A separate own-process arm64e probe loaded the guest's SkyLight, found the
candidate, and verified its `PACIBSP` entry. Its page successfully transitioned
from executable to writable with copy-on-write and back to executable, without
modifying any instruction. This is evidence only for a mapped page in that
probe process; it is not proof that WindowServer's sandbox permits the same
operations, nor that a concurrent patch is safe.

The reusable Odin installer now applies the branch through a writable alias and
checks the expected entry word before writing. The owned-process self-test uses
that exact installer and passes, including rejecting a second installation.
Alias ownership is now explicit in `Hook_State`. On the guest, the single-threaded
test passed 100 install/restore/release cycles using the correctly typed raw Mach
deallocator. It also passed a simulated conflicting-instruction test and an
injected deallocation failure/retry test: unknown bytes were not overwritten,
failed cleanup retained ownership, and reinstallation was blocked until release.
The subsequent owned-process stress test starts four pthread callers and installs
the entry branch while they are calling the anonymous target. Five consecutive
guest runs passed four million calls each (20 million total), observing both
original and hooked results, no unexpected results, and matching replacement
counts. All callers joined before restoration/release; the restored target was
then called again successfully. This is empirical evidence for that fixture,
not proof for shared-cache mappings, arbitrary code writers, or WindowServer.
Teardown requires externally established quiescence; no WindowServer live-thread
barrier has been implemented or proven. No WindowServer code has been patched.
