# Niri layout behavior reference for Shoji

Verified 2026-10-25. This is a source map and acceptance reference, not a claim that Shoji implements the behavior yet.

## Pin and provenance

GitHub's latest official release resolves to **v26.04**, released April 25, 2026. Its commit is **`8ed0da44d974c32c6877d2f4630c314da0717ecb`**; Cargo's workspace version is `26.4.0`. All links below pin that commit rather than `main`. [Release](https://github.com/niri-wm/niri/releases/tag/v26.04), [commit](https://github.com/niri-wm/niri/commit/8ed0da44d974c32c6877d2f4630c314da0717ecb).

The exact Cargo SPDX field is **`license = "GPL-3.0-or-later"`**, inherited by the `niri` package. The repository includes the GPL version 3 license text. [Cargo.toml:8–12,36–41](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/Cargo.toml#L8), [LICENSE](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/LICENSE).

**Project decision:** implement matching behavior independently and retain Shoji's MIT license. This document describes behavior and numerical acceptance cases; it does not authorize copying or translating upstream implementation or test code. Shoji's window-identity/screen-position anchor representation and tests were authored independently. This is not a clean-room development claim: upstream source was studied.

## Insertion and camera: first port these together

The source file in the following table is [`src/layout/scrolling.rs`](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/src/layout/scrolling.rs). Line numbers refer to the original file, including blank lines.

| Function / lines | Exact behavior relevant to the port |
| --- | --- |
| `add_column`, 963–1024 | With no explicit insertion index: first column at zero, otherwise immediately **right of active**, not at the strip's end. Existing widths stay unchanged. Inserting before the active column increments its index, preserving its identity. On activated insertion immediately right of active, save the old stationary offset for close-and-return. First insertion resets stale viewport state and chooses its initial offset without an animation. |
| `add_tile_right_of`, 945–960 | Explicit parent/neighbor placement finds that window's column and inserts at its index plus one. |
| `column_xs`, 2304–2317 | Logical X starts at zero and advances by actual cached column width plus one gap. There is no redistribution to fit the display and no special transition to thirds when a third window opens. |
| `view_pos` / `target_view_pos`, 2294–2299 | Absolute camera X is `column_x(active) + current_or_target_view_offset`. The stored offset is **relative to the active column**. A column's settled screen X is logical column X minus camera X. |
| `activate_column_with_anim_config`, 776–798; `animate_view_offset_with_config`, 688–731 | Before changing the active index, rebase the current offset by `old_active_x - new_active_x`, preserving the current absolute camera. Then animate to the new relative target. Changing active column clears the temporary close-return offset and fullscreen restore state. Do not directly replace camera X with the target before establishing the animation's starting point. |
| `compute_new_view_offset`, 5457–5488 | Oversized columns left-align. Otherwise padding is `clamp((view_width-column_width)/2, 0, gap)`. Fully visible columns preserve camera position. Off-screen columns choose whichever padded edge requires less motion; equal distances choose left alignment. |
| `compute_new_view_offset_fit`, 545–569 | Pass the current **target** absolute camera and working-area origin into that helper. Normal tiles use working area plus gap; maximized uses parent area and zero gap; fullscreen offset is zero. |
| `compute_new_view_offset_for_column`, 620–678 | `Never`: fit with minimal pan. `Always`: center unless too wide. `OnOverflow`: compare the target with its adjacent column in the direction of the previous focus, not necessarily the previously focused distant column; center only if that pair plus outside gaps cannot fit. |
| `remove_column_by_idx`, 1162–1245 | Removal left of focus decrements active index while leaving its relative offset intact, anchoring the focused window visually. Removing a newly opened active neighbor can activate the previous column and restore its saved offset, then ensure visibility if it resized. Otherwise retain the current index if valid, or clamp to the last. |

### Three-column oracle

These numbers are **derived from the pinned source**, not output from running Niri on this Mac. Assumptions: width 1280, working-area origin zero, scale 1, gap 16, borders off, no tab indicator, no minimum-size constraints, normal columns, default half-width, `center-focused-column = Never`, animations settled.

Column width is `(1280 - 16) × 0.5 - 16 = 616`; logical pitch is 632.

| Action | Logical column order | Active | Absolute camera X | Settled screen X in column order |
| --- | --- | --- | --- | --- |
| Open A | A | A | -16 | 16 |
| Open B | A, B | B | -16 | 16, 648 |
| Open C | A, B, C | C | 616 | -616, 16, 648 |
| Close C immediately | A, B | B | -16 | 16, 648 |

Additional independent fixtures, starting from the states explicitly named:

| Initial state and action | Expected result after settling |
| --- | --- |
| A,B,C with C active; open D | Order A,B,C,D; D active; camera 1248; screen X `[-1248,-616,16,648]`; widths remain 616. |
| A,B,C with C active; focus B; open D | Order **A,B,D,C**; D active; camera remains 616; screen X `[-616,16,648,1280]`. |
| A,B,C with C active; focus B; focus C; close C | The intervening focus cleared close-return state. B becomes active at screen X=16, camera stays 616; A is at -616. This intentionally differs from closing C immediately. |
| Fixed client widths A=400,B=600,C=500; open successively | No resizing of existing columns. Logical X `[0,416,1032]`; final camera 268; screen X `[-268,148,764]`. |
| Previous heterogeneous state; A acknowledges resize 400→700 while C stays focused | Logical X becomes `[0,716,1332]`; camera becomes 568; B remains at screen X=148 and C at 764. A now starts at -568. This checks active-relative anchoring rather than a globally fixed absolute camera. |
| Heterogeneous A=400,B=600,C=500 state; request C width 700 and acknowledge it | Camera pans to 468 to expose C's new right edge with 16-pixel margin; screen X `[-468,-52,564]`. |

These are deterministic expected values derived from the implementation, **not black-box observations**. They should become runtime oracles against the pinned Niri release when a Linux test environment is available. Minimum constraints, window rules, centering modes, animations and client refusal can legitimately change these results.

Widths remain 616 throughout. If A is focused in `A,B,C` and D opens, the order becomes **`A,D,B,C`**. Appending D after C would diverge from Niri. A single column initially remains half-width at X=16; automatically maximizing it also diverges from these defaults.

## Sizing, rows and tabs

Defaults live in [`niri-config/src/layout.rs:29–55`](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/niri-config/src/layout.rs#L29): half-width columns; width and height presets one-third, half, two-thirds; `Never` centering; normal display; gap 16; single-column centering disabled. Workspace rules can override or clear the width; floating windows without an explicit width use application sizing. [`Workspace::resolve_default_width`, workspace.rs:790–800](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/src/layout/workspace.rs#L790).

Continue in the pinned `scrolling.rs`:

| Function / lines | Port requirement |
| --- | --- |
| `Column::resolve_column_width`, 4401–4411; `resolve_preset_size`, 5554–5565 | Proportional tile width subtracts gap and tab-indicator extra geometry. Fixed presets refer to client/window size, so border conversion matters. Keep requested width distinct from actual constrained width. |
| `Column::update_tile_sizes_with_transaction`, 4418–4710 | Width clamps against the largest member minimum and smallest nonzero maximum; conflicting maxima yield to the minimum. Fixed row heights consume space first. Automatic rows divide remaining height by weights, iteratively satisfying minimum heights and rounding client sizes. Auto allocation deliberately does not solve arbitrary maximum heights; exact fixed-size constraints are handled separately. Port actual behavior rather than replacing it with equal splitting. |
| `consume_into_column`, 1965–1992 | Move the **first** tile of the next column to the **end** of the active column, keeping active focus. No next column means no operation. |
| `expel_from_column`, 1994–2030 | Move the **last** tile of a multi-tile active column into a new column immediately right; preserve its width/full-width state and leave focus in the source. A one-tile column is unchanged. |
| `consume_or_expel_window_left/right`, 1765–1963 | Different actions: act on specified or active tile. A single-tile source consumes into the adjacent column; a multi-tile source expels the selected tile into a new adjacent column. Do not alias these commands to legacy consume/expel above. |
| `remove_tile_by_idx`, 1052–1151 | Preserve active tile identity when an earlier row disappears. Reset a sole remaining auto row's weight to one. Recompute sizing and animate shifts on the appropriate side of the anchored active column. |
| `Column::set_column_display`, 5111–5167; sizing 4551–4579 | Tabs retain column membership and active index. Tab heights share the fixed target or full available height, with constraints; inactive tiles fade out. Switching back restores vertical tiles. Only the active tab participates in size transactions. |
| `Column::toggle_width`, 4796–4844; `set_column_width`, 4859–4911 | Cycle known preset index, otherwise choose next larger/smaller actual size with a one-pixel tolerance. Explicit resizing clears preset index, full-width and maximized flags. Fixed width requests convert for the selected client, rather than treating decorations as client pixels. |

## Existing upstream checks worth translating

These are inspected source tests; they were **not executed here**. Some use property/invariant checks rather than explicit pixel assertions, so copy their intended assertions carefully.

| Pinned source | Useful oracle |
| --- | --- |
| [`tests.rs:3317–3338`](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/src/layout/tests.rs#L3317), `removing_window_above_preserves_focused_window` | Three windows consumed into one column, focus second row, close first: focus stays on window 1. |
| [`tests.rs:3342–3385`](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/src/layout/tests.rs#L3342), `preset_column_width_fixed_correct_with_border` | Fixed 500 client preset remains 500 after applying the preset with borders. Merely adding 5-pixel borders temporarily reduces client width to 490. |
| [`tests.rs:3389–3412`](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/src/layout/tests.rs#L3389), `preset_column_width_reset_after_set_width` | Presets 500/1000, select preset, adjust -10, cycle: expected client width 500. |
| [`tests.rs:2441–2531`](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/src/layout/tests.rs#L2441) | Fixed/auto row height transitions, sole auto weight reset, and fixed-height limits relative to other rows. |
| [`tests/animations.rs:1012–1098`](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/src/layout/tests/animations.rs#L1012), `width_resize_and_cancel_of_column_to_the_left` | With focused right window at X=100, left client grows 100→105 during animation and shifts X=0→-5, leaving right window anchored. Cancel preserves left X=-5 initially, then returns to zero. Inline snapshots provide exact values and times. |

Upstream tests use fake clients, explicit communication steps, a deterministic clock and settling of animations. An Odin port should distinguish requested, acknowledged and animated geometry; asserting only the final array order misses anchoring and resize races. The three-column oracle above should be added as an explicit settled-layout test alongside those upstream cases.

For a basic row oracle, use working height 800, gap 16, borders off, no height constraints and all automatic row weights equal to one. Two rows request heights 376/376 at Y=16/408. Three rows request **245/246/245** at Y=16/277/539: upstream distributes and rounds the remaining height sequentially. Giving every row `round(736/3)` would lose a pixel. Legacy consume brings the next column's first tile into the active column's last row; legacy expel returns its last row to the right without moving focus. Include those membership and focus assertions in addition to geometry.

## Behavior parity and rendering parity are separate

These logical and acknowledged-geometry oracles can be implemented and tested independently of macOS native Spaces, clipping, capture or animation. They do not establish that moving native macOS windows can reproduce Niri's independent monitor viewports, invisible/input-inaccessible off-screen windows, live overview, or frame-synchronized surface transforms. Preserve a separate backend acceptance matrix for those capabilities. Choosing independently implemented behavioral compatibility versus translating GPL source is also a separate project licensing decision; no upstream implementation code was copied into this repository by this investigation.

## Appendix: additional independent behavior fixtures

This appendix describes observable state transitions for an independent implementation. It contains no translated upstream implementation code. Expected values are derived from the pinned reference; they have not been checked by running the Linux compositor. Numeric fixtures assume compliant clients, settled geometry, no borders, no tab-indicator space or other decoration, no struts, scale one and no constraints unless stated. Parentheses group one column's top-to-bottom rows; `*` identifies the globally focused window.

### Legacy versus directional consume and expel

| Starting columns | Action | Result and focus |
| --- | --- | --- |
| `(A*) ∥ (B,C) ∥ (D)` | Legacy consume | `(A*,B) ∥ (C) ∥ (D)`. Move the next column's first row to the active column's end. |
| `(A,B*,C) ∥ (D)` | Legacy expel | `(A,B*) ∥ (C) ∥ (D)`. Expel the last row, regardless of which row is active. |
| `(A,B,C*) ∥ (D)` | Legacy expel | `(A,B*) ∥ (C) ∥ (D)`. If the last row was active, focus falls to its preceding source row. It does **not** follow the expelled window. |
| `(A*) ∥ (B,C)` | Directional right, no explicit target | `(B,C,A*)`. The active single-row column consumes into its right neighbor's **end**. |
| `(A,B) ∥ (C*)` | Directional left, no explicit target | `(A,B,C*)`. Active moved window retains focus. |
| `(A,B*,C) ∥ (D)` | Directional right, no explicit target | `(A,C) ∥ (B*) ∥ (D)`. Multi-row source expels its active row into a new adjacent column. |
| `(A,B*,C) ∥ (D)` | Directional left, no explicit target | `(B*) ∥ (A,C) ∥ (D)`. Left expel inserts before the original source column. |
| `(A*,B,C) ∥ (D)` | Directional right, explicit target B | `(A*,C) ∥ (B) ∥ (D)`. Moving an inactive window does not steal global focus. |
| `(A*) ∥ (B)` | Directional left targeting A | Unchanged: single-row source has no left neighbor. |
| `(A) ∥ (B*)` | Directional right targeting B | Unchanged: single-row source has no right neighbor. |

The edge restriction applies to consuming from a single-row source. A multi-row first/last column can still expel outward into a new column. Directional operations also preserve the moved window's preferred width/full-width state when making a new column. Sources: [`consume_or_expel_window_left/right`, lines 1765–1963](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/src/layout/scrolling.rs#L1765), [`consume_into_column` / `expel_from_column`, 1965–2030](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/src/layout/scrolling.rs#L1965), [`remove_tile_by_idx`, 1121–1133](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/src/layout/scrolling.rs#L1121).

### Centering modes

For width 1280, gap 16 and three half-width columns (616 each), their logical X values are 0/632/1264.

- `Always`: the active column's settled screen X is 332. Successively opening A/B/C yields cameras -332/300/932. Oversized columns are left-aligned rather than centered outside both edges.
- `Never`: use the minimal-pan values in the earlier three-column oracle.
- `OnOverflow`: the default pair of half-width columns fits exactly with three gaps, so its behavior here matches `Never`. With fixed widths 700 and 700 instead, the pair plus gaps needs 1448 pixels and cannot fit: switching A→B centers B at X=290 (camera 426). Initial A alone uses ordinary fit unless single-column centering was explicitly enabled.
- A distant focus jump under `OnOverflow` compares the target to its immediate neighbor on the arrival side. Example widths A=900, B=400, C=400 at logical X=0/916/1332: focus A→C considers B+C, which fits (848 including gaps). It therefore fits C with minimum pan, ending camera 468 and C screen X=864; considering A+C instead would incorrectly center C at 440.

Source: [`compute_new_view_offset_for_column`, 620–678; centered helper 571–594](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/src/layout/scrolling.rs#L571).

### Width presets and full-width state

Use fixed client presets 400/600/800, gap zero, no constraints. For a width set explicitly (no remembered preset index), forward selection requires a candidate more than one pixel larger; backward selection requires one more than one pixel smaller. Thus forward from 398→400, 399→600, 400→600, 800→400; backward from 602→600, 601→400, 600→400, 400→800. The boundaries are strict. These checks use resolved client or tile geometry according to preset kind, not indiscriminately one width field.

After selecting a preset, subsequent toggles cycle the remembered preset order modulo its length, even if client constraints changed the resulting size. Explicit width adjustment clears that remembered selection. Full-width or maximized state makes selection behave as uncached rather than advancing a stale preset index. Source: [`toggle_width`, 4796–4844](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/src/layout/scrolling.rs#L4796).

For width 1280/gap16, an ordinary full-width column requests 1248 pixels and retains gaps. Toggling full width off restores its stored preferred width; it does not replace that preference with 100%. Maximizing to edges is a separate window state using available parent area, and fullscreen is a separate client state covering the output. An ordinary full-width column can contain multiple vertical rows. Source: [`toggle_full_width`, 4847–4857](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/src/layout/scrolling.rs#L4847), [`sizing`, 4418–4437](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/src/layout/scrolling.rs#L4418).

### Fixed and weighted row allocation

For height 800 and gap16, a two-row column has 752 pixels for client heights; three rows have 736. Expected allocations:

| State | Requested client heights |
| --- | --- |
| Two auto rows, weights 1:3 | 188/564 |
| Same, first row minimum 300 | 300/452 |
| Three equal auto rows | 245/246/245, including sequential rounding |
| Three rows, first fixed200 and remaining weights1:1 | 200/268/268 |
| Previous state acknowledged; set second row fixed100 | First row becomes auto, preserving relative apparent weights; resulting heights 272/100/364. There is only one user-selected non-auto row at a time. |

Setting a different automatic row's height converts existing apparent row heights into proportional auto weights before setting the new row fixed. Repeatedly resizing the same already-fixed row preserves other auto weights. Resetting an ordinary row sets that row to auto weight one; resetting height in tabbed mode resets every member to auto weight one. Exact fixed-size client constraints are honored; arbitrary maximum heights on automatic rows are deliberately not solved as a general redistribution constraint. Sources: [`set_window_height` / `reset_window_height`, 4914–5006](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/src/layout/scrolling.rs#L4914), [`convert_heights_to_auto`, 5070–5083](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/src/layout/scrolling.rs#L5070), [`allocation`, 4582–4708](https://github.com/niri-wm/niri/blob/8ed0da44d974c32c6877d2f4630c314da0717ecb/src/layout/scrolling.rs#L4582).
