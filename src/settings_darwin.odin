package shoji

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

foreign import libc "system:c"

// Configuration
// ------------------------------------------------------------------------

config :: proc(m: ^Manager, args: []string) -> Response {
	args := args
	s: ^Space
	if len(args) >= 2 && args[0] == "--space" {
		s = select_space(m, args[1])
		if s == nil {
			return failure("could not locate space")
		}
		args = args[2:]
	}
	if len(args) < 1 || len(args) > 2 {
		return failure("config expects a setting and optional value")
	}
	name := args[0]
	setting := len(args) == 2
	value := setting ? args[1] : ""
	if s != nil &&
	   (name == "window_opacity" ||
			   name == "active_window_opacity" ||
			   name == "normal_window_opacity") {
		return failure("opacity settings are global")
	}
	switch name {
	case "tab_indicator_gap":
		if s != nil { return failure("tab_indicator_gap is global") }
		if !setting { return success(fmt.tprintf("%g", m.tab_indicator_gap)) }
		gap, ok := strconv.parse_f64(value)
		if !ok || math.is_nan(gap) || math.is_inf(gap) || gap < 0 || gap > 32 {
			return failure("tab_indicator_gap expects 0 through 32 logical pixels")
		}
		m.tab_indicator_gap = gap
	case "tab_indicator_width":
		if s != nil { return failure("tab_indicator_width is global") }
		if !setting { return success(fmt.tprintf("%g", m.tab_indicator_width)) }
		width, ok := strconv.parse_f64(value)
		if !ok || math.is_nan(width) || math.is_inf(width) || width < 1 || width > 32 {
			return failure("tab_indicator_width expects 1 through 32 logical pixels")
		}
		m.tab_indicator_width = width
		for space in m.spaces { space.view.tab_indicator_width = width }
	case "tab_indicator_active_color", "tab_indicator_inactive_color":
		if s != nil { return failure(fmt.tprintf("%s is global", name)) }
		target := name == "tab_indicator_active_color" ? &m.tab_indicator_active_color : &m.tab_indicator_inactive_color
		if !setting {
			if color, present := target^.?; present { return success(fmt.tprintf("0x%08x", color)) }
			return success("default")
		}
		if value == "default" {
			target^ = nil
		} else {
			if len(value) != 10 || !strings.has_prefix(value, "0x") {
				return failure(fmt.tprintf("%s expects default or 0xAARRGGBB", name))
			}
			color, ok := strconv.parse_u64(value[2:], 16)
			if !ok { return failure("invalid tab indicator color") }
			target^ = u32(color)
		}
	case "tab_indicator_position":
		if s != nil { return failure("tab_indicator_position is global") }
		if !setting { return success(m.tab_indicator_top ? "top" : "left") }
		if value != "top" && value != "left" {
			return failure("tab_indicator_position expects left or top")
		}
		m.tab_indicator_top = value == "top"
		for space in m.spaces { space.view.tab_indicator_top = m.tab_indicator_top }
	case "window_resize_animation":
		if s != nil {
			return failure("window_resize_animation is global")
		}
		if !setting {
			return success(m.resize_fade ? "fade" : "off")
		}
		if value != "fade" && value != "off" {
			return failure("window_resize_animation expects fade or off")
		}
		m.resize_fade = value == "fade"
	case "scroll_frame_pacing":
		if s != nil {
			return failure("scroll_frame_pacing is global")
		}
		if !setting {
			return success(m.scroll_frame_pacing ? "on" : "off")
		}
		if value != "on" && value != "off" {
			return failure("scroll_frame_pacing expects on or off")
		}
		m.scroll_frame_pacing = value == "on"
	case "scroll_animation":
		if s != nil {
			return failure("scroll_animation is global")
		}
		if !setting {
			return success(m.scroll_animate ? "on" : "off")
		}
		if value != "on" && value != "off" {
			return failure("scroll_animation expects on or off")
		}
		m.scroll_animate = value == "on"
	case "scroll_gestures",
	     "three_finger_horizontal",
	     "stack_swipe",
	     "scroll_drag_edge_scroll",
	     "scroll_drag_edge_width",
	     "scroll_drag_edge_delay",
	     "scroll_drag_edge_speed":
		return mouse_config(m, s, name, value, setting)
	case "scroll_center_focused_column",
	     "scroll_default_column_display",
	     "scroll_center_single_column",
	     "scroll_default_column_width",
	     "scroll_width_presets",
	     "scroll_height_presets",
	     "scroll_warp_pointer":
		return scroll_config(m, s, name, value, setting)
	case "focus_ring":
		if s != nil {
			return failure("focus_ring is global")
		}
		if !setting {
			return success(m.focus_ring.enabled ? "on" : "off")
		}
		if value != "on" && value != "off" {
			return failure("focus_ring expects on or off")
		}
		m.focus_ring.enabled = value == "on"
	case "focus_ring_width", "focus_ring_radius":
		if s != nil {
			return failure(fmt.tprintf("%s is global", name))
		}
		target :=
			name == "focus_ring_width" \
				? &m.focus_ring.width \
				: &m.focus_ring.radius
		if !setting {
			return success(fmt.tprintf("%g", target^))
		}
		width, valid := strconv.parse_f64(value)
		maximum := name == "focus_ring_width" ? f64(16) : f64(64)
		if !valid ||
		   math.is_nan(width) ||
		   math.is_inf(width) ||
		   width < 1 ||
		   width > maximum {
			return failure(
				fmt.tprintf(
					"%s expects 1 through %g logical pixels",
					name,
					maximum,
				),
			)
		}
		target^ = width
	case "insert_feedback_color", "focus_ring_color":
		if s != nil {
			return failure(fmt.tprintf("%s is global", name))
		}
		color_target :=
			name == "focus_ring_color" \
				? &m.focus_ring.color \
				: &m.feedback_color
		if !setting {
			return success(fmt.tprintf("0x%08x", color_target^))
		}
		if len(value) != 10 || !strings.has_prefix(value, "0x") {
			return failure(fmt.tprintf("%s expects 0xAARRGGBB", name))
		}
		color, valid := strconv.parse_u64(value[2:], 16)
		if !valid {
			return failure("invalid insert feedback color")
		}
		color_target^ = u32(color)
	case "external_bar":
		if s != nil {
			return failure("external_bar is global")
		}
		modes := [3]string{"off", "main", "all"}
		if !setting {
			return success(
				fmt.tprintf(
					"%s:%v:%v",
					modes[int(m.external_bar)],
					m.bar_top,
					m.bar_bottom,
				),
			)
		}
		parts := strings.split(value, ":", context.temp_allocator)
		values: [2]f64
		if len(parts) != 3 ||
		   !parse_numbers(
				   strings.join(parts[1:], ":", context.temp_allocator),
				   values[:],
			   ) ||
		   values[0] < 0 ||
		   values[1] < 0 ||
		   values[0] > 100000 ||
		   values[1] > 100000 {
			return failure("external_bar expects main|all|off:top:bottom")
		}
		switch parts[0] {case "off":
			m.external_bar = .Off; case "main":
			m.external_bar = .Main; case "all":
			m.external_bar = .All; case:
			return failure("invalid external_bar mode")
		}
		m.bar_top, m.bar_bottom = values[0], values[1]
		for space in m.spaces {
			if d := display_by_id(m, space.display); d != nil {
				space.view.frame = usable_frame(m, d)
			}
		}
	case "display_arrangement_order":
		if s != nil {
			return failure("display_arrangement_order is global")
		}
		modes := [3]string{"default", "vertical", "horizontal"}
		if !setting {
			return success(modes[int(m.display_order)])
		}
		switch value {case "default":
			m.display_order = .Default; case "vertical":
			m.display_order = .Vertical; case "horizontal":
			m.display_order = .Horizontal; case:
			return failure("invalid display arrangement")
		}
		order_displays(m)
	case "window_origin_display":
		if s != nil {
			return failure("window_origin_display is global")
		}
		modes := [3]string{"default", "focused", "cursor"}
		if !setting {
			return success(modes[int(m.origin_display)])
		}
		switch value {case "default":
			m.origin_display = .Default; case "focused":
			m.origin_display = .Focused; case "cursor":
			m.origin_display = .Cursor; case:
			return failure("invalid window origin display")
		}
	case "window_shadow":
		if s != nil {
			return failure("window_shadow is global")
		}
		modes := [3]string{"on", "off", "float"}
		if !setting {
			return success(modes[int(m.shadow_mode)])
		}
		previous := m.shadow_mode
		switch value {case "on":
			m.shadow_mode = .On; case "off":
			m.shadow_mode = .Off; case "float":
			m.shadow_mode = .Float; case:
			return failure("window_shadow expects on, off or float")
		}
		if err := apply_window_shadows(m); err != "" {
			m.shadow_mode = previous; apply_window_shadows(m)
			return failure(err)
		}
		m.shadow_configured = true
	case "window_animation_duration":
		if s != nil {
			return failure("animation duration is global")
		}
		if !setting {
			return success(fmt.tprintf("%v", m.animation_duration))
		}
		number, valid := strconv.parse_f64(value)
		if !valid ||
		   math.is_nan(number) ||
		   math.is_inf(number) ||
		   number < 0 ||
		   number > 3600 {
			return failure("invalid animation duration")
		}
		m.animation_duration = number
	case "window_animation_easing":
		if s != nil {
			return failure("animation easing is global")
		}
		if !setting {
			return success(EASING_NAMES[int(m.animation_easing)])
		}
		found := false
		for name, kind in EASING_NAMES {
			if value == name {
				m.animation_easing = Easing(kind); found = true; break
			}
		}
		if !found {
			return failure("unknown animation easing")
		}
	case "window_zoom_persist":
		if s != nil {
			return failure("window_zoom_persist is global")
		}
		if !setting {
			return success(m.zoom_persist ? "on" : "off")
		}
		if value != "on" && value != "off" {
			return failure("window_zoom_persist expects on or off")
		}
		m.zoom_persist = value == "on"
		for space in m.spaces { space.view.zoom_persist = m.zoom_persist }
	case "window_insertion_point":
		if s != nil {
			return failure("window_insertion_point is global")
		}
		if !setting {
			switch m.insertion_point {case .Focused:
				return success("focused"); case .First:
				return success("first"); case .Last:
				return success("last")
			}
		}
		switch value {case "focused":
			m.insertion_point = .Focused; case "first":
			m.insertion_point = .First; case "last":
			m.insertion_point = .Last; case:
			return failure("invalid insertion point")
		}
	case "mouse_modifier",
	     "mouse_action1",
	     "mouse_action2",
	     "mouse_drop_action",
	     "focus_follows_mouse",
	     "mouse_follows_focus":
		return mouse_config(m, s, name, value, setting)
	case "window_opacity":
		if !setting {
			return success(m.window_opacity ? "on" : "off")
		}
		if value != "on" && value != "off" {
			return failure("window_opacity expects on or off")
		}
		previous := m.window_opacity
		m.window_opacity = value == "on"
		if err := apply_window_opacity(m); err != "" {
			m.window_opacity = previous
			apply_window_opacity(m)
			return failure(err)
		}
	case "window_opacity_duration":
		if s != nil {
			return failure("opacity duration is global")
		}
		if !setting {
			return success(fmt.tprintf("%v", m.opacity_duration))
		}
		number, ok := strconv.parse_f64(value)
		if !ok ||
		   math.is_nan(number) ||
		   math.is_inf(number) ||
		   number < 0 ||
		   number > 3600 {
			return failure("invalid opacity duration")
		}
		m.opacity_duration = number
	case "active_window_opacity", "normal_window_opacity":
		p :=
			name == "active_window_opacity" \
				? &m.active_opacity \
				: &m.normal_opacity
		if !setting {
			return success(fmt.tprintf("%v", p^))
		}
		number, ok := strconv.parse_f64(value)
		if !ok ||
		   math.is_nan(number) ||
		   math.is_inf(number) ||
		   number < 0 ||
		   number > 1 {
			return failure("window opacity expects 0..1")
		}
		previous := p^
		p^ = number
		if err := apply_window_opacity(m); err != "" {
			p^ = previous
			apply_window_opacity(m)
			return failure(err)
		}
	case "layout":
		if !setting {
			return success(
				layout_name(s != nil ? s.view.layout : m.default_layout),
			)
		}
		layout, ok := parse_layout(value)
		if !ok {
			return failure("layout expects bsp, stack, scroll, or float")
		}
		if s == nil {
			m.default_layout = layout
			for space in m.spaces {
				if space.overrides[name] {
					continue
				}
				set_layout(m, space, layout)
			}
		} else {
			set_layout(m, s, layout)
		}
	case "window_gap",
	     "top_padding",
	     "bottom_padding",
	     "left_padding",
	     "right_padding",
	     "split_ratio":
		p: ^f64
		switch name {
		case "window_gap":
			p = s != nil ? &s.view.gap : &m.gap
		case "top_padding":
			p = s != nil ? &s.view.padding.top : &m.padding.top
		case "bottom_padding":
			p = s != nil ? &s.view.padding.bottom : &m.padding.bottom
		case "left_padding":
			p = s != nil ? &s.view.padding.left : &m.padding.left
		case "right_padding":
			p = s != nil ? &s.view.padding.right : &m.padding.right
		case "split_ratio":
			p = s != nil ? &s.view.ratio : &m.ratio
		}
		if !setting {
			return success(fmt.tprintf("%v", p^))
		}
		number, ok := strconv.parse_f64(value)
		if !ok ||
		   math.is_nan(number) ||
		   math.is_inf(number) ||
		   number < 0 ||
		   number > 100000 {
			return failure("invalid numeric setting")
		}
		if name == "split_ratio" && (number < 0.1 || number > 0.9) {
			return failure("split_ratio must be between 0.1 and 0.9")
		}
		p^ = number
		if s == nil {
			for space in m.spaces {
				if space.overrides[name] {
					continue
				}
				switch name {
				case "window_gap":
					space.view.gap = number
				case "top_padding":
					space.view.padding.top = number
				case "bottom_padding":
					space.view.padding.bottom = number
				case "left_padding":
					space.view.padding.left = number
				case "right_padding":
					space.view.padding.right = number
				case "split_ratio":
					space.view.ratio = number
				}
			}
		}
	case "auto_balance", "window_placement":
		p := name == "auto_balance" ? &m.auto_balance : &m.first_child
		if s != nil {
			p =
				name == "auto_balance" \
					? &s.view.auto_balance \
					: &s.view.first_child
		}
		yes, no := "on", "off"
		if name == "window_placement" {
			yes, no = "first_child", "second_child"
		}
		if !setting {
			if name == "auto_balance" && p^ {
				axis := s != nil ? s.view.balance_axis : m.balance_axis
				if axis == .Horizontal {
					return success("x-axis")
				}
				if axis == .Vertical {
					return success("y-axis")
				}
			}
			return success(p^ ? yes : no)
		}
		if value != yes &&
		   value != no &&
		   !(name == "auto_balance" &&
				   (value == "x-axis" || value == "y-axis")) {
			return failure(errorf("%s expects %s or %s", name, yes, no))
		}
		p^ = value != no
		axis :=
			value == "x-axis" \
				? Split.Horizontal \
				: (value == "y-axis" ? Split.Vertical : Split.Auto)
		if name == "auto_balance" {
			if s != nil {
				s.view.balance_axis = axis
			} else {
				m.balance_axis = axis
			}
		}
		if s == nil {
			for space in m.spaces {
				if space.overrides[name] {
					continue
				}
				if name == "auto_balance" {
					space.view.auto_balance = p^
					space.view.balance_axis = axis
				} else {
					space.view.first_child = p^
				}
			}
		}
	case "split_type":
		p := s != nil ? &s.view.split : &m.split
		names := [Split]string {
			.Auto       = "auto",
			.Vertical   = "vertical",
			.Horizontal = "horizontal",
		}
		if !setting {
			return success(names[p^])
		}
		valid := false
		for name, index in names {
			if name == value {
				p^ = Split(index)
				valid = true
			}
		}
		if !valid {
			return failure("split_type expects auto, vertical, or horizontal")
		}
		if s == nil {
			for space in m.spaces {
				if space.overrides[name] {
					continue
				}
				space.view.split = p^
			}
		}
	case:
		return failure(errorf("unsupported setting '%s'", name))
	}
	if s != nil {
		mark_space_override(s, name)
		return result(flush(m, s))
	}
	for space in m.spaces {
		if space.visible {
			if err := flush(m, space); err != "" {
				return failure(err)
			}
		}
	}
	return success()
}

