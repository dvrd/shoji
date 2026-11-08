package layout

import "core:math"
import "core:strconv"
import "core:strings"
import "core:fmt"

// Scroll layout and viewport
// ------------------------------------------------------------------------

// One camera trajectory drives the strip; column geometry stays in target
// coordinates and presentation translates every row by the same displacement.
Scroll_Motion :: struct {
	initialized, active: bool,
	position, target, velocity: f64,
	from, initial_velocity, began: f64,
	anchor: u32,
}

// The tree supplies column membership and ordering. Split ratios are unused:
// widths and viewport position are independent of BSP partition geometry.
Scroll_State :: struct {
	motion: Scroll_Motion,
	dragging, fill_after_removal: bool,
	geometry_enabled, geometry_active: bool,
	geometry_began: f64,
	viewport: Rect,
	offset, content_width: f64,
	focused: u32,
	reveal: bool,
	centered: bool,
	// Anchor by window identity, so resizing or removing earlier columns does
	// not move the active column on screen. offset remains the queryable camera.
	anchor: u32,
	anchor_x: f64,
	initialized: bool,
	opened, return_to: u32,
	return_x: f64,
}

scroll_gap :: proc(v: ^View) -> f64 { return v.gap_enabled ? v.gap : 0 }

tab_indicator_gutter :: proc(v: ^View, n: ^Node) -> f64 {
	return n != nil && n.column_tabbed && n.count > 1 && n.zoom == nil ? v.tab_indicator_width + 5 : 0
}

scroll_update :: proc(v: ^View) {
	r := v.scroll.viewport
	gap := scroll_gap(v)
	width := max(1, r.w)
	if !v.scroll.initialized {
		v.scroll.offset = -gap
		v.scroll.initialized = true
	}
	total: f64
	for n := first(v.root); n != nil; n = next(n) {
		if n.count == 0 {
			continue
		}
		// Existing drag/warp callers may assign a pixel width directly.
		if n.column_width > 0 && n.column_width != n.column_resolved {
			n.column_size = {.Fixed, n.column_width}
			n.column_preset = nil
		}
		size :=
			n.column_size.kind == .Default \
				? v.scroll_options.default_width \
				: n.column_size
		requested :=
			n.column_full \
				? max(1, width - 2 * gap) \
				: scroll_size_value(v, size)
		n.column_width = clamp(
			requested,
			max(1, n.column_min),
			max(
				max(1, n.column_min),
				n.column_max > 0 ? n.column_max : 100000,
			),
		)
		if find(v.root, v.scroll.anchor) == n &&
		   n.column_resolved != n.column_width {
			v.scroll.reveal = true
		}
		n.column_resolved = n.column_width
		if n.column_observed > 0 {n.column_width, n.column_resolved = n.column_observed, n.column_observed}
		total += n.column_width + gap
	}
	if v.scroll.fill_after_removal {
		// Fill only space left by a removed column; retain each requested size
		// so adding a new column restores the user's original proportions.
		remaining := max(0, width - gap - total)
		for remaining > 0.01 {
			eligible := 0
			for n := first(v.root); n != nil; n = next(n) {
				if n.count > 0 && (n.column_max <= 0 || n.column_width < n.column_max - 0.01) { eligible += 1 }
			}
			if eligible == 0 { break }
			share := remaining / f64(eligible)
			added: f64
			for n := first(v.root); n != nil; n = next(n) {
				if n.count == 0 { continue }
				room := n.column_max > 0 ? max(0, n.column_max - n.column_width) : share
				increase := min(share, room)
				n.column_width += increase; n.column_resolved = n.column_width
				added += increase
			}
			if added <= 0.01 { break }
			total += added; remaining -= added
		}
	}
	v.scroll.content_width = max(0, total - gap)
	anchor := find(v.root, v.scroll.anchor)
	logical_x: f64
	for n := first(v.root); n != nil; n = next(n) {
		if n.count == 0 {
			continue
		}
		if n == anchor {
			offset := logical_x - v.scroll.anchor_x
			if !v.scroll.geometry_enabled && v.scroll.motion.initialized && v.scroll.motion.anchor == v.scroll.anchor {
				shift := offset - v.scroll.offset
				v.scroll.motion.position += shift; v.scroll.motion.from += shift; v.scroll.motion.target += shift
			}
			v.scroll.offset = offset; break
		}
		logical_x += n.column_width + gap
	}
	if v.scroll.fill_after_removal && !v.scroll.dragging && !v.scroll.centered {
		v.scroll.offset = clamp(v.scroll.offset, -gap, max(-gap, v.scroll.content_width - width + gap))
	}
	x := r.x - v.scroll.offset
	for n := first(v.root); n != nil; n = next(n) {
		if n.count == 0 {
			continue
		}
		n.frame = {x, r.y + gap, n.column_width, max(1, r.h - 2 * gap)}
		x += n.column_width + gap
	}
}

