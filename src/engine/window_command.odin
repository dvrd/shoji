package engine

import "core:math"
import "core:strconv"
import "core:strings"

window_command :: proc(m: ^Manager, args: []string) -> Response {
	args := args
	selector := ""
	if len(args) > 0 && !strings.has_prefix(args[0], "--") {
		selector = args[0]
		args = args[1:]
	}
	if len(args) == 0 {
		return failure("missing window operation")
	}
	w := select_window(m, selector)
	// `window --focus next` resolves its operand against the focused window.
	if args[0] == "--focus" && len(args) == 2 {
		w = select_window(m, args[1], w != nil ? w.id : 0)
	}
	if w == nil {
		return failure("could not locate window")
	}
	op := args[0]
	operand := len(args) > 1 ? args[1] : ""
	if len(args) > 2 {
		return failure("too many window arguments")
	}
	s := space_by_id(m, w.space)
	n: ^Node
	if s != nil {
		n = find(s.view.root, w.id)
	}
	switch op {
	case "--focus", "--close", "--minimize", "--deminimize":
		if op != "--focus" && len(args) != 1 {
			return failure("operation takes no operand")
		}
		kind: Action_Kind
		switch op {
		case "--focus":
			kind = .Focus
		case "--close":
			kind = .Close
		case "--minimize":
			kind = .Minimize
		case "--deminimize":
			kind = .Deminimize
		}
		if err := perform(m, Action{kind = kind, window = w.id}); err != "" {
			return failure(err)
		}
		if kind == .Focus {
			focus_window(m, w.id)
		}
		return success()
	case "--raise", "--lower":
		relative: u32
		if operand != "" {
			target := select_window(m, operand, w.id)
			if target == nil || target.id == w.id { return failure("invalid relative window") }
			relative = target.id
		}
		return result(
			perform(
				m,
				{
					kind = .Order,
					window = w.id,
					relative = relative,
					value = op == "--raise" ? 1 : -1,
				},
			),
		)
	case "--toggle":
		switch operand {
		case "float":
			if s == nil {
				return failure("window has no space")
			}
			w.floating = !w.floating
			if w.floating {
				remove(&s.view, w.id)
			} else if managed(w) {
				add(&s.view, w.id, m.focused)
			}
		case "zoom-parent", "zoom-fullscreen":
			if n == nil {
				return failure("window is not managed")
			}
			target := operand == "zoom-parent" ? n.parent : s.view.root
			n.zoom = n.zoom == target ? nil : target
		case "split":
			if n == nil || n.parent == nil {
				return failure("window has no split")
			}
			p := n.parent
			p.split = p.split == .Vertical ? .Horizontal : .Vertical
		case "native-fullscreen":
			return result(
				perform(m, Action{kind = .Fullscreen, window = w.id, flag = !w.fullscreen}),
			)
		case "pip":
			display := display_by_id(m, w.display)
			if display == nil { return failure("could not locate display") }
			bounds := display.usable
			view := space_by_id(m, display.active_space)
			if view != nil && view.view.padding_enabled {
				p := view.view.padding
				bounds.x +=
					p.left; bounds.y += p.top; bounds.w -= p.left + p.right; bounds.h -= p.top + p.bottom
			}
			if bounds.w < 4 ||
			   bounds.h <= 0 { return failure("display padding leaves no room for PiP") }
			return result(perform(m, {kind = .Scale, window = w.id, frame = bounds}))
		case "sticky":
			if err := perform(m, {kind = .Sticky, window = w.id, flag = !w.sticky});
			   err != "" { return failure(err) }
			w.sticky = !w.sticky
			return success()
		case "shadow":
			if err := perform(m, {kind = .Shadow, window = w.id, flag = !w.shadow});
			   err != "" { return failure(err) }
			w.shadow = !w.shadow
			return success()
		case:
			return failure(errorf("unsupported toggle '%s'", operand))
		}
	case "--swap", "--warp", "--stack":
		target := select_window(m, operand, w.id)
		if target == nil || target.id == w.id {
			return failure("invalid target window")
		}
		if s == nil || target.space != w.space {
			return failure("target must be on the same space")
		}
		other := find(s.view.root, target.id)
		if n == nil || other == nil {
			return failure("both windows must be managed")
		}
		if op == "--swap" {
			if !swap(n, other) {
				return failure("windows are already in the same stack")
			}
		}
		if op == "--stack" {
			if other == n || other.count == MAX_STACK {
				return failure("invalid or full stack")
			}
			remove(&s.view, w.id)
			other = find(s.view.root, target.id)
			stack_push(other, w.id)
		}
		if op == "--warp" {
			remove(&s.view, w.id)
			add(&s.view, w.id, target.id)
		}
	case "--ratio":
		if n == nil || n.parent == nil {
			return failure("window has no split")
		}
		parts := strings.split(operand, ":", context.temp_allocator)
		if len(parts) != 2 {
			return failure("ratio expects abs:value or rel:value")
		}
		value, ok := strconv.parse_f64(parts[1])
		if !ok || math.is_nan(value) || math.is_inf(value) {
			return failure("invalid ratio")
		}
		switch parts[0] {
		case "abs":
		case "rel":
			value += n.parent.ratio
		case:
			return failure("invalid ratio mode")
		}
		n.parent.ratio = clamp(value, 0.1, 0.9)
	case "--insert":
		if n == nil {
			return failure("window is not managed")
		}
		switch operand {
		case "stack":
			n.insert_stack = true
		case "east", "west":
			n.split = .Vertical
		case "north", "south":
			n.split = .Horizontal
		case:
			return failure("insert expects north, east, south, west, or stack")
		}
		n.insert_first = operand == "west" || operand == "north"
		s.view.insertion = w.id
	case "--move", "--resize":
		parts := strings.split(operand, ":", context.temp_allocator)
		if len(parts) != 3 {
			return failure("expected mode:x:y")
		}
		values: [2]f64
		if !parse_numbers(strings.join(parts[1:], ":", context.temp_allocator), values[:]) {
			return failure("invalid coordinates")
		}
		frame := w.frame
		if op == "--move" {
			if n != nil && s.view.layout != .Float {
				return failure("move requires a floating window")
			}
			switch parts[0] {
			case "abs":
				frame.x, frame.y = values[0], values[1]
			case "rel":
				frame.x += values[0]
				frame.y += values[1]
			case:
				return failure("invalid move mode")
			}
		} else {
			return result(resize_window(m, w, parts[0], values[0], values[1]))
		}
		if err := perform(m, Action{kind = .Frame, window = w.id, frame = frame});
		   err != "" { return failure(err) }
		w.frame = frame
		return success()
	case "--grid":
		if n != nil && s.view.layout != .Float {
			return failure("grid requires a floating window")
		}
		values: [6]f64
		if !parse_numbers(operand, values[:]) {
			return failure("grid expects rows:cols:x:y:w:h")
		}
		rows, cols, x, y, width, height :=
			values[0], values[1], values[2], values[3], values[4], values[5]
		if rows <= 0 ||
		   cols <= 0 ||
		   x < 0 ||
		   y < 0 ||
		   width <= 0 ||
		   height <= 0 ||
		   x + width > cols ||
		   y + height > rows {
			return failure("invalid grid bounds")
		}
		d := display_by_id(m, w.display)
		if d == nil {
			return failure("could not locate display")
		}
		r := d.usable
		return result(
			perform(
				m,
				Action {
					kind = .Frame,
					window = w.id,
					frame = Rect {
						r.x + r.w * x / cols,
						r.y + r.h * y / rows,
						r.w * width / cols,
						r.h * height / rows,
					},
				},
			),
		)
	case "--space", "--display":
		target: ^Space
		if op == "--space" {
			target = select_space(m, operand)
		} else if d := select_display(m, operand); d != nil {
			target = space_by_id(m, d.active_space)
		}
		if target == nil {
			return failure("could not locate destination")
		}
		if err := perform(m, Action{kind = .Space, window = w.id, space = target.id}); err != "" {
			return failure(err)
		}
		if s != nil {
			remove(&s.view, w.id)
		}
		w.space = target.id
		w.display = target.display
		if managed(w) {
			add(&target.view, w.id)
		}
		if err := flush(m, target); err != "" {
			return failure(err)
		}
	case "--opacity":
		value, ok := strconv.parse_f64(operand)
		if !ok || math.is_nan(value) || value < 0 || value > 1 {
			return failure("opacity expects 0..1")
		}
		if err := perform(m, Action{kind = .Opacity, window = w.id, value = value});
		   err != "" { return failure(err) }; w.opacity = value; return success()
	case "--layer", "--sub-layer":
		level: f64
		switch operand {
		case "below":
			level = -1
		case "normal":
			level = 0
		case "above":
			level = 1
		case:
			return failure("invalid layer")
		}
		if err := perform(m, Action{kind = .Layer, window = w.id, value = level});
		   err !=
		   "" { return failure(err) }; w.layer = level < 0 ? "below" : (level > 0 ? "above" : "normal"); return success()
	case:
		return failure(errorf("unsupported window operation '%s'", op))
	}
	return result(flush(m, s))
}

resize_window :: proc(m: ^Manager, w: ^Window, handle: string, dx, dy: f64) -> string {
	if handle == "abs" {
		s := space_by_id(m, w.space)
		if s != nil &&
		   s.view.layout != .Float &&
		   find(s.view.root, w.id) != nil { return "absolute resize requires a floating window" }
		if dx <= 0 || dy <= 0 { return "size must be positive" }
		frame := w.frame; frame.w = dx; frame.h = dy
		if err := perform(m, {kind = .Frame, window = w.id, frame = frame});
		   err != "" { return err }
		w.frame = frame; return ""
	}
	left, top := false, false
	x, y := dx, dy
	switch handle {
	case "top_left":
		left = true; top = true
	case "top_right":
		top = true
	case "bottom_left":
		left = true
	case "bottom_right":
	case "left":
		left = true; y = 0
	case "right":
		y = 0
	case "top":
		top = true; x = 0
	case "bottom":
		x = 0
	case:
		return "resize expects abs, top, bottom, left, right, or a corner handle"
	}
	d := Mouse_Drag {
		window = w.id,
		action = .Resize,
		frame  = w.frame,
		left   = left,
		top    = top,
	}
	return mouse_update(m, &d, {x, y})
}