mark_space_override :: proc(s: ^Space, name: string) {
	// IPC setting names borrow the request buffer; retain only static keys.
	for key in ([]string {
			"layout",
			"scroll_center_focused_column",
			"scroll_default_column_display",
			"scroll_center_single_column",
			"scroll_warp_pointer",
			"scroll_default_column_width",
			"scroll_width_presets",
			"scroll_height_presets",
			"window_gap",
			"top_padding",
			"bottom_padding",
			"left_padding",
			"right_padding",
			"split_ratio",
			"auto_balance",
			"window_placement",
			"split_type",
		}) {
		if key == name {
			s.overrides[key] = true; return
		}
	}
}

apply_window_opacity :: proc(m: ^Manager) -> string {
	for _, w in m.windows {
		if w.opacity_override {
			continue
		}
		desired :=
			m.window_opacity \
				? (w.id == m.focused ? m.active_opacity : m.normal_opacity) \
				: 1.0
		if w.opacity == desired {
			continue
		}
		if err := perform(
			m,
			Action {
				kind = .Opacity,
				window = w.id,
				value = desired,
				duration = m.opacity_duration,
			},
		); err != "" {
			return err
		}
		w.opacity = desired
	}
	return ""
}

// Display and window appearance settings
// ------------------------------------------------------------------------

