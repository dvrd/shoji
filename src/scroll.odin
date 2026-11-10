package shoji

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import layout "layout"

// BSP constraints
// ------------------------------------------------------------------------

// Cache constraints on a candidate tree. The requested ratio is retained;
// node_update derives the closest feasible partition for the current bounds.
bsp_measure :: proc(m: ^Manager, n: ^layout.Node, gap: f64) {
	if n == nil {
		return
	}
	n.minimum = {}
	if layout.leaf(n) {
		for i in 0 ..< n.count {
			if w := m.windows[n.windows[i]]; w != nil {
				n.minimum.w = max(n.minimum.w, max(w.min_width, w.opening.minimum.w))
				n.minimum.h = max(n.minimum.h, max(w.min_height, w.opening.minimum.h))
			}
		}
		return
	}
	bsp_measure(m, n.left, gap); bsp_measure(m, n.right, gap)
	a, b := n.left.minimum, n.right.minimum
	if n.split == .Vertical {
		n.minimum = {
			w = a.w + b.w + gap,
			h = max(a.h, b.h),
		}
	} else {
		n.minimum = {
			w = max(a.w, b.w),
			h = a.h + b.h + gap,
		}
	}
}

bsp_constraints :: proc(m: ^Manager, v: ^layout.View) -> bool {
	layout.view_update(v)
	bsp_measure(m, v.root, v.gap_enabled ? v.gap : 0)
	return v.root.minimum.w <= v.root.frame.w && v.root.minimum.h <= v.root.frame.h
}


