package shoji

import "core:math"
import "core:strconv"
import "core:strings"
import layout "layout"

// BSP constraints
// ------------------------------------------------------------------------

// Cache constraints on a candidate tree. The requested ratio is retained;
// node_update derives the closest feasible partition for the current bounds.
bsp_measure :: proc(m: ^Manager, n: ^layout.Node, gap: f64) {
	if n == nil {return}
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
	bsp_measure(m, n.left, gap);bsp_measure(m, n.right, gap)
	a, b := n.left.minimum, n.right.minimum
	if n.split == .Vertical {n.minimum = {w = a.w + b.w + gap, h = max(a.h, b.h)}}
	else {n.minimum = {w = max(a.w, b.w), h = a.h + b.h + gap}}
}

bsp_constraints :: proc(m: ^Manager, v: ^layout.View) -> bool {
	layout.view_update(v)
	bsp_measure(m, v.root, v.gap_enabled ? v.gap : 0)
	return v.root.minimum.w <= v.root.frame.w && v.root.minimum.h <= v.root.frame.h
}


scroll_direction :: proc(
	m: ^Manager,
	s: ^Space,
	w: ^Window,
	direction: string,
) -> ^Window {
	n := layout.find(s.view.root, w.id)
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
			return success(layout.scroll_size_text(o.default_width))
		}
		size, ok := layout.scroll_parse_size(value)
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
			for i in 0 ..< count^ { parts[i] = layout.scroll_size_text(presets[i]) }
			return success(strings.join(parts, ",", context.temp_allocator))
		}
		parts := strings.split(value, ",", context.temp_allocator)
		if len(parts) == 0 || len(parts) > len(o.presets) {
			return failure("expected 1 to 16 size presets")
		}
		for x, i in parts {
			size, ok := layout.scroll_parse_size(x)
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
			for n := layout.first(s.view.root);
			    n != nil;
			    n = layout.next(n) { n.column_preset = nil }
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
			for n := layout.first(space.view.root);
			    n != nil;
			    n = layout.next(n) { n.column_preset = nil }
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
		if n.column_max < 100000 { n.column_max += gutter }
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
	v: ^layout.View,
	w: ^Window,
	operand: string,
) -> string {
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
			(v.scroll.viewport.h - layout.scroll_gap(v)) * value - layout.scroll_gap(v),
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
	v: ^layout.View,
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
	if operation == "--consume" ||
	   (operation == "--consume-or-expel" && n.count == 1) {
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
			if err := perform(m, {kind = .Focus, window = fallback});
			   err != "" {
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