usable_frame :: proc(m: ^Manager, d: ^Display) -> Rect {
	r := d.usable
	if m.external_bar == .All ||
	   (m.external_bar == .Main && d.id == m.main_display) {
		r.y += m.bar_top
		r.h = max(1, r.h - m.bar_top - m.bar_bottom)
	}
	return r
}

order_displays :: proc(m: ^Manager) {
	for i in 1 ..< len(m.displays) {
		for j := i; j > 0; j -= 1 {
			a, b := m.displays[j - 1], m.displays[j]
			ax, ay := a.frame.x + a.frame.w / 2, a.frame.y + a.frame.h / 2
			bx, by := b.frame.x + b.frame.w / 2, b.frame.y + b.frame.h / 2
			after := a.native_index > b.native_index
			switch m.display_order {
			case .Default:
			case .Vertical:
				after = ay > by || (ay == by && ax > bx)
			case .Horizontal:
				after = ax > bx || (ax == bx && ay > by)
			}
			if !after {
				break
			}
			m.displays[j - 1], m.displays[j] = b, a
		}
	}
	for &d, i in m.displays { d.index = u32(i + 1) }
}

apply_window_shadows :: proc(m: ^Manager) -> string {
	for _, w in m.windows {
		desired :=
			m.shadow_mode == .On || (m.shadow_mode == .Float && !managed(w))
		if w.shadow == desired {
			continue
		}
		if err := perform(m, {kind = .Shadow, window = w.id, flag = desired});
		   err != "" {
			return err
		}
		w.shadow = desired
	}
	return ""
}

