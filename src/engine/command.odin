package engine

import "core:math"
import "core:strconv"
import "core:strings"

Response :: struct {
	text: string,
	failed: bool,
}

success :: proc(text: string = "") -> Response {
	return {text, false}
}

failure :: proc(text: string) -> Response {
	return {text, true}
}

result :: proc(err: string) -> Response {
	return {err, err != ""}
}

layout_name :: proc(layout: Layout) -> string {
	switch layout {
	case .BSP:
		return "bsp"
	case .Stack:
		return "stack"
	case .Float:
		return "float"
	}
	return "float"
}

parse_layout :: proc(text: string) -> (Layout, bool) {
	switch text {
	case "bsp":
		return .BSP, true
	case "stack":
		return .Stack, true
	case "float":
		return .Float, true
	}
	return .Float, false
}

parse_numbers :: proc(text: string, values: []f64) -> bool {
	parts := strings.split(text, ":", context.temp_allocator)
	if len(parts) != len(values) {
		return false
	}
	for part, i in parts {
		value, ok := strconv.parse_f64(part)
		if !ok || math.is_nan(value) || math.is_inf(value) {
			return false
		}
		values[i] = value
	}
	return true
}

select_display :: proc(m: ^Manager, text: string) -> ^Display {
	current := space_by_id(m, m.active_space)
	if text == "" {
		if current != nil {
			return display_by_id(m, current.display)
		}
		return nil
	}
	if text == "first" && len(m.displays) > 0 {
		return &m.displays[0]
	}
	if text == "last" && len(m.displays) > 0 {
		return &m.displays[len(m.displays) - 1]
	}
	number, numeric := strconv.parse_u64(text)
	for &d, i in m.displays {
		if (numeric && u64(d.index) == number) || d.label == text {
			return &d
		}
		if current != nil && d.id == current.display && (text == "next" || text == "prev") {
			j := text == "next" ? i + 1 : i - 1
			if j >= 0 && j < len(m.displays) {
				return &m.displays[j]
			}
		}
	}
	return nil
}

execute :: proc(m: ^Manager, args: []string) -> Response {
	if len(args) == 0 {
		return failure("missing command domain")
	}
	switch args[0] {
	case "query":
		return query(m, args[1:])
	case "config":
		return config(m, args[1:])
	case "window":
		return window_command(m, args[1:])
	case "space":
		return space_command(m, args[1:])
	case "display":
		return display_command(m, args[1:])
	case "rule":
		return rule_command(m, args[1:])
	case "signal":
		return signal_command(m, args[1:])
	}
	return failure(errorf("unknown command domain '%s'", args[0]))
}
