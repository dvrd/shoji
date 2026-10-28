# WindowServer ordering: macOS 27.0.1 / 26A434

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