scroll_anchor :: proc(v: ^View, window: u32) {
	if n := find(v.root, window); n != nil {
		v.scroll.anchor = window
		v.scroll.anchor_x = n.frame.x - v.scroll.viewport.x
	}
}

scroll_pan :: proc(v: ^View, offset: f64) {
	gap := scroll_gap(v)
	v.scroll.anchor = 0
	v.scroll.opened, v.scroll.return_to = 0, 0
	v.scroll.offset = clamp(
		offset,
		-gap,
		max(-gap, v.scroll.content_width - v.scroll.viewport.w + gap),
	)
	scroll_update(v)
	scroll_anchor(v, v.scroll.focused)
}

scroll_before_add :: proc(v: ^View, id: u32) {
	v.scroll.opened = id
	v.scroll.return_to = v.scroll.focused
	if n := find(v.root, v.scroll.focused); n != nil {
		v.scroll.return_x = n.frame.x - v.scroll.viewport.x
	}
}

scroll_before_remove :: proc(v: ^View, id: u32) {
	n := find(v.root, id)
	if n == nil {
		return
	}
	if n.count > 1 {
		if v.scroll.anchor == id {
			for i in 0 ..< n.count {
				if n.windows[i] != id {
					v.scroll.anchor = n.windows[i]; break
				}
			}
		}
		return
	}
	v.scroll.fill_after_removal = true
	if v.scroll.opened == id &&
	   v.scroll.focused == id &&
	   find(v.root, v.scroll.return_to) != nil {
		v.scroll.anchor = v.scroll.return_to
		v.scroll.anchor_x = v.scroll.return_x
		v.scroll.focused = v.scroll.return_to
		v.scroll.reveal = true
	} else if find(v.root, v.scroll.anchor) == n {
		target := next(n)
		if target == nil {
			target = previous(n)
		}
		v.scroll.anchor = 0
		if target != nil {
			scroll_anchor(v, target.order[0])
		}
	}
	if v.scroll.opened == id || v.scroll.return_to == id {
		v.scroll.opened, v.scroll.return_to = 0, 0
	}
}

scroll_reveal :: proc(v: ^View, window: u32, center: bool = false) {
	center := center
	n := find(v.root, window)
	if n == nil {
		return
	}
	v.scroll.centered = center
	r := v.scroll.viewport
	if v.scroll_options.center == .Always ||
	   (v.scroll_options.center_single && first(v.root) == last(v.root)) {
		center = true
	}
	if v.scroll_options.center == .On_Overflow {
		old := find(v.root, v.scroll.focused)
		if old != nil && old != n {
			neighbor := old.frame.x < n.frame.x ? previous(n) : next(n)
			if neighbor != nil &&
			   neighbor.column_width + n.column_width + 3 * scroll_gap(v) >
				   r.w {
				center = true
			}
		}
	}
	center = center && n.frame.w < r.w
	padding := min(scroll_gap(v), max(0, (r.w - n.frame.w) * 0.5))
	if v.scroll.focused != window && v.scroll.opened != window {
		v.scroll.opened, v.scroll.return_to = 0, 0
	}
	v.scroll.anchor = 0
	if center {
		v.scroll.offset += n.frame.x + n.frame.w * 0.5 - (r.x + r.w * 0.5)
	} else if n.frame.w >= r.w {
		v.scroll.offset += n.frame.x - r.x
	} else if n.frame.x < r.x + padding {
		v.scroll.offset += n.frame.x - r.x - padding
	} else if n.frame.x + n.frame.w > r.x + r.w - padding {
		v.scroll.offset += n.frame.x + n.frame.w - r.x - r.w + padding
	}
	scroll_update(v)
	scroll_anchor(v, window)
}

