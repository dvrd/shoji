# Existing-window resize presentation polish

Implemented 2026-10-27 on macOS 15.6 (24G84), arm64. This extends [content blending](RESIZE_CONTENT_FADE.md) toward the motion contract in the independent Niri reference. It does not establish compositor parity or perfect perceptual smoothness.

## Changes

- Scroll geometry publishes explicit spring progress alongside its size and velocity. Content opacity no longer depends on dividing observed dimensions by the requested resize distance. Retained velocity can carry geometry through its target early; that must not complete the content blend early.
- Live BSP jobs publish their configured easing progress before applying the corresponding native frame. The cover sees that same sample instead of the previous frame's geometry.
- BSP jobs, Scroll motion and resize covers consume the same display pulse and fixed predicted sample time. Their nested native frame batches stay within one presentation boundary. This coordinates Shoji's updates; it is not a client repaint fence.
- Frame application prepares/queues cover state. One cover presentation follows geometry per pulse. The previous path presented once before AX geometry and again afterward.
- Ordinary resize setup does not sample the application's background pixels. That readback is deferred until the prolonged manual-drag fallback needs it. The image is retained and drawn once; normal frames change its WindowServer transform and opacity.
- Interruptions preserve current visible opacity, then blend the remaining amount using the new geometry clock. There is no synchronous recapture on a retarget. Small resize policy, live native input, disable/failure cleanup and bounded cover lifetime remain.

`scroll_frame_pacing` retains its existing configuration name and now gates the shared scheduler for existing-window BSP motion too. No gesture or layout setting was changed as a new default.

## Why retargets do not recapture

Niri can preserve a current composite using compositor-owned render textures. Experimental Shoji paths reconstructed the old/live image using a CPU bitmap, then a temporary WindowServer surface, then the existing backing surface. Native pixel fixtures verified the latter two blends and repeated-interruption continuity. However, synchronous client capture still introduced visible stalls in live trials. The final path deliberately preserves opacity without another capture; the experimental code is excluded from production.

This is a remaining fidelity difference: immediately after a retarget, the original retained image has the same influence as before the command. Shoji does not replace it with Niri's exact compositor snapshot of the prior old/live mix. Removing that difference without blocking would require a fresh, asynchronously supplied client texture or a proven equivalent backend capability. Geometry, opacity and input remain live meanwhile.

## Validation

The full deterministic suite passes **262 tests** with warnings as errors. Two regressions were reproduced before the fix: retained size velocity advanced content opacity ahead of the animation clock, and one geometry sample produced two cover updates. Integration checks also exercise an existing BSP job, suppress motion without a display pulse, verify geometry and content are inside one balanced presentation batch, reverse direction continuously, and finish without a trailing fade.

The [native owned-window check](evidence/resize-polish-24G84/native.json) verifies:

- halfway geometry progress produces cover opacity 0.5;
- two immediate retargets keep that opacity at 0.5;
- the retained snapshot is reused and no final-content screenshot is frozen;
- the normal path skips background pixel readback;
- the real window keeps opacity 1, point queries route to it, and surfaces are cleaned up at completion.

The same standalone check also runs the production display clock, live BSP job sampler, native AppKit geometry writes, content cover renderer and nested presentation batch together. It passed **51 display-paced native updates**, including three retargets, using **one retained image**, with balanced batches and complete cleanup. These are execution checks on an owned window, not displayed-FPS measurements or proof of foreign-client repaint synchronization.

The signed candidate is `bin/shoji-resize-polish-smooth`. Raw tests, native results and investigation traces are under `bin/resize-polish-20261027/`. The pre-polish binary is preserved there as `shoji-before-resize-polish`.

Earlier live trials exercised the existing Chrome/Ghostty windows with normal resizes and rapid width reversals. Their layouts and active Space were restored. These traces are not a controlled before/after performance comparison: active applications and concurrent desktop actions differed, and another task replaced the installed binary during validation. A trace with no cover events was rejected as evidence for this candidate.

After the user paused that task, the latest shared source was rebuilt, tested, signed with the existing identity and installed. The running executable's SHA-256 matched the validated candidate. A fresh Chrome trial produced **165 model samples, 109 native frame calls, five complete covers and zero native errors**. The original BSP layout and full work-area frame (1720 × 1071) were restored; trace capture was cleared and no covers remained. WindowServer cover updates had median **0.285ms**, p95 **1.715ms** and maximum **45.035ms**; initial cover preparation had median **34.931ms** and maximum **41.210ms**. [Final timing summary](evidence/resize-polish-24G84/timing.json).

The large outliers and remaining initial-capture cost must not be hidden by the low median. No displayed-FPS, input-to-photon latency or universal speedup claim follows from this trial. Dock was not restarted. The state before the final validated installation is backed up at `bin/resize-polish-20261027/shoji-before-final-validation`.

## Remaining limits

Initial client capture and native AX frame calls can still exceed one display interval. macOS owns foreign app rendering, buffer readiness, clipping and composition. The active Space selects one display clock; independent simultaneous motion on monitors with different refresh rates is unverified. Niri-equivalent retarget snapshots and client-frame synchronization are not established. Visual acceptance still requires real use with fast reversals, multiple windows, slow app redraws and manual edge resizing.