apply_window_layers :: proc(m: ^Manager) -> string {
	for _, w in m.windows {
		if w.layer_override {
			continue
		}
		below := managed(w)
		// Accessory system panels must remain visible above document windows.
		above := !below && w.application_accessory && w.role == "AXWindow"
		desired := below ? "below" : (above ? "above" : "normal")
		if w.layer == desired {
			continue
		}
		if err := perform(
			m,
			{
				kind = .Layer,
				window = w.id,
				value = below ? -1 : (above ? 1 : 0),
			},
		); err != "" {
			return err
		}
		w.layer = desired
	}
	return ""
}

// Rules and signals
// ------------------------------------------------------------------------

Filter :: struct {
	pattern: string,
	expression: POSIX_Regex,
	enabled, exclude: bool,
}

Rule :: struct {
	label: string,
	app, title, role, subrole: Filter,
	manage: Maybe(bool),
	space: string,
	display, grid, scratchpad, sub_layer: string,
	opacity: Maybe(f64),
	sticky, native_fullscreen, mouse_follows_focus: Maybe(bool),
	one_shot: bool,
	pending_window: u32,
}

Signal :: struct {
	label, event, action: string,
	active: Maybe(bool),
	app, title: Filter,
}

rule_destroy :: proc(r: ^Rule) {
	delete(r.label)
	delete(r.space)
	delete(r.display); delete(r.grid); delete(r.scratchpad)
	delete(r.sub_layer)
	filter_destroy(&r.app)
	filter_destroy(&r.title)
	filter_destroy(&r.role)
	filter_destroy(&r.subrole)
}

