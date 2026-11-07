package shoji

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import layout "layout"

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
	case "windowserver_gate":
		if s != nil { return failure("windowserver_gate is global") }
		if m.ws_gate_control == nil {
			return failure("windowserver_gate needs the daemon")
		}
		if setting && value != "on" && value != "off" {
			return failure("windowserver_gate expects on or off")
		}
		return m.ws_gate_control(m.ws_gate_user, value)
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
				? layout.Split.Horizontal \
				: (value == "y-axis" ? layout.Split.Vertical : layout.Split.Auto)
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
		names := [layout.Split]string {
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
				p^ = layout.Split(index)
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
