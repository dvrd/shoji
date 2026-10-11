package engine

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

Filter :: struct {
	pattern:          string,
	expression:       POSIX_Regex,
	enabled, exclude: bool,
}

Rule :: struct {
	label:                                          string,
	app, title, role, subrole:                      Filter,
	manage:                                         Maybe(bool),
	space:                                          string,
	display, grid, scratchpad, sub_layer:           string,
	opacity:                                        Maybe(f64),
	sticky, native_fullscreen, mouse_follows_focus: Maybe(bool),
	one_shot:                                       bool,
}

Signal :: struct {
	label, event, action: string,
	active:               Maybe(bool),
	app, title:           Filter,
}

rule_destroy :: proc(r: ^Rule) {
	delete(r.label)
	delete(r.space)
	delete(r.display);delete(r.grid);delete(r.scratchpad);delete(r.sub_layer)
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
) -> string {
	for i := 0; i < len(m.rules); {
		r := &m.rules[i]
		if (existing && r.one_shot) || (selected >= 0 && i != selected) || !rule_matches(r^, w) {
			i += 1
			continue
		}
		if enabled, ok := r.manage.?; ok {
			w.floating = !enabled
			w.manage_override = enabled
		}
		if err := apply_rule_effects(m, w, r^); err != "" {return err}
		if r.one_shot {
			rule_destroy(r)
			ordered_remove(&m.rules, i)
		} else {
			i += 1
		}
	}
	return ""
}

apply_rule_effects :: proc(m: ^Manager, w: ^Window, r: Rule) -> string {
	selector := fmt.tprintf("%d", w.id)
	target: ^Space
	follow := false
	if r.space != "" {
		text := r.space;follow = strings.has_prefix(text, "^");if follow {text = text[1:]}
		target = select_space(m, text)
	} else if r.display != "" {
		text := r.display;follow = strings.has_prefix(text, "^");if follow {text = text[1:]}
		if d := select_display(m, text); d != nil {target = space_by_id(m, d.active_space)}
	}
	if r.space != "" || r.display != "" {
		if target == nil {return "rule destination could not be located"}
		if err := perform(m, {kind = .Space, window = w.id, space = target.id});
		   err != "" {return err}
		w.space, w.display = target.id, target.display
		if follow {if err := perform(m, {kind = .Space_Focus, space = target.id}); err != "" {return err}}
	}
	if value, ok := r.sticky.?; ok {
		if err := perform(m, {kind = .Sticky, window = w.id, flag = value}); err != "" {return err}
		w.sticky = value
	}
	if value, ok := r.opacity.?; ok {
		if response := window_command(
			m,
			[]string{selector, "--opacity", fmt.tprintf("%v", value)},
		); response.failed {return response.text}
	}
	if r.sub_layer != "" {
		if response := window_command(m, []string{selector, "--sub-layer", r.sub_layer});
		   response.failed {return response.text}
	}
	if r.scratchpad != "" && scratchpad_by_label(m, r.scratchpad) == nil {
		if err := scratchpad_assign(m, w, r.scratchpad); err != "" {return err}
	}
	if r.grid != "" {
		if response := window_command(m, []string{selector, "--grid", r.grid});
		   response.failed {return response.text}
	}
	if value, ok := r.native_fullscreen.?; ok {
		if err := perform(m, {kind = .Fullscreen, window = w.id, flag = value});
		   err != "" {return err}
		w.fullscreen = value
	}
	if value, ok := r.mouse_follows_focus.?; ok {w.mouse_follows_focus = value}
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
		if arg == "--one-shot" {rule.one_shot = true;continue}
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
			delete(p^);p^ = strings.clone(value)
			if key == "sub-layer" &&
			   value != "below" &&
			   value != "normal" &&
			   value != "above" &&
			   value != "auto" {err = "invalid rule sub-layer"}
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
				   values[3] + values[5] > values[0] {err = "invalid rule grid"}
			}
		case "opacity":
			number, valid := strconv.parse_f64(value)
			if !valid ||
			   math.is_nan(number) ||
			   math.is_inf(number) ||
			   number < 0 ||
			   number > 1 {err = "invalid rule opacity"} else {rule.opacity = number}
		case "sticky", "native-fullscreen", "mouse_follows_focus":
			p := &rule.sticky
			if key == "native-fullscreen" {p = &rule.native_fullscreen}
			if key == "mouse_follows_focus" {p = &rule.mouse_follows_focus}
			if value != "on" &&
			   value != "off" {err = "rule boolean expects on or off"} else {p^ = value == "on"}
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