scroll_direction :: proc(m: ^Manager, s: ^Space, w: ^Window, direction: string) -> ^Window {
	n := layout.find(s.view.root, w.id)
	if n == nil {
		return nil
	}
	if n.column_tabbed && s.view.tab_indicator_top {
		if direction == "east" || direction == "west" {
			for i in 0 ..< n.count {
				if n.windows[i] == w.id {
					j := direction == "east" ? i + 1 : i - 1
					if j >= 0 && j < n.count {
						return m.windows[n.windows[j]]
					}
					break
				}
			}
		} else {
			return nil
		}
	}
	if direction == "east" || direction == "west" {
		target := direction == "east" ? layout.next(n) : layout.previous(n)
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


scroll_config :: proc(m: ^Manager, s: ^Space, name, value: string, setting: bool) -> Response {
	o := s != nil ? s.view.scroll_options : m.scroll_options
	switch name {
	case "scroll_default_column_display":
		if !setting {
			return success(o.default_tabbed ? "tabbed" : "normal")
		}
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
			return failure("scroll_center_focused_column expects never, always, or on-overflow")
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
			return success(layout.scroll_size_text(o.default_width))
		}
		size, ok := layout.scroll_parse_size(value)
		if !ok {
			return failure("expected positive abs:pixels or ratio:fraction")
		}
		o.default_width = size
	case "scroll_width_presets", "scroll_height_presets":
		presets := name == "scroll_width_presets" ? &o.presets : &o.height_presets
		count := name == "scroll_width_presets" ? &o.preset_count : &o.height_preset_count
		if !setting {
			parts := make([]string, count^, context.temp_allocator)
			for i in 0 ..< count^ {parts[i] = layout.scroll_size_text(presets[i])}
			return success(strings.join(parts, ",", context.temp_allocator))
		}
		parts := strings.split(value, ",", context.temp_allocator)
		if len(parts) == 0 || len(parts) > len(o.presets) {
			return failure("expected 1 to 16 size presets")
		}
		for x, i in parts {
			size, ok := layout.scroll_parse_size(x)
			if !ok {
				return failure("size presets expect comma-separated abs:pixels or ratio:fraction")
			}
			presets[i] = size
		}
		count^ = len(parts)
	}
	if s != nil {
		s.view.scroll_options = o
		if name == "scroll_width_presets" {
			for n := layout.first(s.view.root);
			    n != nil;
			    n = layout.next(n) {n.column_preset = nil}
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
			space.view.scroll_options.height_preset_count = o.height_preset_count
		}
		if name == "scroll_width_presets" {
			for n := layout.first(space.view.root);
			    n != nil;
			    n = layout.next(n) {n.column_preset = nil}
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


scroll_constraints :: proc(m: ^Manager, v: ^layout.View) {
	for n := layout.first(v.root); n != nil; n = layout.next(n) {
		n.column_min, n.column_max = 1, 100000
		for i in 0 ..< n.count {
			if w := m.windows[n.windows[i]]; w != nil {
				n.column_min = max(n.column_min, max(w.min_width, w.opening.minimum.w))
				if w.max_width > 0 {
					n.column_max = min(n.column_max, w.max_width)
				}
			}
		}
		gutter := v.tab_indicator_top ? f64(0) : layout.tab_indicator_gutter(v, n)
		n.column_min += gutter
		if n.column_max < 100000 {
			n.column_max += gutter
		}
		n.column_max = max(n.column_min, n.column_max)
	}
}

// Allocate fixed rows first, then water-fill automatic rows around their
// minimums. Round cumulative edges, rather than each height independently.
scroll_rows :: proc(m: ^Manager, v: ^layout.View, use_feedback: bool = false) {
	for n := layout.first(v.root); n != nil; n = layout.next(n) {
		if n.count == 0 {
			continue
		}
		gap := min(layout.scroll_gap(v), max(0, n.frame.h / f64(n.count)))
		remaining := max(1, n.frame.h - gap * f64(n.count - 1))
		pending: [layout.MAX_STACK]bool
		weights: [layout.MAX_STACK]f64
		minima: [layout.MAX_STACK]f64
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
				height := clamp(w.row_fixed, minima[i], max(minima[i], remaining - other_min))
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
					weight_sum > 0 ? remaining * weights[i] / weight_sum : minima[i],
				)
			}
		}
		position: f64
		for i in 0 ..< n.count {
			next_position := position + n.row_heights[i]
			n.row_heights[i] = max(1, math.round(next_position) - math.round(position))
			position = next_position
		}
		if n.count == 1 {
			if w := m.windows[n.windows[0]]; w != nil && w.row_fixed == 0 {
				w.row_weight = 1
			}
		}
	}
}

scroll_set_row :: proc(m: ^Manager, v: ^layout.View, w: ^Window, operand: string) -> string {
	n := layout.find(v.root, w.id)
	if n == nil {
		return "window is not in a scrolling column"
	}
	if operand == "auto" {
		w.row_revision += 1
		w.row_fixed, w.row_weight = 0, 1; w.row_preset = nil; return ""
	}
	parts := strings.split(operand, ":", context.temp_allocator)
	if len(parts) != 2 {
		return "row-height expects auto, abs:pixels, rel:pixels, ratio:fraction, or weight:value"
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
		value = max(1, (v.scroll.viewport.h - layout.scroll_gap(v)) * value - layout.scroll_gap(v))
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
		if other := m.windows[n.windows[i]]; other != nil && other.row_fixed == 0 {
			unit_height = max(1, other.frame.h) / (other.row_weight > 0 ? other.row_weight : 1)
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

scroll_cycle_height :: proc(m: ^Manager, v: ^layout.View, w: ^Window, reverse: bool) -> string {
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
						(v.scroll.viewport.h - layout.scroll_gap(v)) * size.value -
						layout.scroll_gap(v),
					) \
					: size.value
			if reverse ? height + 1 < w.frame.h : w.frame.h + 1 < height {
				index = i; break
			}
		}
	}
	size := v.scroll_options.height_presets[index]
	if err := scroll_set_row(m, v, w, layout.scroll_size_text(size)); err != "" {
		return err
	}
	w.row_preset = index
	return ""
}

// Column transfers
// ------------------------------------------------------------------------


scroll_transfer :: proc(
	m: ^Manager,
	s: ^Space,
	w: ^Window,
	operation, direction: string,
) -> string {
	v := &s.view
	n := layout.find(v.root, w.id)
	if n == nil {
		return "window is not in a scrolling column"
	}
	west := direction == "west"
	if operation == "--consume" || (operation == "--consume-or-expel" && n.count == 1) {
		donor, destination := layout.next(n), n
		moved := u32(0)
		if operation == "--consume" {
			if donor == nil {
				return ""
			}
			moved = donor.windows[0]
		} else {
			destination = west ? layout.previous(n) : layout.next(n)
			if destination == nil {
				return ""
			}
			donor = n
			moved = w.id
		}
		if destination.count == layout.MAX_STACK {
			return "target column is full"
		}
		anchor := destination.windows[0]
		layout.remove(v, moved)
		destination = layout.find(v.root, anchor)
		layout.scroll_append_row(destination, moved)
		if m.focused == moved {
			layout.focus_order(destination, moved)
		}
	} else {
		if n.count <= 1 {
			return ""
		}
		moved := operation == "--expel" ? n.windows[n.count - 1] : w.id
		anchor := n.windows[0] == moved ? n.windows[1] : n.windows[0]
		if operation == "--expel" && m.focused == moved {
			fallback := n.windows[n.count - 2]
			if err := perform(m, {kind = .Focus, window = fallback}); err != "" {
				return err
			}
			focus_window(m, fallback)
		}
		size, width, full := n.column_size, n.column_width, n.column_full
		layout.remove(v, moved)
		source := layout.find(v.root, anchor)
		source.insert_first = operation == "--consume-or-expel" && west
		source.insert_stack = false
		layout.add(v, moved, anchor)
		placed := layout.find(v.root, moved)
		placed.column_size, placed.column_full = size, full
		placed.column_width, placed.column_resolved = width, width
	}
	v.scroll.opened, v.scroll.return_to = 0, 0
	v.scroll.reveal = true
	return flush(m, s)
}

// Window animation
// ------------------------------------------------------------------------

Easing :: enum {
	Linear,
	In_Sine,
	Out_Sine,
	In_Out_Sine,
	In_Quad,
	Out_Quad,
	In_Out_Quad,
	In_Cubic,
	Out_Cubic,
	In_Out_Cubic,
	In_Quart,
	Out_Quart,
	In_Out_Quart,
	In_Quint,
	Out_Quint,
	In_Out_Quint,
	In_Expo,
	Out_Expo,
	In_Out_Expo,
	In_Circ,
	Out_Circ,
	In_Out_Circ,
}
EASING_NAMES := []string {
	"linear",
	"ease_in_sine",
	"ease_out_sine",
	"ease_in_out_sine",
	"ease_in_quad",
	"ease_out_quad",
	"ease_in_out_quad",
	"ease_in_cubic",
	"ease_out_cubic",
	"ease_in_out_cubic",
	"ease_in_quart",
	"ease_out_quart",
	"ease_in_out_quart",
	"ease_in_quint",
	"ease_out_quint",
	"ease_in_out_quint",
	"ease_in_expo",
	"ease_out_expo",
	"ease_in_out_expo",
	"ease_in_circ",
	"ease_out_circ",
	"ease_in_out_circ",
}

ease :: proc(kind: Easing, t: f64) -> f64 {
	t := clamp(t, 0, 1)
	if t == 0 || t == 1 {
		return t
	}
	#partial switch kind {
	case .Linear:
		return t
	case .In_Sine:
		return 1 - math.cos(t * math.PI / 2)
	case .Out_Sine:
		return math.sin(t * math.PI / 2)
	case .In_Out_Sine:
		return (1 - math.cos(t * math.PI)) / 2
	case .In_Expo:
		return math.pow(2, 10 * t - 10)
	case .Out_Expo:
		return 1 - math.pow(2, -10 * t)
	case .In_Out_Expo:
		return t < 0.5 ? math.pow(2, 20 * t - 10) / 2 : (2 - math.pow(2, -20 * t + 10)) / 2
	case .In_Circ:
		return 1 - math.sqrt(1 - t * t)
	case .Out_Circ:
		return math.sqrt(1 - (t - 1) * (t - 1))
	case .In_Out_Circ:
		return(
			t < 0.5 \
				? (1 - math.sqrt(1 - 4 * t * t)) / 2 \
				: (math.sqrt(1 - math.pow(-2 * t + 2, 2)) + 1) / 2 \
		)
	case:
	}
	index := int(kind) - int(Easing.In_Quad)
	power := f64(index / 3 + 2)
	switch index % 3 {
	case 0:
		return math.pow(t, power)
	case 1:
		return 1 - math.pow(1 - t, power)
	case 2:
		return(
			t < 0.5 \
				? math.pow(2, power - 1) * math.pow(t, power) \
				: 1 - math.pow(-2 * t + 2, power) / 2 \
		)
	}
	return t
}

