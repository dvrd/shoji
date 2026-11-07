package shoji

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

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
