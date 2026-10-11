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
	if op == "--destroy" && operand != "" {s = select_space(m, operand)}
	if op == "--create" && operand != "" {
		if d := select_display(m, operand);
		   d !=
		   nil {s = space_by_id(m, d.active_space)} else {return failure("could not locate display")}
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
		s.overrides["layout"] = true
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
		for key in ([]string {
				"top_padding",
				"bottom_padding",
				"left_padding",
				"right_padding",
			}) {s.overrides[key] = true}
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
		s.overrides["window_gap"] = true
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
		if s == target {return success()}
		if s.display !=
		   target.display {return failure("space --move requires the same display; use --display")}
		if s.fullscreen ||
		   target.fullscreen {return failure("cannot reorder native fullscreen spaces")}
		if s.index < target.index {return result(move_space_after(m, s, target))}
		previous := previous_space_on_display(m, target)
		if previous != nil {return result(move_space_after(m, s, previous))}
		if err := move_space_after(m, s, target); err != "" {return failure(err)}
		return result(move_space_after(m, target, s))
	case "--swap", "--switch":
		target := select_space(m, operand)
		if op == "--switch" {s = select_space(m, "")}
		if target == nil || s == nil {return failure("could not locate target space")}
		if s == target {return success()}
		if s.fullscreen ||
		   target.fullscreen {return failure("cannot swap native fullscreen spaces")}
		if op == "--switch" &&
		   s.display ==
			   target.display {return result(perform(m, {kind = .Space_Focus, space = target.id}))}
		if s.display != target.display {
			if err := swap_space_windows(m, s, target); err != "" {return failure(err)}
		} else {
			earlier, later := s, target
			if earlier.index > later.index {earlier, later = later, earlier}
			previous := previous_space_on_display(m, later)
			if previous == earlier {previous = later}
			if err := move_space_after(m, later, earlier); err != "" {return failure(err)}
			if err := move_space_after(m, earlier, previous); err != "" {return failure(err)}
		}
		if op == "--switch" {return result(perform(m, {kind = .Space_Focus, space = target.id}))}
		return success()
	case "--display":
		d := select_display(m, operand)
		if d == nil {return failure("could not locate display")}
		if s.display == d.id {return success()}
		if s.fullscreen {return failure("cannot move a native fullscreen space")}
		return result(perform(m, {kind = .Space_Move, space = s.id, destination = d.active_space}))
	case:
		return failure(errorf("unsupported space operation '%s'", op))
	}
	return result(flush(m, s))
}

previous_space_on_display :: proc(m: ^Manager, target: ^Space) -> ^Space {
	previous: ^Space
	for s in m.spaces {if s == target {return previous};if s.display == target.display {previous = s}}
	return nil
}

move_space_after :: proc(m: ^Manager, s, anchor: ^Space) -> string {
	if s == nil || anchor == nil || s == anchor {return "invalid space move"}
	if err := perform(m, {kind = .Space_Move, space = s.id, destination = anchor.id});
	   err != "" {return err}
	from, to := -1, -1
	for space, i in m.spaces {if space == s {from = i};if space == anchor {to = i}}
	if from > to {to += 1}
	if from < to {for j := from; j < to; j += 1 {m.spaces[j] = m.spaces[j + 1]}}
	if from > to {for j := from; j > to; j -= 1 {m.spaces[j] = m.spaces[j - 1]}}
	m.spaces[to] = s
	for &d in m.displays {clear(&d.spaces)}
	for space, i in m.spaces {
		space.index = u32(i + 1)
		if d := display_by_id(m, space.display); d != nil {append(&d.spaces, space.id)}
	}
	return ""
}

Space_Window_Move :: struct {
	window:         ^Window,
	source, target: ^Space,
	moved:          bool,
}
swap_space_windows :: proc(m: ^Manager, a, b: ^Space) -> string {
	moves := make([dynamic]Space_Window_Move, context.temp_allocator)
	for _, w in m.windows {
		if w.space == a.id {append(&moves, Space_Window_Move{w, a, b, false})}
		if w.space == b.id {append(&moves, Space_Window_Move{w, b, a, false})}
	}
	err := ""
	for &move in moves {
		if error := perform(m, {kind = .Space, window = move.window.id, space = move.target.id});
		   error != "" {err = error;break}
		move.moved = true
	}
	if err != "" {
		for &move in moves {
			if move.moved {
				if rollback := perform(
					m,
					{kind = .Space, window = move.window.id, space = move.source.id},
				);
				rollback ==
				"" {move.moved = false} else {err = errorf("%s; rollback failed: %s", err, rollback)}
			}
		}
	}
	for move in moves {
		if !move.moved {continue}
		remove(&move.source.view, move.window.id)
		move.window.space, move.window.display = move.target.id, move.target.display
		if managed(move.window) {add(&move.target.view, move.window.id)}
	}
	if err != "" {return err}
	if err := flush(m, a); err != "" {return err}
	return flush(m, b)
}