interpolate_frame :: proc(from, to: Rect, progress: f64, kind: Easing) -> Rect {
	t := ease(kind, progress)
	return {
		from.x + (to.x - from.x) * t,
		from.y + (to.y - from.y) * t,
		from.w + (to.w - from.w) * t,
		from.h + (to.h - from.h) * t,
	}
}

// Viewport springs
// ------------------------------------------------------------------------

SCROLL_SPRING_OMEGA :: 28.2842712474619 // sqrt(800), unit mass, critical damping
SCROLL_SPRING_DURATION :: 0.3256347067030293 // -ln(0.0001) / sqrt(800)

scroll_motion_sample :: proc(motion: ^layout.Scroll_Motion, now: f64) {
	if !motion.active {
		return
	}
	t := max(0, now - motion.began)
	if t >= SCROLL_SPRING_DURATION {
		motion.position, motion.velocity, motion.active = motion.target, 0, false
		return
	}
	y := motion.from - motion.target
	b := motion.initial_velocity + SCROLL_SPRING_OMEGA * y
	decay := math.exp(-SCROLL_SPRING_OMEGA * t)
	motion.position = motion.target + (y + b * t) * decay
	motion.velocity = (motion.initial_velocity - SCROLL_SPRING_OMEGA * b * t) * decay
}
scroll_motion_prepare :: proc(v: ^layout.View, now: f64, animate: bool) {
	motion := &v.scroll.motion
	if !motion.initialized || !animate || v.scroll.dragging {
		motion^ = {
			initialized = true,
			position    = v.scroll.offset,
			target      = v.scroll.offset,
			anchor      = v.scroll.anchor,
		}
		return
	}
	if motion.target != v.scroll.offset || (!motion.active && motion.velocity != 0) {
		scroll_motion_sample(motion, now)
		motion.from, motion.initial_velocity = motion.position, motion.velocity
		motion.target, motion.began, motion.active = v.scroll.offset, now, true
	}
	motion.anchor = v.scroll.anchor
}
scroll_motion_tick :: proc(m: ^Manager, now: f64) -> string {
	m.scroll_time = now
	for s in m.spaces {
		if !s.view.scroll.motion.active && !s.view.scroll.geometry_active {
			continue
		}
		if !m.scroll_animate ||
		   s.view.layout != .Scroll ||
		   !s.visible ||
		   m.suspended ||
		   m.gesture_active {
			s.view.scroll.motion.active = false
			s.view.scroll.motion.position = s.view.scroll.offset
			s.view.scroll.motion.velocity = 0
			scroll_geometry_finish(m, s)
			continue
		}
		scroll_motion_sample(&s.view.scroll.motion, now)
		if err := flush(m, s); err != "" {
			s.view.scroll.motion.active = false
			s.view.scroll.motion.position = s.view.scroll.offset
			s.view.scroll.motion.velocity = 0
			scroll_geometry_finish(m, s)
			return err
		}
	}
	return ""
}
scroll_begin_pan :: proc(m: ^Manager, s: ^Space) {
	v := &s.view
	if m.scroll_animate && v.scroll.motion.initialized {
		scroll_motion_sample(&v.scroll.motion, m.scroll_time)
		v.scroll.offset = v.scroll.motion.position
	}
	v.scroll.anchor = 0
	v.scroll.dragging = true
	v.scroll.motion.active = false
	layout.scroll_update(v)
	layout.scroll_anchor(v, v.scroll.focused)
}

