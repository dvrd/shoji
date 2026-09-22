package engine

import "core:math"
import "core:strconv"
import "core:strings"

space_command :: proc(m: ^Manager, args: []string) -> Response {
	args := args
	selector := ""
	if len(args) > 0 && !strings.has_prefix(args[0], "--") {
		selector = args[0]
		args = args[1:]
	}
	if len(args) == 0 || len(args) > 2 {
		return failure("expected space operation and optional operand")
	}
	s := select_space(m, selector)
	op := args[0]
	operand := len(args) > 1 ? args[1] : ""
	if op == "--focus" && operand != "" {
		s = select_space(m, operand)
	}
	if s == nil {
		return failure("could not locate space")
	}
	switch op {
	case "--layout":
		layout, ok := parse_layout(operand)
		if !ok {
			return failure("invalid layout")
		}
		set_layout(m, s, layout)
	case "--rotate":
		angle, ok := strconv.parse_int(operand)
		if !ok || (angle != 90 && angle != 180 && angle != 270) {
			return failure("rotate expects 90, 180, or 270")
		}
		rotate(s.view.root, angle)
	case "--mirror":
		if operand != "x-axis" && operand != "y-axis" {
			return failure("mirror expects x-axis or y-axis")
		}
		mirror(s.view.root, operand == "x-axis" ? .Horizontal : .Vertical)
	case "--balance", "--equalize":
		axis: Split
		switch operand {
		case "", "both":
			axis = .Auto
		case "x-axis":
			axis = .Horizontal
		case "y-axis":
			axis = .Vertical
		case:
			return failure("invalid axis")
		}
		if op == "--balance" {
			balance(s.view.root, axis)
		} else {
			equalize(s.view.root, axis, s.view.ratio)
		}
	case "--label":
		delete(s.label)
		s.label = strings.clone(operand)
	case "--toggle":
		switch operand {
		case "padding":
			s.view.padding_enabled = !s.view.padding_enabled
		case "gap":
			s.view.gap_enabled = !s.view.gap_enabled
		case:
			return failure("toggle expects padding or gap")
		}
	case "--padding":
		parts := strings.split(operand, ":", context.temp_allocator)
		values: [4]f64
		if len(parts) != 5 ||
		   !parse_numbers(strings.join(parts[1:], ":", context.temp_allocator), values[:]) {
			return failure("padding expects abs|rel:top:bottom:left:right")
		}
		p := Padding{values[0], values[1], values[2], values[3]}
		if parts[0] == "rel" {
			p.top += s.view.padding.top
			p.bottom += s.view.padding.bottom
			p.left += s.view.padding.left
			p.right += s.view.padding.right
		} else if parts[0] != "abs" {
			return failure("invalid padding mode")
		}
		if min(p.top, p.bottom, p.left, p.right) < 0 {
			return failure("padding cannot be negative")
		}
		s.view.padding = p
	case "--gap":
		parts := strings.split(operand, ":", context.temp_allocator)
		if len(parts) != 2 {
			return failure("gap expects abs:value or rel:value")
		}
		value, ok := strconv.parse_f64(parts[1])
		if !ok || math.is_nan(value) || math.is_inf(value) {
			return failure("invalid gap")
		}
		if parts[0] == "rel" {
			value += s.view.gap
		} else if parts[0] != "abs" {
			return failure("invalid gap mode")
		}
		if value < 0 {
			return failure("gap cannot be negative")
		}
		s.view.gap = value
	case "--focus":
		return result(perform(m, Action{kind = .Space_Focus, space = s.id}))
	case "--create":
		return result(perform(m, Action{kind = .Space_Create, space = s.id}))
	case "--destroy":
		return result(perform(m, Action{kind = .Space_Destroy, space = s.id}))
	case "--move":
		target := select_space(m, operand)
		if target == nil {
			return failure("could not locate target space")
		}
		return result(
			perform(m, Action{kind = .Space_Move, space = s.id, destination = target.id}),
		)
	case:
		return failure(errorf("unsupported space operation '%s'", op))
	}
	return result(flush(m, s))
}
