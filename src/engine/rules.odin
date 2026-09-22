package engine

import "core:strconv"
import "core:strings"

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
	one_shot: bool,
}

Signal :: struct {
	label, event, action: string,
	active: Maybe(bool),
	app, title: Filter,
}

rule_destroy :: proc(r: ^Rule) {
	delete(r.label)
	delete(r.space)
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

apply_rules :: proc(m: ^Manager, w: ^Window) {
	for i := 0; i < len(m.rules); {
		r := &m.rules[i]
		if !rule_matches(r^, w) {
			i += 1
			continue
		}
		if enabled, ok := r.manage.?; ok {
			w.floating = !enabled
			w.manage_override = enabled
		}
		if r.space != "" {
			if s := select_space(m, r.space); s != nil {
				if perform(m, Action{kind = .Space, window = w.id, space = s.id}) == "" {
					w.space = s.id
					w.display = s.display
				}
			}
		}
		if r.one_shot {
			rule_destroy(r)
			ordered_remove(&m.rules, i)
		} else {
			i += 1
		}
	}
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