Scroll_Snap :: struct {
	offset:   f64,
	window:   u32,
	centered: bool,
}
scroll_snap_target :: proc(v: ^layout.View, position, velocity: f64) -> Scroll_Snap {
	projected := position + velocity * 0.332833083
	gap, width := layout.scroll_gap(v), v.scroll.viewport.w
	leading, trailing := layout.first(v.root), layout.last(v.root)
	if leading == nil || leading.count == 0 {
		return {position, 0, false}
	}
	first_x := leading.frame.x - v.scroll.viewport.x + v.scroll.offset
	last_x := trailing.frame.x - v.scroll.viewport.x + v.scroll.offset
	minimum := first_x - min(gap, max(0, (width - leading.column_width) * 0.5))
	maximum := max(
		minimum,
		last_x +
		trailing.column_width -
		width +
		min(gap, max(0, (width - trailing.column_width) * 0.5)),
	)
	best := Scroll_Snap {
		offset = minimum,
		window = leading.order[0],
	}
	best_distance := f64(1e300)
	for n := leading; n != nil; n = layout.next(n) {
		if n.count == 0 {
			continue
		}
		x := n.frame.x - v.scroll.viewport.x + v.scroll.offset
		padding := min(gap, max(0, (width - n.column_width) * 0.5))
		center :=
			v.scroll_options.center == .Always ||
			(v.scroll_options.center_single && leading == trailing)
		// On overflow, center only against the neighbor on the side we came
		// from. The other side can overflow without pulling this column center.
		rest_center := false
		if v.scroll_options.center == .On_Overflow {
			left, right := layout.previous(n), layout.next(n)
			left_overflows := left != nil && left.column_width + n.column_width + 3 * gap > width
			right_overflows :=
				right != nil && right.column_width + n.column_width + 3 * gap > width
			old := layout.find(v.root, v.scroll.focused)
			if old != nil && old != n {
				center = old.frame.x < n.frame.x ? left_overflows : right_overflows
			} else {
				rest_center = left_overflows || right_overflows
			}
		}
		mid := n.column_width < width ? x + (n.column_width - width) * 0.5 : x
		offsets: [3]f64
		centered_offset: [3]bool
		count := 0
		if center {
			offsets[0] = clamp(mid, minimum, maximum)
			centered_offset[0] = true
			count = 1
		} else {
			offsets[0] = clamp(x - padding, minimum, maximum)
			offsets[1] = clamp(x + n.column_width - width + padding, minimum, maximum)
			count = 2
			if rest_center {
				offsets[2] = clamp(mid, minimum, maximum)
				centered_offset[2] = true
				count = 3
			}
		}
		for i in 0 ..< count {
			candidate := offsets[i]
			distance := math.abs(projected - candidate)
			if distance < best_distance || (distance == best_distance && candidate < best.offset) {
				best = {candidate, n.order[0], centered_offset[i]}
				best_distance = distance
			}
		}
	}
	if !best.centered {
		for n := leading; n != nil; n = layout.next(n) {
			x := n.frame.x - v.scroll.viewport.x + v.scroll.offset - best.offset
			padding := min(gap, max(0, (width - n.column_width) * 0.5))
			if x >= padding - 0.001 && x + n.column_width <= width - padding + 0.001 {
				best.window = n.order[0]
				if projected < position {
					break
				}
			}
		}
	}
	return best
}
scroll_finish_pan :: proc(
	m: ^Manager,
	s: ^Space,
	velocity: f64,
	prevent_overshoot: bool = false,
	step: i32 = 0,
) -> string {
	velocity := velocity
	v := &s.view
	if math.is_nan(velocity) || math.is_inf(velocity) {
		velocity = 0
	}
	velocity = clamp(velocity, -100000, 100000)
	v.scroll.dragging = false
	snap := scroll_snap_target(v, v.scroll.offset, velocity)
	if step != 0 {
		current := layout.find(v.root, m.focused)
		neighbor := step > 0 ? layout.next(current) : layout.previous(current)
		if neighbor != nil && neighbor.count > 0 {
			// Reveal only the adjacent column, independently of fling speed.
			before := v.scroll.offset
			layout.scroll_reveal(v, neighbor.order[0])
			snap = {
				offset = v.scroll.offset,
				window = neighbor.order[0],
			}
			v.scroll.offset = before; layout.scroll_update(v)
		}
	}
	if snap.window == 0 {
		return ""
	}
	if snap.window != m.focused {
		if err := perform(m, {kind = .Focus, window = snap.window}); err != "" {
			return err
		}
		focus_window(m, snap.window)
	}
	v.scroll.anchor = 0
	v.scroll.offset = snap.offset
	layout.scroll_update(v)
	layout.scroll_anchor(v, snap.window)
	v.scroll.focused, v.scroll.reveal = snap.window, false
	if prevent_overshoot {
		distance := snap.offset - v.scroll.motion.position
		velocity =
			distance >= 0 \
				? clamp(velocity, 0, SCROLL_SPRING_OMEGA * distance) \
				: clamp(velocity, SCROLL_SPRING_OMEGA * distance, 0)
	}
	v.scroll.motion.velocity = velocity
	return flush(m, s)
}

