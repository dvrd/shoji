package shoji

import "core:math"
import "core:strconv"
import "core:strings"
import "core:fmt"

// Layout tree
// ------------------------------------------------------------------------


// BSP constraints
// ------------------------------------------------------------------------

// Cache constraints on a candidate tree. The requested ratio is retained;
// node_update derives the closest feasible partition for the current bounds.
bsp_measure :: proc(m: ^Manager, n: ^Node, gap: f64) {
	if n == nil {return}
	n.minimum = {}
	if leaf(n) {
		for i in 0 ..< n.count {
			if w := m.windows[n.windows[i]]; w != nil {
				n.minimum.w = max(n.minimum.w, max(w.min_width, w.opening.minimum.w))
				n.minimum.h = max(n.minimum.h, max(w.min_height, w.opening.minimum.h))
			}
		}
		return
	}
	bsp_measure(m, n.left, gap);bsp_measure(m, n.right, gap)
	a, b := n.left.minimum, n.right.minimum
	if n.split == .Vertical {n.minimum = {w = a.w + b.w + gap, h = max(a.h, b.h)}}
	else {n.minimum = {w = max(a.w, b.w), h = a.h + b.h + gap}}
}

bsp_constraints :: proc(m: ^Manager, v: ^View) -> bool {
	view_update(v)
	bsp_measure(m, v.root, v.gap_enabled ? v.gap : 0)
	return v.root.minimum.w <= v.root.frame.w && v.root.minimum.h <= v.root.frame.h
}

