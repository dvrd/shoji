package engine

import "core:strings"

display_command :: proc(m: ^Manager, args: []string) -> Response {
	args := args
	selector := ""
	if len(args) > 0 && !strings.has_prefix(args[0], "--") {
		selector = args[0]
		args = args[1:]
	}
	if len(args) != 2 {
		return failure("display expects --focus selector or --label label")
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
		d.label = strings.clone(args[1])
		return success()
	}
	if args[0] == "--focus" {
		return result(perform(m, Action{kind = .Space_Focus, space = d.active_space}))
	}
	return failure("unsupported display operation")
}