Scroll_Velocity :: struct {
	samples:  [64]struct {
		at, position: f64,
	},
	count:    int,
	position: f64,
}
scroll_velocity_add :: proc(v: ^Scroll_Velocity, delta, at: f64) {
	if v.count > 0 && at <= v.samples[v.count - 1].at {
		return
	}
	v.position += delta
	start := 0
	for start < v.count && at - v.samples[start].at > 0.15 {start += 1}
	if start > 0 {
		copy(v.samples[:], v.samples[start:v.count]); v.count -= start
	}
	if v.count == len(v.samples) {
		copy(v.samples[:], v.samples[1:]); v.count -= 1
	}
	v.samples[v.count] = {at, v.position}; v.count += 1
}
scroll_velocity_get :: proc(v: ^Scroll_Velocity) -> f64 {
	if v.count < 2 {
		return 0
	}
	a, b := v.samples[0], v.samples[v.count - 1]
	return (b.position - a.position) / (b.at - a.at)
}

pointer_follows_focus :: proc(m: ^Manager, w: ^Window) -> bool {
	if override, known := w.mouse_follows_focus.?; known {
		return override
	}
	if s := space_by_id(m, w.space);
	   s != nil && s.view.layout == .Scroll && !s.view.scroll_options.warp_pointer {
		return false
	}
	return m.mouse.follows_focus
}

// Animated geometry
// ------------------------------------------------------------------------