// Scroll layout and viewport
// ------------------------------------------------------------------------

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
	if n.column_tabbed && s.view.tab_indicator_top {
		if direction == "east" || direction == "west" {
			for i in 0 ..< n.count {
				if n.windows[i] == w.id {
					j := direction == "east" ? i + 1 : i - 1
					if j >= 0 && j < n.count { return m.windows[n.windows[j]] }
					break
				}
			}
		} else {
			return nil
		}
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

scroll_config :: proc(
	m: ^Manager,
	s: ^Space,
	name, value: string,
	setting: bool,
) -> Response {
	o := s != nil ? s.view.scroll_options : m.scroll_options
	switch name {
	case "scroll_default_column_display":
		if !setting { return success(o.default_tabbed ? "tabbed" : "normal") }
		if value != "normal" && value != "tabbed" {
			return failure("scroll_default_column_display expects normal or tabbed")
		}
		o.default_tabbed = value == "tabbed"
	case "scroll_center_focused_column":
		names := [3]string{"never", "always", "on-overflow"}
		if !setting {
			return success(names[int(o.center)])
		}
		valid := false
		for x, i in names {
			if value == x {
				o.center = type_of(o.center)(i); valid = true
			}
		}
		if !valid {
			return failure(
				"scroll_center_focused_column expects never, always, or on-overflow",
			)
		}
	case "scroll_center_single_column", "scroll_warp_pointer":
		flag := name == "scroll_warp_pointer" ? &o.warp_pointer : &o.center_single
		if !setting {
			return success(flag^ ? "on" : "off")
		}
		if value != "on" && value != "off" {
			return failure("scroll_center_single_column expects on or off")
		}
		flag^ = value == "on"
	case "scroll_default_column_width":
		if !setting {
			return success(scroll_size_text(o.default_width))
		}
		size, ok := scroll_parse_size(value)
		if !ok {
			return failure("expected positive abs:pixels or ratio:fraction")
		}
		o.default_width = size
	case "scroll_width_presets", "scroll_height_presets":
		presets :=
			name == "scroll_width_presets" ? &o.presets : &o.height_presets
		count :=
			name == "scroll_width_presets" \
				? &o.preset_count \
				: &o.height_preset_count
		if !setting {
			parts := make([]string, count^, context.temp_allocator)
			for i in 0 ..< count^ { parts[i] = scroll_size_text(presets[i]) }
			return success(strings.join(parts, ",", context.temp_allocator))
		}
		parts := strings.split(value, ",", context.temp_allocator)
		if len(parts) == 0 || len(parts) > len(o.presets) {
			return failure("expected 1 to 16 size presets")
		}
		for x, i in parts {
			size, ok := scroll_parse_size(x)
			if !ok {
				return failure(
					"size presets expect comma-separated abs:pixels or ratio:fraction",
				)
			}
			presets[i] = size
		}
		count^ = len(parts)
	}
	if s != nil {
		s.view.scroll_options = o
		if name == "scroll_width_presets" {
			for n := first(s.view.root);
			    n != nil;
			    n = next(n) { n.column_preset = nil }
		}
		if name == "scroll_height_presets" {
			for _, w in m.windows {
				if w.space == s.id {
					w.row_preset = nil
				}
			}
		}
		mark_space_override(s, name)
		s.view.scroll.reveal = true
		return result(flush(m, s))
	}
	m.scroll_options = o
	for space in m.spaces {
		if space.overrides[name] {
			continue
		}
		// Copy only the changed option so unrelated per-Space settings survive.
		switch name {
		case "scroll_default_column_display":
			space.view.scroll_options.default_tabbed = o.default_tabbed
		case "scroll_center_focused_column":
			space.view.scroll_options.center = o.center
		case "scroll_center_single_column":
			space.view.scroll_options.center_single = o.center_single
		case "scroll_warp_pointer":
			space.view.scroll_options.warp_pointer = o.warp_pointer
		case "scroll_default_column_width":
			space.view.scroll_options.default_width = o.default_width
		case "scroll_width_presets":
			space.view.scroll_options.presets = o.presets
			space.view.scroll_options.preset_count = o.preset_count
		case "scroll_height_presets":
			space.view.scroll_options.height_presets = o.height_presets
			space.view.scroll_options.height_preset_count =
				o.height_preset_count
		}
		if name == "scroll_width_presets" {
			for n := first(space.view.root);
			    n != nil;
			    n = next(n) { n.column_preset = nil }
		}
		if name == "scroll_height_presets" {
			for _, w in m.windows {
				if w.space == space.id {
					w.row_preset = nil
				}
			}
		}
		space.view.scroll.reveal = true
		if space.visible {
			if err := flush(m, space); err != "" {
				return failure(err)
			}
		}
	}
	return success()
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

scroll_constraints :: proc(m: ^Manager, v: ^View) {
	for n := first(v.root); n != nil; n = next(n) {
		n.column_min, n.column_max = 1, 100000
		for i in 0 ..< n.count {
			if w := m.windows[n.windows[i]]; w != nil {
				n.column_min = max(n.column_min, max(w.min_width, w.opening.minimum.w))
				if w.max_width > 0 {
					n.column_max = min(n.column_max, w.max_width)
				}
			}
		}
		gutter := v.tab_indicator_top ? f64(0) : tab_indicator_gutter(v, n)
		n.column_min += gutter
		if n.column_max < 100000 { n.column_max += gutter }
		n.column_max = max(n.column_min, n.column_max)
	}
}

// Allocate fixed rows first, then water-fill automatic rows around their
// minimums. Round cumulative edges, rather than each height independently.
scroll_rows :: proc(m: ^Manager, v: ^View, use_feedback: bool = false) {
	for n := first(v.root); n != nil; n = next(n) {
		if n.count == 0 {
			continue
		}
		gap := min(scroll_gap(v), max(0, n.frame.h / f64(n.count)))
		remaining := max(1, n.frame.h - gap * f64(n.count - 1))
		pending: [MAX_STACK]bool
		weights: [MAX_STACK]f64
		minima: [MAX_STACK]f64
		weight_sum: f64
		for i in 0 ..< n.count {
			w := m.windows[n.windows[i]]
			if w == nil {
				continue
			}
			minima[i] = max(1, max(w.min_height, w.opening.minimum.h))
			if use_feedback && w.size_feedback.height_valid && !n.column_tabbed && n.zoom == nil {
				n.row_heights[i] = w.size_feedback.accepted.h
				remaining -= n.row_heights[i]
			} else if w.row_fixed > 0 {
				other_min: f64
				for j in 0 ..< n.count {
					if j != i {
						if other := m.windows[n.windows[j]]; other != nil {
							other_min += max(1, other.min_height)
						}
					}
				}
				height := clamp(
					w.row_fixed,
					minima[i],
					max(minima[i], remaining - other_min),
				)
				if w.max_height > 0 {
					height = max(minima[i], min(height, w.max_height))
				}
				n.row_heights[i] = height
				remaining -= height
			} else {
				weights[i] = w.row_weight > 0 ? w.row_weight : 1
				pending[i] = true
				weight_sum += weights[i]
			}
		}
		for _ in 0 ..< n.count {
			changed := false
			for i in 0 ..< n.count {
				if pending[i] &&
				   weight_sum > 0 &&
				   remaining * weights[i] / weight_sum < minima[i] {
					n.row_heights[i] = minima[i]
					remaining -= minima[i]; weight_sum -= weights[i]
					pending[i] = false; changed = true
				}
			}
			if !changed {
				break
			}
		}
		for i in 0 ..< n.count {
			if pending[i] {
				n.row_heights[i] = max(
					minima[i],
					weight_sum > 0 \
						? remaining * weights[i] / weight_sum \
						: minima[i],
				)
			}
		}
		position: f64
		for i in 0 ..< n.count {
			next_position := position + n.row_heights[i]
			n.row_heights[i] = max(
				1,
				math.round(next_position) - math.round(position),
			)
			position = next_position
		}
		if n.count == 1 {
			if w := m.windows[n.windows[0]]; w != nil && w.row_fixed == 0 {
				w.row_weight = 1
			}
		}
	}
}

scroll_set_row :: proc(
	m: ^Manager,
	v: ^View,
	w: ^Window,
	operand: string,
) -> string {
	n := find(v.root, w.id)
	if n == nil {
		return "window is not in a scrolling column"
	}
	if operand == "auto" {
		w.row_revision += 1
		w.row_fixed, w.row_weight = 0, 1; w.row_preset = nil; return ""
	}
	parts := strings.split(operand, ":", context.temp_allocator)
	if len(parts) != 2 {
		return(
			"row-height expects auto, abs:pixels, rel:pixels, ratio:fraction, or weight:value" \
		)
	}
	value, ok := strconv.parse_f64(parts[1])
	if !ok || math.is_nan(value) || math.is_inf(value) {
		return "invalid row height"
	}
	switch parts[0] {
	case "weight":
		if value <= 0 || value > 100000 {
			return "row weight must be positive and at most 100000"
		}
		w.row_revision += 1
		w.row_fixed, w.row_weight = 0, value; w.row_preset = nil; return ""
	case "abs":
	case "rel":
		value += w.frame.h
	case "ratio":
		value = max(
			1,
			(v.scroll.viewport.h - scroll_gap(v)) * value - scroll_gap(v),
		)
	case:
		return "invalid row height mode"
	}
	if value <= 0 || value > 100000 {
		return "row height must be positive and at most 100000"
	}
	// Only one fixed row per column; previous fixed rows become automatic,
	// retaining their apparent height as a weight relative to other auto rows.
	unit_height := f64(1)
	for i in 0 ..< n.count {
		if other := m.windows[n.windows[i]];
		   other != nil && other.row_fixed == 0 {
			unit_height =
				max(1, other.frame.h) /
				(other.row_weight > 0 ? other.row_weight : 1)
			break
		}
	}
	for i in 0 ..< n.count {
		if other := m.windows[n.windows[i]];
		   other != nil && other.id != w.id && other.row_fixed > 0 {
			other.row_weight = max(1, other.frame.h) / unit_height
			other.row_fixed = 0
			other.row_preset = nil
		}
	}
	w.row_fixed = value
	w.row_revision += 1
	w.row_preset = nil
	return ""
}

scroll_cycle_height :: proc(
	m: ^Manager,
	v: ^View,
	w: ^Window,
	reverse: bool,
) -> string {
	count := v.scroll_options.height_preset_count
	index := reverse ? count - 1 : 0
	if old, ok := w.row_preset.?; ok && old < count {
		index = (old + (reverse ? count - 1 : 1)) % count
	} else {
		for step in 0 ..< count {
			i := reverse ? count - 1 - step : step
			size := v.scroll_options.height_presets[i]
			height :=
				size.kind == .Proportion \
					? max(
						1,
						(v.scroll.viewport.h - scroll_gap(v)) * size.value -
						scroll_gap(v),
					) \
					: size.value
			if reverse ? height + 1 < w.frame.h : w.frame.h + 1 < height {
				index = i; break
			}
		}
	}
	size := v.scroll_options.height_presets[index]
	if err := scroll_set_row(m, v, w, scroll_size_text(size)); err != "" {
		return err
	}
	w.row_preset = index
	return ""
}

// Column transfers
// ------------------------------------------------------------------------

scroll_append_row :: proc(n: ^Node, id: u32) {
	// Consume appends after the last row, independently of the active row.
	n.windows[n.count] = id
	n.order[n.count] = id
	n.count += 1
}

scroll_transfer :: proc(
	m: ^Manager,
	s: ^Space,
	w: ^Window,
	operation, direction: string,
) -> string {
	v := &s.view
	n := find(v.root, w.id)
	if n == nil {
		return "window is not in a scrolling column"
	}
	west := direction == "west"
	if operation == "--consume" ||
	   (operation == "--consume-or-expel" && n.count == 1) {
		donor, destination := next(n), n
		moved := u32(0)
		if operation == "--consume" {
			if donor == nil {
				return ""
			}
			moved = donor.windows[0]
		} else {
			destination = west ? previous(n) : next(n)
			if destination == nil {
				return ""
			}
			donor = n
			moved = w.id
		}
		if destination.count == MAX_STACK {
			return "target column is full"
		}
		anchor := destination.windows[0]
		remove(v, moved)
		destination = find(v.root, anchor)
		scroll_append_row(destination, moved)
		if m.focused == moved {
			focus_order(destination, moved)
		}
	} else {
		if n.count <= 1 {
			return ""
		}
		moved := operation == "--expel" ? n.windows[n.count - 1] : w.id
		anchor := n.windows[0] == moved ? n.windows[1] : n.windows[0]
		if operation == "--expel" && m.focused == moved {
			fallback := n.windows[n.count - 2]
			if err := perform(m, {kind = .Focus, window = fallback});
			   err != "" {
				return err
			}
			focus_window(m, fallback)
		}
		size, width, full := n.column_size, n.column_width, n.column_full
		remove(v, moved)
		source := find(v.root, anchor)
		source.insert_first = operation == "--consume-or-expel" && west
		source.insert_stack = false
		add(v, moved, anchor)
		placed := find(v.root, moved)
		placed.column_size, placed.column_full = size, full
		placed.column_width, placed.column_resolved = width, width
	}
	v.scroll.opened, v.scroll.return_to = 0, 0
	v.scroll.reveal = true
	return flush(m, s)
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
