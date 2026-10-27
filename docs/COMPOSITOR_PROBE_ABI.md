# Clipping probe ABI evidence

Investigated 2026-10-25 against the running macOS 15.6 (24G84), arm64 SkyLight image. This note supports the disposable-window experiment proposed in [EXTERNAL_COMPOSITOR.md](../EXTERNAL_COMPOSITOR.md). It establishes client calling conventions, not cross-process permission or clipping behavior.

## Target-specific findings

A read-only program opened SkyLight with `dlopen`, located symbols with `dlsym`, and copied their executable bytes into temporary assembly for disassembly. It invoked no window or region functions. The source and output are `/tmp/shoji-clip-abi.c` and `/tmp/shoji-clip-abi-disasm.txt`; these temporary files are not durable repository evidence.

The supported diagnostic declarations, expressed using Odin types, are:

```odin
// All procedures use the C calling convention.
SLSSetWindowClipShape: proc "c" (connection: i32, window: u32, region: rawptr) -> i32
SLSCopyWindowClipShape: proc "c" (connection: i32, window: u32, output: ^rawptr) -> i32
CGSNewRegionWithRect: proc "c" (rectangle: ^CGRect, output: ^rawptr) -> i32
CGSNewEmptyRegion: proc "c" (output: ^rawptr) -> i32
CGSReleaseRegion: proc "c" (region: rawptr) -> i32
CGSGetRegionBounds: proc "c" (region: rawptr, output: ^CGRect) -> i32
```

`CGRect` contains four `f64` values on this target. Region handles are opaque pointers, not window IDs. The region functions above are exported under the **CGS** prefix through the SkyLight handle; their corresponding SLS spellings were not found.

The setter entry saves `x2` as the region and `x1` as the window, while passing incoming `x0` through a connection helper. Its normal path finishes with `mov w0, #0`. Thus the setter requires **three arguments** on this target. Its zero result cannot establish that WindowServer applied the clip: the implementation also returns zero when its window lookup finds nothing. Independent readback and observation are mandatory.

The copy function saves `x0`, `x1` and `x2`, serializes the window ID into a WindowServer request, constructs a region from the reply bytes, and stores it through the output pointer. It returns zero only when the constructed output is non-null. Failure paths clear the output and return 1000. In particular, null reply data or an unusable decoded region cannot be interpreted as an ordinary successful “no clipping” baseline.

The allocator reads four doubles through the rectangle pointer and writes an opaque handle through its second argument. The release function accepts the handle and returns zero. These observations agree with the historical region lifecycle declarations. Non-null copy results should be released with `CGSReleaseRegion`, after restoration has finished. [Region declarations](https://github.com/NUIKit/CGSInternal/blob/master/CGSRegion.h)

## Why the old two-argument declaration is unsuitable

NUIKit's historical window header declares the clip setter with only a window and region. That declaration conflicts with the observed 15.6 implementation and must not be used here. PoomSmart's independently maintained analysis header declares the CGS setter with connection, window and region, which agrees with the observed register use; this remains reverse-engineered evidence rather than an Apple API guarantee. [Historical window declarations](https://github.com/NUIKit/CGSInternal/blob/master/CGSWindow.h), [Analysis declarations](https://github.com/PoomSmart/IDAObjcTypes/blob/master/CoreGraphics/CoreGraphics.h)

## Restoration and coordinate constraints

For exact restoration, require a successful non-null baseline copy, retain that full opaque region, set it back after each operation, and compare the copied result afterward. Comparing only region bounds cannot detect holes or rounded corners; use region equality where available, plus rendered observations. A fabricated full-frame rectangle is not necessarily equivalent to the original clip.

The meaning and validity of passing **nil to the setter remain unproven**. Nil, an empty allocated region and a full-frame allocated region must not be treated as interchangeable reset operations. If a disposable fixture has no readable baseline, terminate that fixture as the final recovery mechanism and report exact restoration as unavailable. Do not apply this experiment to existing user windows.

Window-local versus global coordinates, vertical-axis direction, titlebar inclusion, backing-scale conversion, shadow clipping and input clipping remain runtime questions. The client setter merely serializes the supplied region; its signature does not establish any of these semantics. Start with a known fixture geometry and a central partial rectangle, record the actual visible boundary, then test several screen points on both sides. Treat local coordinates as an experimental hypothesis until the positive control establishes them.

## Hit-testing

The existing upstream window manager declares `SLSFindWindowAndOwner` with eight arguments: connection (`i32`), filter window (`i32`), traversal selector (`i32`), options (`i32`), screen point (`^CGPoint`), output local point (`^CGPoint`), output window (`^u32`), and output owner connection (`^i32`), returning an `i32` status. Its implementation uses a zero filter, selector 1 and options 0 for ordinary point lookup. The local 15.6 entry saves registers `x0` through `x7`, agreeing with the argument count. [Upstream declarations](https://github.com/asmvik/yabai/blob/master/src/misc/extern.h), [Upstream uses](https://github.com/asmvik/yabai/blob/master/src/window_manager.c)

This query can supplement real fixture click counters. It cannot replace actual event delivery checks: rendering, WindowServer hit-testing and app-delivered input must be reported separately. None of those behavioral checks were performed during this ABI investigation.