Scroll_Frame :: struct {
	valid:                                             bool,
	snap_width, snap_height:                           bool,
	space:                                             u64,
	from, target, current, velocity, initial_velocity: Rect,
	progress:                                          f64,
}
scroll_rect_near :: proc(a, b: Rect, tolerance: f64 = 0.001) -> bool {
	return(
		math.abs(a.x - b.x) <= tolerance &&
		math.abs(a.y - b.y) <= tolerance &&
		math.abs(a.w - b.w) <= tolerance &&
		math.abs(a.h - b.h) <= tolerance \
	)
}
scroll_small_resize :: proc(current, target, velocity, limit: f64) -> bool {
	delta := target - current
	if math.abs(delta) > limit {
		return false
	}
	// Only cancel slow motion already heading toward the new size. A fast
	// reversal retains its velocity rather than popping into a nearby target.
	if delta == 0 {
		return math.abs(velocity) < .001
	}
	return velocity * delta >= 0 && math.abs(velocity) <= SCROLL_SPRING_OMEGA * math.abs(delta)
}
scroll_frame_sample :: proc(frame: ^Scroll_Frame, elapsed: f64) {
	if elapsed >= SCROLL_SPRING_DURATION {
		frame.current, frame.velocity, frame.progress = frame.target, {}, 1
		return
	}
	t := max(0, elapsed)
	decay := math.exp(-SCROLL_SPRING_OMEGA * t)
	a, b := (1 + SCROLL_SPRING_OMEGA * t) * decay, t * decay
	// Content blending follows the animation clock, independent of retained
	// geometry velocity (which can move through the target before settling).
	frame.progress = clamp(1 - a, 0, 1)
	c, d :=
		-SCROLL_SPRING_OMEGA *
		SCROLL_SPRING_OMEGA *
		t *
		decay,
		(1 - SCROLL_SPRING_OMEGA * t) *
		decay
	from := [4]f64{frame.from.x, frame.from.y, frame.from.w, frame.from.h}
	target := [4]f64{frame.target.x, frame.target.y, frame.target.w, frame.target.h}
	velocity := [4]f64 {
		frame.initial_velocity.x,
		frame.initial_velocity.y,
		frame.initial_velocity.w,
		frame.initial_velocity.h,
	}
	positions, speeds: [4]f64
	for i in 0 ..< 4 {
		positions[i] = target[i] + (from[i] - target[i]) * a + velocity[i] * b
		speeds[i] = (from[i] - target[i]) * c + velocity[i] * d
	}
	frame.current = {positions[0], positions[1], positions[2], positions[3]}
	frame.velocity = {speeds[0], speeds[1], speeds[2], speeds[3]}
	if frame.snap_width {
		frame.current.w = frame.target.w; frame.velocity.w = 0
	}
	if frame.snap_height {
		frame.current.h = frame.target.h; frame.velocity.h = 0
	}
}
scroll_world_target :: proc(v: ^layout.View, n: ^layout.Node, w: ^Window) -> Rect {
	r := size_feedback_frame(w, layout.scroll_window_frame(v, n, w.id, false))
	r.x += v.scroll.offset
	return r
}
scroll_geometry_prepare :: proc(m: ^Manager, s: ^Space) {
	v := &s.view
	changed := false
	for n := layout.first(v.root); n != nil; n = layout.next(n) {
		for i in 0 ..< n.count {
			w := m.windows[n.windows[i]]
			if w == nil {
				continue
			}
			target := scroll_world_target(v, n, w)
			if w.scroll_frame.valid &&
			   w.scroll_frame.space == s.id &&
			   !scroll_rect_near(w.scroll_frame.target, target) {
				changed = true
			}
		}
	}
	previously_active := v.scroll.geometry_active
	active := false
	for n := layout.first(v.root); n != nil; n = layout.next(n) {
		for i in 0 ..< n.count {
			w := m.windows[n.windows[i]]
			if w == nil {
				continue
			}
			target := scroll_world_target(v, n, w)
			f := &w.scroll_frame
			if !f.valid || f.space != s.id || !v.scroll.geometry_enabled {
				f^ = {
					valid    = true,
					space    = s.id,
					from     = target,
					target   = target,
					current  = target,
					progress = 1,
				}
				continue
			}
			if previously_active {
				scroll_frame_sample(f, m.scroll_time - v.scroll.geometry_began)
			}
			if changed {
				// A small resize can resolve in one content update while existing
				// position motion continues. Cap the cutoff to the gap so a growing
				// body uses only the available spacing during catch-up motion.
				cutoff := min(10.0, layout.scroll_gap(v))
				if f.target.w != target.w {
					f.snap_width = scroll_small_resize(f.current.w, target.w, f.velocity.w, cutoff)
				}
				if f.target.h != target.h {
					f.snap_height = scroll_small_resize(
						f.current.h,
						target.h,
						f.velocity.h,
						cutoff,
					)
				}
				f.from, f.initial_velocity, f.target = f.current, f.velocity, target
				f.progress = 0
				if f.snap_width {
					f.current.w, f.from.w = target.w, target.w
					f.velocity.w, f.initial_velocity.w = 0, 0
				}
				if f.snap_height {
					f.current.h, f.from.h = target.h, target.h
					f.velocity.h, f.initial_velocity.h = 0, 0
				}
			}
			if !scroll_rect_near(f.current, f.target) || !scroll_rect_near(f.velocity, {}) {
				active = true
			}
		}
	}
	if changed {
		v.scroll.geometry_began = m.scroll_time
	}
	v.scroll.geometry_active = active
}
scroll_geometry_finish :: proc(m: ^Manager, s: ^Space) {
	s.view.scroll.geometry_active = false
	for _, w in m.windows {
		if w.space == s.id {
			w.scroll_frame.current, w.scroll_frame.velocity = w.scroll_frame.target, {}
			w.scroll_frame.progress = 1
		}
	}
}

// Scroll layout persistence
// ------------------------------------------------------------------------
// Column membership, row order, the active tab and each column's width,
// full-width and tabbed state survive a daemon restart. Window IDs live as
// long as their app's WindowServer connection, so the snapshot sits in /tmp
// (gone after a reboot, when the IDs are too) and every window must match its
// saved ID and owning PID before it is placed. Windows that are gone are
// skipped; windows the snapshot does not know keep the place they opened in.

