package engine

import "core:strings"

display_command :: proc(m: ^Manager, args: []string) -> Response {
	args := args
	selector := ""
	if len(args) > 0 && !strings.has_prefix(args[0], "--") {
		selector = args[0]
		args = args[1:]
	}
	if len(args) < 1 || len(args) > 2 || (args[0] != "--label" && len(args) != 2) {
		return failure("display expects --focus selector, --space selector, or --label [label]")
	}
	if args[0] == "--focus" {
		selector = args[1]
	}
	d := select_display(m, selector)
	if d == nil {
		return failure("could not locate display")
	}
	if args[0] == "--label" {
		delete(d.label)
		d.label = len(args) == 2 ? strings.clone(args[1]) : ""
		return success()
	}
	if args[0] == "--space" {
		s := select_space(m, args[1])
		if s == nil {return failure("could not locate space")}
		if s.display != d.id {return failure("space must belong to the selected display")}
		return result(perform(m, Action{kind = .Space_Focus, space = s.id}))
	}
	if args[0] == "--focus" {
		return result(
			perform(m, Action{kind = .Display_Focus, display = d.id, space = d.active_space}),
		)
	}
	return failure("unsupported display operation")
}