scroll_window_frame :: proc(
	v: ^View,
	n: ^Node,
	window: u32,
	park: bool = true,
	camera: Maybe(f64) = nil,
) -> Rect {
	r := frame_for(n)
	if position, current := camera.?; current {r.x += v.scroll.offset - position}
	if n.zoom != nil {
		return v.scroll.viewport
	}
	// Retain a visible edge to avoid requesting entirely off-screen placement.
	// This is parking, not clipping: horizontal adjacent displays may show it.
	if park {
		r = scroll_park_frame(v, r)
	}
	if gutter := tab_indicator_gutter(v, n); gutter > 0 {
		if v.tab_indicator_top {
			gutter = min(gutter, max(0, r.h - 1))
			r.y += gutter; r.h -= gutter
		} else {
			gutter = min(gutter, max(0, r.w - 1))
			r.x += gutter; r.w -= gutter
		}
	}
	if n.count > 1 && !n.column_tabbed {
		gap := min(scroll_gap(v), max(0, r.h / f64(n.count)))
		for i in 0 ..< n.count {
			if n.windows[i] == window {
				for j in 0 ..< i { r.y += n.row_heights[j] + gap }
				r.h = max(1, n.row_heights[i])
				break
			}
		}
	}
	return r
}

scroll_park_frame :: proc(v: ^View, frame: Rect) -> Rect {
	r := frame
	sliver := min(32, v.scroll.viewport.w, r.w)
	r.x = clamp(r.x, v.scroll.viewport.x - r.w + sliver, v.scroll.viewport.x + v.scroll.viewport.w - sliver)
	return r
}

// Window-local intersection of a parked frame with the viewport. partial is
// false when the frame sits inside (half a pixel of slack). No overlap is an
// empty clip. A zero-size input is not a clip.
viewport_clip :: proc(frame, viewport: Rect) -> (x, y, w, h: i32, partial: bool) {
	if frame.w <= 0 || frame.h <= 0 || viewport.w <= 0 || viewport.h <= 0 {return}
	if frame.x >= viewport.x - 0.5 &&
	   frame.y >= viewport.y - 0.5 &&
	   frame.x + frame.w <= viewport.x + viewport.w + 0.5 &&
	   frame.y + frame.h <= viewport.y + viewport.h + 0.5 {
		return 0, 0, i32(math.round(frame.w)), i32(math.round(frame.h)), false
	}
	x0 := max(frame.x, viewport.x)
	y0 := max(frame.y, viewport.y)
	x1 := min(frame.x + frame.w, viewport.x + viewport.w)
	y1 := min(frame.y + frame.h, viewport.y + viewport.h)
	if x1 <= x0 || y1 <= y0 {return 0, 0, 0, 0, true}
	x = i32(math.round(x0 - frame.x))
	y = i32(math.round(y0 - frame.y))
	w = i32(math.round(x1 - x0))
	h = i32(math.round(y1 - y0))
	if w <= 0 || h <= 0 {return 0, 0, 0, 0, true}
	partial = true
	return
}

scroll_set_width :: proc(v: ^View, window: u32, operand: string) -> string {
	n := find(v.root, window)
	if n == nil {
		return "window is not in a scrolling column"
	}
	parts := strings.split(operand, ":", context.temp_allocator)
	if len(parts) != 2 {
		return "column-width expects abs:pixels, rel:pixels, or ratio:fraction"
	}
	value, ok := strconv.parse_f64(parts[1])
	if !ok || math.is_nan(value) || math.is_inf(value) {
		return "invalid column width"
	}
	v.scroll.fill_after_removal = false
	switch parts[0] {
	case "abs":
	case "rel":
		value += n.column_width
	case "ratio":
		size, valid := scroll_parse_size(operand)
		if !valid {
			return "invalid proportional column width"
		}
		n.column_size = size; n.column_preset = nil; n.column_full = false
		n.column_revision += 1
		v.scroll.reveal = true; return ""
	case:
		return "column-width expects abs, rel, or ratio"
	}
	if value <= 0 || value > 100000 {
		return "column width must be positive and at most 100000"
	}
	n.column_size = {.Fixed, value}
	n.column_revision += 1
	n.column_preset = nil
	n.column_full = false
	v.scroll.reveal = true
	return ""
}