LAYOUT_SNAPSHOT_VERSION :: 1
LAYOUT_SNAPSHOT_BYTES :: 1 << 20
LAYOUT_SNAPSHOT_SPACES :: 64
LAYOUT_SNAPSHOT_SAVE_INTERVAL :: 2 * time.Second
// shojirc sets Space layouts, so restore waits for it, bounded like the ring
// hold so a hung config cannot keep the snapshot from ever applying.
LAYOUT_SNAPSHOT_RESTORE_WAIT :: 20 * time.Second

Snapshot_Window :: struct {
	id:  u32,
	pid: i32,
}
Snapshot_Column :: struct {
	windows:    []Snapshot_Window, // row order
	order:      []u32, // most recent first; order[0] is the active tab
	size_kind:  int,
	size_value: f64,
	width:      f64,
	preset:     int, // -1 when unset
	full:       bool,
	tabbed:     bool,
}
Snapshot_Space :: struct {
	uuid:    string,
	columns: []Snapshot_Column,
}
Snapshot_Data :: struct {
	version: int,
	spaces:  []Snapshot_Space,
}

Layout_Snapshot :: struct {
	path:      string,
	restored:  bool,
	started:   time.Time,
	next_save: time.Time,
	saved:     []u8, // last bytes written, heap-owned
}

layout_snapshot_open :: proc(snap: ^Layout_Snapshot, path: string, now: time.Time) {
	snap^ = {
		path    = path,
		started = now,
	}
}

// Saves a final snapshot, but only once the startup restore has run: before
// that the layout is the unrestored one and would overwrite the saved state.
layout_snapshot_close :: proc(snap: ^Layout_Snapshot, m: ^Manager) {
	if snap.path != "" && snap.restored {
		layout_snapshot_save(snap, m)
	}
	delete(snap.saved)
	delete(snap.path)
	snap^ = {}
}

layout_snapshot_tick :: proc(state: ^State, config_finished: bool, now: time.Time) {
	snap := &state.layout_snapshot
	if snap.path == "" {
		return
	}
	if !snap.restored {
		if !config_finished && time.diff(snap.started, now) < LAYOUT_SNAPSHOT_RESTORE_WAIT {
			return
		}
		snap.restored = true
		snap.next_save = time.time_add(now, LAYOUT_SNAPSHOT_SAVE_INTERVAL)
		if err := layout_snapshot_load(snap, &state.manager); err != "" {
			fmt.eprintln("shoji: layout snapshot:", err)
		}
		return
	}
	if time.diff(now, snap.next_save) > 0 {
		return
	}
	snap.next_save = time.time_add(now, LAYOUT_SNAPSHOT_SAVE_INTERVAL)
	layout_snapshot_save(snap, &state.manager)
}

layout_snapshot_save :: proc(snap: ^Layout_Snapshot, m: ^Manager) {
	bytes, err := json.marshal(layout_snapshot_capture(m), allocator = context.temp_allocator)
	if err != nil || len(bytes) > LAYOUT_SNAPSHOT_BYTES {
		fmt.eprintln("shoji: layout snapshot: cannot encode")
		return
	}
	if slice.equal(bytes, snap.saved) {
		return
	}
	if write_error := private_file_write(snap.path, bytes); write_error != "" {
		fmt.eprintln("shoji: layout snapshot:", write_error)
		return
	}
	delete(snap.saved)
	snap.saved = slice.clone(bytes)
}

layout_snapshot_load :: proc(snap: ^Layout_Snapshot, m: ^Manager) -> string {
	bytes, found, read_error := private_file_read(snap.path, LAYOUT_SNAPSHOT_BYTES)
	if !found && read_error == "" {
		return ""
	}
	if read_error != "" {
		return read_error
	}
	data: Snapshot_Data
	if json.unmarshal(bytes, &data, allocator = context.temp_allocator) != nil ||
	   data.version != LAYOUT_SNAPSHOT_VERSION ||
	   len(data.spaces) > LAYOUT_SNAPSHOT_SPACES {
		return "invalid snapshot data"
	}
	layout_snapshot_restore(m, data)
	return ""
}

layout_snapshot_capture :: proc(m: ^Manager) -> Snapshot_Data {
	spaces := make([dynamic]Snapshot_Space, 0, len(m.spaces), context.temp_allocator)
	for s in m.spaces {
		if s.view.layout != .Scroll || s.uuid == "" || len(spaces) == LAYOUT_SNAPSHOT_SPACES {
			continue
		}
		columns := make([dynamic]Snapshot_Column, 0, 8, context.temp_allocator)
		for n := layout.first(s.view.root); n != nil; n = layout.next(n) {
			if n.count > 0 {
				append(&columns, snapshot_column(m, n))
			}
		}
		if len(columns) > 0 {
			append(&spaces, Snapshot_Space{s.uuid, columns[:]})
		}
	}
	return {LAYOUT_SNAPSHOT_VERSION, spaces[:]}
}