signal_destroy :: proc(s: ^Signal) {
	delete(s.label)
	delete(s.event)
	delete(s.action)
	filter_destroy(&s.app)
	filter_destroy(&s.title)
}

rule_matches :: proc(r: Rule, w: ^Window) -> bool {
	return(
		filter_matches(r.app, w.app) &&
		filter_matches(r.title, w.title) &&
		filter_matches(r.role, w.role) &&
		filter_matches(r.subrole, w.subrole) \
	)
}

apply_rules :: proc(
	m: ^Manager,
	w: ^Window,
	existing: bool = false,
	selected: int = -1,
	initial: bool = false,
) -> (
	err: string,
) {
	previous_space := w.space
	was_pending := w.rules_pending
	defer {
		// Explicit reapply excludes one-shots and must not cancel a creation retry.
		if !existing {
			w.rules_pending = err != ""
		}
		if !existing || !was_pending || err != "" {
			delete(w.rule_error); w.rule_error = strings.clone(err)
		}
	}
	// Resolve precedence before issuing operations. A failed earlier destination
	// must not prevent a later management rule from taking effect.
	effects: Rule
	one_shots := make([dynamic]int, context.temp_allocator)
	matched := false
	for i in 0 ..< len(m.rules) {
		r := &m.rules[i]
		matches := rule_matches(r^, w)
		if r.pending_window == w.id && !matches {
			r.pending_window = 0
		}
		if (existing && r.one_shot) ||
		   (selected >= 0 && i != selected) ||
		   !matches ||
		   (r.one_shot && r.pending_window != 0 && r.pending_window != w.id) {
			continue
		}
		matched = true
		if r.manage != nil {
			effects.manage = r.manage
		}
		if r.opacity != nil {
			effects.opacity = r.opacity
		}
		if r.sticky != nil {
			effects.sticky = r.sticky
		}
		if r.native_fullscreen != nil {
			effects.native_fullscreen = r.native_fullscreen
		}
		if r.mouse_follows_focus != nil {
			effects.mouse_follows_focus = r.mouse_follows_focus
		}
		for pair in ([5][2]^string {
				{&effects.space, &r.space},
				{&effects.display, &r.display},
				{&effects.grid, &r.grid},
				{&effects.scratchpad, &r.scratchpad},
				{&effects.sub_layer, &r.sub_layer},
			}) {
			if pair[1]^ != "" {
				pair[0]^ = pair[1]^
			}
		}
		if r.one_shot {
			r.pending_window = w.id
			append(&one_shots, i)
		}
	}
	if !matched {
		return ""
	}
	if enabled, ok := effects.manage.?; ok {
		w.floating = !enabled; w.manage_override = enabled
		if !managed(w) {
			if s := space_by_id(m, w.space); s != nil {
				remove(&s.view, w.id)
			}
		}
	}
	if value, ok := effects.mouse_follows_focus.?; ok {
		w.mouse_follows_focus = value
	}
	err = apply_rule_effects(m, w, effects)
	// Even a partial backend failure can change management or destination.
	// Reconcile only those changes; unchanged membership keeps its original node.
	if !initial {
		if membership_error := sync_window_membership(m, w, previous_space);
		   membership_error != "" && membership_error != err {
			err =
				err == "" \
					? membership_error \
					: errorf("%s; %s", err, membership_error)
		}
	}
	if err != "" {
		return err
	}
	for i := len(one_shots) - 1; i >= 0; i -= 1 {
		index := one_shots[i]; rule_destroy(&m.rules[index])
		ordered_remove(&m.rules, index)
	}
	return ""
}

