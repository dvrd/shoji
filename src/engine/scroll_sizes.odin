package engine

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

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
