package engine


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
				},
			)
		}
		return success(json_text(items))
	case "--apply":
		if len(args) > 1 {
			return failure("selective rule apply is not implemented")
		}
		for _, w in m.windows {
			if s := space_by_id(m, w.space); s != nil {
				remove(&s.view, w.id)
			}
			apply_rules(m, w)
			if s := space_by_id(m, w.space); s != nil && managed(w) {
				add(&s.view, w.id)
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
		}
		items := make([dynamic]Item, 0, len(m.signals), context.temp_allocator)
		for s, i in m.signals {
			append(&items, Item{i, s.label, s.event, s.action, s.app.pattern, s.title.pattern})
		}
		return success(json_text(items))
	}
	return failure("unknown signal operation")
}
