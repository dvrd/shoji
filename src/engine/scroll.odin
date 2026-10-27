package engine

import "core:math"
import "core:strconv"
import "core:strings"

// The tree supplies column membership and ordering. Split ratios are unused:
// widths and viewport position are independent of BSP partition geometry.
Scroll_State :: struct {
	motion: Scroll_Motion,
	dragging: bool,
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

scroll_direction :: proc(
	m: ^Manager,
	s: ^Space,
	w: ^Window,
	direction: string,
) -> ^Window {
	n := find(s.view.root, w.id)
	if n == nil {
		return nil
	}
	if direction == "east" || direction == "west" {
		target := direction == "east" ? next(n) : previous(n)
		if target != nil && target.count > 0 {
			return m.windows[target.order[0]]
		}
		return nil
	}
	for i in 0 ..< n.count {
		if n.windows[i] != w.id {
			continue
		}
		j := direction == "south" ? i + 1 : i - 1
		if j >= 0 && j < n.count {
			return m.windows[n.windows[j]]
		}
	}
	return nil
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