snapshot_column :: proc(m: ^Manager, n: ^layout.Node) -> Snapshot_Column {
	windows := make([]Snapshot_Window, n.count, context.temp_allocator)
	for i in 0 ..< n.count {
		pid: i32
		if w := m.windows[n.windows[i]]; w != nil {
			pid = w.pid
		}
		windows[i] = {n.windows[i], pid}
	}
	return {
		windows = windows,
		order = slice.clone(n.order[:n.count], context.temp_allocator),
		size_kind = int(n.column_size.kind),
		size_value = n.column_size.value,
		width = n.column_width,
		preset = n.column_preset.? or_else -1,
		full = n.column_full,
		tabbed = n.column_tabbed,
	}
}

layout_snapshot_restore :: proc(m: ^Manager, data: Snapshot_Data) {
	for space in data.spaces {
		s: ^Space
		for candidate in m.spaces {
			if candidate.uuid == space.uuid {
				s = candidate; break
			}
		}
		if s == nil || s.view.layout != .Scroll {
			continue
		}
		if snapshot_restore_space(m, s, space) == 0 {
			continue
		}
		if err := flush(m, s); err != "" {
			fmt.eprintln("shoji: layout snapshot:", err)
		}
	}
}

// Restored columns are rebuilt left to right in front of the windows the
// snapshot does not know, each one after the previously restored column.
snapshot_restore_space :: proc(m: ^Manager, s: ^Space, space: Snapshot_Space) -> (columns: int) {
	v := &s.view
	anchor: u32
	for column in space.columns {
		ids := snapshot_live_windows(m, s, column)
		if len(ids) == 0 {
			continue
		}
		for id in ids {layout.remove(v, id)}
		if !snapshot_place_column(v, ids, anchor) {
			continue
		}
		snapshot_apply_column(layout.find(v.root, ids[0]), column, ids)
		anchor = ids[0]
		columns += 1
	}
	return
}

// Saved windows that still exist, are owned by the same process and are tiled
// on this Space, in saved row order (temp allocator).
snapshot_live_windows :: proc(m: ^Manager, s: ^Space, column: Snapshot_Column) -> []u32 {
	ids := make([dynamic]u32, 0, len(column.windows), context.temp_allocator)
	for saved in column.windows {
		if len(ids) == layout.MAX_STACK || slice.contains(ids[:], saved.id) {
			continue
		}
		w := m.windows[saved.id]
		if w == nil || w.pid != saved.pid || w.space != s.id || !layout_admitted(w) {
			continue
		}
		if layout.find(s.view.root, saved.id) == nil {
			continue
		}
		append(&ids, saved.id)
	}
	return ids[:]
}

snapshot_place_column :: proc(v: ^layout.View, ids: []u32, anchor: u32) -> bool {
	target := layout.find(v.root, anchor)
	before := false
	if target == nil {
		target = layout.first(v.root)
		before = true
	}
	if target != nil && target.count > 0 {
		// Same insertion as a returning column (scroll_return_restore).
		anchor_id := target.windows[0]
		insert_first, insert_stack, insertion :=
			target.insert_first, target.insert_stack, v.insertion
		target.insert_first, target.insert_stack = before, false
		ok := layout.add(v, ids[0], anchor_id)
		if old := layout.find(v.root, anchor_id); old != nil {
			old.insert_first, old.insert_stack = insert_first, insert_stack
		}
		v.insertion = insertion
		if !ok {
			return false
		}
	} else if !layout.add(v, ids[0]) {
		return false
	}
	n := layout.find(v.root, ids[0])
	for id in ids[1:] {
		// Cannot overflow: ids holds at most MAX_STACK windows.
		pushed := layout.stack_push(n, id)
		assert(pushed)
	}
	return true
}

snapshot_apply_column :: proc(n: ^layout.Node, column: Snapshot_Column, ids: []u32) {
	assert(n != nil && n.count == len(ids))
	for id, i in ids {n.windows[i] = id}
	count := 0
	for id in column.order {
		if count < n.count && slice.contains(ids, id) && !slice.contains(n.order[:count], id) {
			n.order[count] = id
			count += 1
		}
	}
	for id in ids {
		if count < n.count && !slice.contains(n.order[:count], id) {
			n.order[count] = id
			count += 1
		}
	}
	n.column_tabbed, n.column_full = column.tabbed, column.full
	if column.size_kind >= 0 && column.size_kind <= 2 && !math.is_nan(column.size_value) {
		n.column_size = {
			kind  = type_of(n.column_size.kind)(column.size_kind),
			value = column.size_value,
		}
	}
	if column.width > 0 && !math.is_inf(column.width) {
		n.column_width, n.column_resolved = column.width, column.width
	}
	n.column_preset = nil
	if column.preset >= 0 {
		n.column_preset = column.preset
	}
}