// Column and row sizing
// ------------------------------------------------------------------------

Scroll_Size :: struct {
	kind: enum {
		Default,
		Fixed,
		Proportion,
	},
	value: f64,
}
Scroll_Options :: struct {
	center: enum {
		Never,
		Always,
		On_Overflow,
	},
	center_single: bool,
	default_tabbed: bool,
	warp_pointer: bool,
	default_width: Scroll_Size,
	presets: [16]Scroll_Size,
	preset_count: int,
	height_presets: [16]Scroll_Size,
	height_preset_count: int,
}
scroll_options_defaults :: proc() -> Scroll_Options {
	o := Scroll_Options {
		default_width = {.Proportion, 0.5},
		preset_count  = 3,
	}
	o.presets[0] = {.Proportion, 1.0 / 3}
	o.presets[1] = {.Proportion, 0.5}
	o.presets[2] = {.Proportion, 2.0 / 3}
	o.height_presets = o.presets
	o.height_preset_count = o.preset_count
	return o
}
scroll_size_value :: proc(v: ^View, size: Scroll_Size) -> f64 {
	if size.kind == .Proportion {
		return max(
			1,
			(v.scroll.viewport.w - scroll_gap(v)) * size.value - scroll_gap(v),
		)
	}
	return max(1, size.value)
}
scroll_parse_size :: proc(text: string) -> (Scroll_Size, bool) {
	p := strings.split(text, ":", context.temp_allocator)
	if len(p) != 2 {
		return {}, false
	}
	n, ok := strconv.parse_f64(p[1])
	if !ok || math.is_nan(n) || math.is_inf(n) || n <= 0 || n > 100000 {
		return {}, false
	}
	if p[0] == "abs" {
		return {.Fixed, n}, true
	}
	if p[0] == "ratio" && n <= 100 {
		return {.Proportion, n}, true
	}
	return {}, false
}
scroll_size_text :: proc(size: Scroll_Size) -> string {
	return fmt.tprintf(
		"%s:%g",
		size.kind == .Proportion ? "ratio" : "abs",
		size.value,
	)
}

scroll_cycle_width :: proc(v: ^View, n: ^Node, reverse: bool) {
	v.scroll.fill_after_removal = false
	count := v.scroll_options.preset_count
	index := reverse ? count - 1 : 0
	if old, ok := n.column_preset.?; ok && old < count {
		index = (old + (reverse ? count - 1 : 1)) % count
	} else {
		for step in 0 ..< count {
			i := reverse ? count - 1 - step : step
			width := scroll_size_value(v, v.scroll_options.presets[i])
			if reverse \
				   ? width + 1 < n.column_width \
				   : n.column_width + 1 < width {
				index = i; break
			}
		}
	}
	n.column_size = v.scroll_options.presets[index]
	n.column_revision += 1
	n.column_preset = index
	n.column_full = false
	v.scroll.reveal = true
}

scroll_append_row :: proc(n: ^Node, id: u32) {
	// Consume appends after the last row, independently of the active row.
	n.windows[n.count] = id
	n.order[n.count] = id
	n.count += 1
}

scroll_move_column :: proc(v: ^View, n: ^Node, west: bool) {
	other := west ? previous(n) : next(n)
	if other == nil {
		return
	}
	v.scroll.fill_after_removal = true
	swap(n, other)
	n.column_size, other.column_size = other.column_size, n.column_size
	n.column_width, other.column_width = other.column_width, n.column_width
	n.column_resolved, other.column_resolved =
		other.column_resolved, n.column_resolved
	n.column_preset, other.column_preset = other.column_preset, n.column_preset
	n.column_revision, other.column_revision = other.column_revision, n.column_revision
	n.column_full, other.column_full = other.column_full, n.column_full
	n.column_tabbed, other.column_tabbed = other.column_tabbed, n.column_tabbed
	n.column_raised, other.column_raised = 0, 0
	v.scroll.opened, v.scroll.return_to = 0, 0
	v.scroll.reveal = true
}
