package engine

import "core:fmt"
import "core:math"
import "core:strconv"

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
	switch name {
	case "mouse_modifier",
	     "mouse_action1",
	     "mouse_action2",
	     "mouse_drop_action",
	     "focus_follows_mouse",
	     "mouse_follows_focus":
		return mouse_config(m, s, name, value, setting)
	case "layout":
		if !setting {
			return success(layout_name(s != nil ? s.view.layout : m.default_layout))
		}
		layout, ok := parse_layout(value)
		if !ok {
			return failure("layout expects bsp, stack, or float")
		}
		if s == nil {
			m.default_layout = layout
			for space in m.spaces {
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
		if !ok || math.is_nan(number) || math.is_inf(number) || number < 0 || number > 100000 {
			return failure("invalid numeric setting")
		}
		if name == "split_ratio" && (number < 0.1 || number > 0.9) {
			return failure("split_ratio must be between 0.1 and 0.9")
		}
		p^ = number
		if s == nil {
			for space in m.spaces {
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
			p = name == "auto_balance" ? &s.view.auto_balance : &s.view.first_child
		}
		yes, no := "on", "off"
		if name == "window_placement" {
			yes, no = "first_child", "second_child"
		}
		if !setting {
			return success(p^ ? yes : no)
		}
		if value != yes && value != no {
			return failure(errorf("%s expects %s or %s", name, yes, no))
		}
		p^ = value == yes
		if s == nil {
			for space in m.spaces {
				if name == "auto_balance" {
					space.view.auto_balance = p^
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
				space.view.split = p^
			}
		}
	case:
		return failure(errorf("unsupported setting '%s'", name))
	}
	if s != nil {
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