apply_rule_effects :: proc(m: ^Manager, w: ^Window, r: Rule) -> string {
	selector := fmt.tprintf("%d", w.id)
	target: ^Space
	follow := false
	if r.space != "" {
		text := r.space; follow = strings.has_prefix(text, "^"); if follow {
			text = text[1:]
		}
		target = select_space(m, text)
	} else if r.display != "" {
		text := r.display; follow = strings.has_prefix(text, "^"); if follow {
			text = text[1:]
		}
		if d := select_display(m, text); d != nil {
			target = space_by_id(m, d.active_space)
		}
	}
	if r.space != "" || r.display != "" {
		if target == nil {
			return "rule destination could not be located"
		}
		if target.id != w.space {
			if managed(w) &&
			   target.view.layout != .Float &&
			   !can_add(&target.view, m.focused) {
				return "rule destination tiling tree is full"
			}
			if err := perform(
				m,
				{kind = .Space, window = w.id, space = target.id},
			); err != "" {
				return err
			}
			w.space, w.display = target.id, target.display
		}
		if follow {
			if err := perform(m, {kind = .Space_Focus, space = target.id});
			   err != "" {
				return err
			}
		}
	}
	if value, ok := r.sticky.?; ok {
		if err := perform(m, {kind = .Sticky, window = w.id, flag = value});
		   err != "" {
			return err
		}
		w.sticky = value
	}
	if value, ok := r.opacity.?; ok {
		if response := window_command(
			m,
			[]string{selector, "--opacity", fmt.tprintf("%v", value)},
		); response.failed {
			return response.text
		}
	}
	if r.sub_layer != "" {
		if response := window_command(
			m,
			[]string{selector, "--sub-layer", r.sub_layer},
		); response.failed {
			return response.text
		}
	}
	if r.scratchpad != "" && scratchpad_by_label(m, r.scratchpad) == nil {
		if err := scratchpad_assign(m, w, r.scratchpad); err != "" {
			return err
		}
	}
	if r.grid != "" {
		if response := window_command(m, []string{selector, "--grid", r.grid});
		   response.failed {
			return response.text
		}
	}
	if value, ok := r.native_fullscreen.?; ok {
		if err := perform(
			m,
			{kind = .Fullscreen, window = w.id, flag = value},
		); err != "" {
			return err
		}
		w.fullscreen = value
	}
	if value, ok := r.mouse_follows_focus.?; ok {
		w.mouse_follows_focus = value
	}
	return ""
}

assignment :: proc(arg: string) -> (key, value: string, exclude, ok: bool) {
	at := strings.index_byte(arg, '=')
	if at < 1 {
		return
	}
	key, value = arg[:at], arg[at + 1:]
	if strings.has_suffix(key, "!") {
		key = key[:len(key) - 1]
		exclude = true
	}
	ok = true
	return
}

parse_rule :: proc(args: []string) -> (rule: Rule, err: string) {
	for arg in args {
		if arg == "--one-shot" {
			rule.one_shot = true; continue
		}
		key, value, exclude, ok := assignment(arg)
		if !ok {
			err = "expected key=value"
			break
		}
		f: ^Filter
		switch key {
		case "app":
			f = &rule.app
		case "title":
			f = &rule.title
		case "role":
			f = &rule.role
		case "subrole":
			f = &rule.subrole
		case "label":
			delete(rule.label)
			rule.label = strings.clone(value)
		case "space":
			delete(rule.space)
			rule.space = strings.clone(value)
		case "display", "grid", "scratchpad", "sub-layer":
			p := &rule.display
			switch key {
			case "grid":
				p = &rule.grid
			case "scratchpad":
				p = &rule.scratchpad
			case "sub-layer":
				p = &rule.sub_layer
			}
			delete(p^); p^ = strings.clone(value)
			if key == "sub-layer" &&
			   value != "below" &&
			   value != "normal" &&
			   value != "above" &&
			   value != "auto" {
				err = "invalid rule sub-layer"
			}
			if key == "grid" {
				values: [6]f64
				if !parse_numbers(value, values[:]) ||
				   values[0] <= 0 ||
				   values[1] <= 0 ||
				   values[2] < 0 ||
				   values[3] < 0 ||
				   values[4] <= 0 ||
				   values[5] <= 0 ||
				   values[2] + values[4] > values[1] ||
				   values[3] + values[5] > values[0] {
					err = "invalid rule grid"
				}
			}
		case "opacity":
			number, valid := strconv.parse_f64(value)
			if !valid ||
			   math.is_nan(number) ||
			   math.is_inf(number) ||
			   number < 0 ||
			   number > 1 {
				err = "invalid rule opacity"
			} else {
				rule.opacity = number
			}
		case "sticky", "native-fullscreen", "mouse_follows_focus":
			p := &rule.sticky
			if key == "native-fullscreen" {
				p = &rule.native_fullscreen
			}
			if key == "mouse_follows_focus" {
				p = &rule.mouse_follows_focus
			}
			if value != "on" && value != "off" {
				err = "rule boolean expects on or off"
			} else {
				p^ = value == "on"
			}
		case "manage":
			if value != "on" && value != "off" {
				err = "manage expects on or off"
			} else {
				rule.manage = value == "on"
			}
		case "one-shot":
			if value != "on" && value != "off" {
				err = "one-shot expects on or off"
			} else {
				rule.one_shot = value == "on"
			}
		case:
			err = errorf("unsupported rule property '%s'", key)
		}
		if f != nil && !filter_set(f, value, exclude) {
			err = errorf("invalid regular expression '%s'", value)
		}
		if err != "" {
			break
		}
	}
	if err != "" {
		rule_destroy(&rule)
		rule = {}
	}
	return
}

