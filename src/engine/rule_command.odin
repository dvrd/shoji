package engine

import "core:strconv"
import "core:strings"

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
			index:                            int,
			label, app, title, role, subrole: string,
			manage:                           Maybe(bool),
			space:                            string,
			display, grid, scratchpad:        string,
			sub_layer:                        string `json:"sub-layer"`,
			opacity:                          Maybe(f64),
			sticky, mouse_follows_focus:      Maybe(bool),
			native_fullscreen:                Maybe(bool) `json:"native-fullscreen"`,
			one_shot:                         bool `json:"one-shot"`,
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
			if temporary {rule_destroy(&m.rules[selected]);ordered_remove(&m.rules, selected)}
		}
		if len(args) > 1 {
			if strings.contains(args[1], "=") {
				rule, err := parse_rule(args[1:])
				if err != "" {return failure(err)}
				selected = len(m.rules)
				append(&m.rules, rule)
				temporary = true
			} else {
				if len(args) != 2 {return failure("apply expects a rule selector or properties")}
				index, numeric := strconv.parse_int(args[1])
				for rule, i in m.rules {
					if (numeric && i == index) ||
					   (!numeric && rule.label == args[1]) {selected = i;break}
				}
				if selected < 0 {return failure("rule not found")}
			}
		}
		for _, w in m.windows {if err := apply_rule_to_window(m, w, selected); err != "" {return failure(err)}}
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

apply_rule_to_window :: proc(m: ^Manager, w: ^Window, selected: int = -1) -> string {
	if s := space_by_id(m, w.space); s != nil {
		remove(&s.view, w.id)
	}
	err := apply_rules(m, w, existing = true, selected = selected)
	if s := space_by_id(m, w.space); s != nil && managed(w) {
		add(&s.view, w.id)
	}
	return err
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
			index:                            int,
			label, event, action, app, title: string,
			active:                           Maybe(bool),
		}
		items := make([dynamic]Item, 0, len(m.signals), context.temp_allocator)
		for s, i in m.signals {
			append(
				&items,
				Item{i, s.label, s.event, s.action, s.app.pattern, s.title.pattern, s.active},
			)
		}
		return success(json_text(items))
	}
	return failure("unknown signal operation")
}
