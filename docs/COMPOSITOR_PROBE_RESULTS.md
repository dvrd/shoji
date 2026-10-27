# Native clipping experiment: macOS 15.6 / 24G84

Run on 2026-10-25 from the user's Terminal. Original evidence directory: `/var/folders/dr/rhcpqcds1wqd3824tvjn0f940000gn/T/shoji-compositor-9442920632`. [Raw observations](evidence/compositor-24G84/observations.jsonl), [OS](evidence/compositor-24G84/os.txt), [architecture](evidence/compositor-24G84/architecture.txt), and [SIP configuration](evidence/compositor-24G84/sip.txt) are preserved in the repository so cleanup of temporary files does not erase the result.

## Result

**Owner-issued rectangular clipping works in this fixture. The same clipping setter called by the separate ordinary controller did not change the foreign window.** This is a result for the tested API, calling context, fixture and OS build, not a proof that every possible external clipping mechanism fails.

| Observation | Owner control | Foreign-controller attempt |
|---|---|---|
| Calling process | Fixture PID 99671, connection 1022951 | Controller PID 99663, connection 9817187 |
| Target window / owner | Window 152849, connection 1022951 | Same window and owner, checked before mutation |
| Setter result | 0 | 0 |
| Clip-region readback | Width 260, height 328 | Width 520, height 328 throughout all ten sampled observations |
| Left / right sampled hit | Target 152849 / background 152848 | Target 152849 / target 152849 |
| Actual received clicks, target / background | 2 / 2 | 1 / 0 |
| Final rectangular-baseline readback | Restored to 520 × 328 | Remained at 520 × 328 |

The owner control establishes the local rectangular coordinate hypothesis and sampled input clipping for this window. Background clicks are app-delivered mouse events, not just point queries. Foreign click counts alone are insufficient to prove routing at every point; the unchanged region and repeated point queries independently support the negative result. Visual boundary quality, shadow behavior and eventual fixture disappearance were not explicitly confirmed by the user and remain separate acceptance items.

The setter's zero return therefore cannot be used as a success assertion. This agrees with the [read-only ABI investigation](COMPOSITOR_PROBE_ABI.md): the client stub returns zero even when its window lookup finds nothing. An ownership/connection restriction is consistent with the observed behavior, but the run did not trace the internal denial path or establish which authorization check was responsible.

The host has custom SIP settings, with debugging and filesystem restrictions disabled. This result neither certifies SIP-enabled clipping nor proves that disabling additional protections would make the ordinary-controller path work. No Dock connection, injection or security-setting change was used by the experiment.

## What this changes for Shoji

The straightforward approach of moving another application's native surface and clipping it from Shoji's own connection is **not a verified presentation backend**. Do not build exact Niri viewport behavior on this setter or infer that using an owner's connection number grants ownership.

Scrolling-column layout remains viable through ordinary window management, with the known edge-placement/display constraints. A practical next development step is the pure column/viewport model and an opt-in AX presentation mode with documented limitations. Keep its logical coordinates independent of physical parking positions.

Further compositor research should be bounded and separately justified: another native clipping/transaction mechanism with a validated ABI and independent observation, or an explicitly privileged addition experiment. The existing addition's other effects do not prove it can clip windows. Capture-based previews remain an overview/transition option, not proof of interactive native-surface composition.

Transform/input alignment, complete hiding, dialog behavior, multiple displays and fully SIP-enabled operation remain untested. Do not report compositor parity or repeat the unchanged foreign clipping call as though more retries establish authority.