SIGNAL_EVENTS :: []string {
	"application_launched",
	"application_terminated",
	"application_front_switched",
	"application_activated",
	"application_deactivated",
	"application_visible",
	"application_hidden",
	"window_created",
	"window_destroyed",
	"window_focused",
	"window_moved",
	"window_resized",
	"window_minimized",
	"window_deminimized",
	"window_title_changed",
	"space_created",
	"space_destroyed",
	"space_changed",
	"display_added",
	"display_removed",
	"display_moved",
	"display_resized",
	"display_changed",
	"mission_control_enter",
	"mission_control_exit",
	"dock_did_change_pref",
	"dock_did_restart",
	"menu_bar_hidden_changed",
	"system_woke",
}

parse_signal :: proc(args: []string) -> (s: Signal, err: string) {
	for arg in args {
		key, value, exclude, ok := assignment(arg)
		if !ok {
			err = "expected key=value"
			break
		}
		switch key {
		case "active":
			if value != "yes" && value != "no" {
				err = "active expects yes or no"
			} else {
				s.active = value == "yes"
			}
		case "label":
			delete(s.label)
			s.label = strings.clone(value)
		case "event":
			delete(s.event)
			s.event = strings.clone(value)
		case "action":
			delete(s.action)
			s.action = strings.clone(value)
		case "app":
			if !filter_set(&s.app, value, exclude) {
				err = "invalid app regex"
			}
		case "title":
			if !filter_set(&s.title, value, exclude) {
				err = "invalid title regex"
			}
		case:
			err = errorf("unsupported signal property '%s'", key)
		}
		if err != "" {
			break
		}
	}
	known := false
	for event in SIGNAL_EVENTS {
		if event == s.event {
			known = true
			break
		}
	}
	if !known {
		err = "unknown signal event"
	}
	if s.action == "" {
		err = "signal requires action"
	}
	if err != "" {
		signal_destroy(&s)
		s = {}
	}
	return
}

remove_rule :: proc(m: ^Manager, selector: string) -> bool {
	index, numeric := strconv.parse_int(selector)
	for &r, i in m.rules {
		if (numeric && i == index) || (!numeric && r.label == selector) {
			rule_destroy(&r)
			ordered_remove(&m.rules, i)
			return true
		}
	}
	return false
}

remove_signal :: proc(m: ^Manager, selector: string) -> bool {
	index, numeric := strconv.parse_int(selector)
	for &s, i in m.signals {
		if (numeric && i == index) || (!numeric && s.label == selector) {
			signal_destroy(&s)
			ordered_remove(&m.signals, i)
			return true
		}
	}
	return false
}

// Rule and signal commands
// ------------------------------------------------------------------------

rule_command :: proc(m: ^Manager, args: []string) -> Response {
	if len(args) == 0 {
		return failure("missing rule operation")
	}
	switch args[0] {
	case "--add":
		if len(args) < 2 {
			return failure("missing rule properties")
		}
		r, err := parse_rule(args[1:])
		if err != "" {
			return failure(err)
		}
		if r.label != "" {
			remove_rule(m, r.label)
		}
		append(&m.rules, r)
		return success()
	case "--remove":
		if len(args) != 2 {
			return failure("remove requires index or label")
		}
		if !remove_rule(m, args[1]) {
			return failure("rule not found")
		}
		return success()
	case "--list":
		Item :: struct {
			index: int,
			label, app, title, role, subrole: string,
			manage: Maybe(bool),
			space: string,
			display, grid, scratchpad: string,
			sub_layer: string `json:"sub-layer"`,
			opacity: Maybe(f64),
			sticky, mouse_follows_focus: Maybe(bool),
			native_fullscreen: Maybe(bool) `json:"native-fullscreen"`,
			one_shot: bool `json:"one-shot"`,
		}
		items := make([dynamic]Item, 0, len(m.rules), context.temp_allocator)
		for r, i in m.rules {
			append(
				&items,
				Item {
					i,
					r.label,
					r.app.pattern,
					r.title.pattern,
					r.role.pattern,
					r.subrole.pattern,
					r.manage,
					r.space,
					r.display,
					r.grid,
					r.scratchpad,
					r.sub_layer,
					r.opacity,
					r.sticky,
					r.mouse_follows_focus,
					r.native_fullscreen,
					r.one_shot,
				},
			)
		}
		return success(json_text(items))
	case "--apply":
		selected := -1
		temporary := false
		defer {
			if temporary {
				rule_destroy(&m.rules[selected])
				ordered_remove(&m.rules, selected)
			}
		}
		if len(args) > 1 {
			if strings.contains(args[1], "=") {
				rule, err := parse_rule(args[1:])
				if err != "" {
					return failure(err)
				}
				selected = len(m.rules)
				append(&m.rules, rule)
				temporary = true
			} else {
				if len(args) != 2 {
					return failure(
						"apply expects a rule selector or properties",
					)
				}
				index, numeric := strconv.parse_int(args[1])
				for rule, i in m.rules {
					if (numeric && i == index) ||
					   (!numeric && rule.label == args[1]) {
						selected = i; break
					}
				}
				if selected < 0 {
					return failure("rule not found")
				}
			}
		}
		for _, w in m.windows {
			if err := apply_rule_to_window(m, w, selected); err != "" {
				return failure(err)
			}
		}
		for s in m.spaces {
			if s.visible {
				if err := flush(m, s); err != "" {
					return failure(err)
				}
			}
		}
		return success()
	}
	return failure("unknown rule operation")
}

apply_rule_to_window :: proc(
	m: ^Manager,
	w: ^Window,
	selected: int = -1,
) -> string {
	return apply_rules(m, w, existing = true, selected = selected)
}

signal_command :: proc(m: ^Manager, args: []string) -> Response {
	if len(args) == 0 {
		return failure("missing signal operation")
	}
	switch args[0] {
	case "--add":
		s, err := parse_signal(args[1:])
		if err != "" {
			return failure(err)
		}
		if s.label != "" {
			remove_signal(m, s.label)
		}
		append(&m.signals, s)
		return success()
	case "--remove":
		if len(args) != 2 {
			return failure("remove requires index or label")
		}
		if !remove_signal(m, args[1]) {
			return failure("signal not found")
		}
		return success()
	case "--list":
		Item :: struct {
			index: int,
			label, event, action, app, title: string,
			active: Maybe(bool),
		}
		items := make([dynamic]Item, 0, len(m.signals), context.temp_allocator)
		for s, i in m.signals {
			append(
				&items,
				Item {
					i,
					s.label,
					s.event,
					s.action,
					s.app.pattern,
					s.title.pattern,
					s.active,
				},
			)
		}
		return success(json_text(items))
	}
	return failure("unknown signal operation")
}

// Darwin regular expressions
// ------------------------------------------------------------------------

// Darwin regex_t's public ABI; compiled expressions remain owned by libSystem.
// Matching uses the same REG_EXTENDED grammar as yabai.
POSIX_Regex :: struct {
	magic: i32,
	subexpressions: uint,
	end: cstring,
	guts: rawptr,
}
@(default_calling_convention = "c")
foreign libc {
	regcomp :: proc(expression: ^POSIX_Regex, pattern: cstring, flags: i32) -> i32 ---
	regexec :: proc(expression: ^POSIX_Regex, text: cstring, count: uint, matches: rawptr, flags: i32) -> i32 ---
	regfree :: proc(expression: ^POSIX_Regex) ---
}

filter_destroy :: proc(f: ^Filter) {
	if f.enabled {
		regfree(&f.expression)
	}
	delete(f.pattern)
	f^ = {}
}

filter_set :: proc(f: ^Filter, pattern: string, exclude: bool) -> bool {
	if strings.contains(pattern, "\x00") {
		return false
	}
	expression: POSIX_Regex
	if regcomp(
		   &expression,
		   strings.clone_to_cstring(pattern, context.temp_allocator),
		   1,
	   ) !=
	   0 {
		return false
	}
	filter_destroy(f)
	f^ = Filter{strings.clone(pattern), expression, true, exclude}
	return true
}

filter_matches :: proc(f: Filter, text: string) -> bool {
	if !f.enabled {
		return true
	}
	expression := f.expression
	matched :=
		regexec(
			&expression,
			strings.clone_to_cstring(text, context.temp_allocator),
			0,
			nil,
			0,
		) ==
		0
	return matched != f.exclude
}
