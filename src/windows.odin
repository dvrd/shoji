package shoji

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import dock "dock"
import layout "layout"

// Window commands
// ------------------------------------------------------------------------

window_toggle_float :: proc(m: ^Manager, w: ^Window) -> string {
	s := space_by_id(m, w.space)
	if s == nil {
		return "window has no space"
	}
	w.floating = !w.floating
	if !w.floating && w.opening.phase == .Excluded {
		w.opening.phase = .Admitted
	}
	w.scroll_frame = {}
	if w.floating {
		layout.remove(&s.view, w.id)
	} else if layout_admitted(w) {
		layout.add(&s.view, w.id, m.focused)
		scroll_rule_realize(m, w)
	}
	return flush(m, s)
}

window_command :: proc(m: ^Manager, args: []string) -> Response {
	start := 0
	if len(args) > 0 && !strings.has_prefix(args[0], "--") {
		start = 1
	}
	parts := make([dynamic][]string, context.temp_allocator)
	for i := start + 1; i < len(args); i += 1 {
		if strings.has_prefix(args[i], "--") {
			append(&parts, args[start:i]); start = i
		}
	}
	if len(parts) == 0 {
		return window_command_one(m, args)
	}
	append(&parts, args[start:])
	// Check the command framing before applying any operation. Backend failures
	// stop the chain; earlier successful operations retain their normal effects.
	for part in parts {
		if len(part) < 1 || len(part) > 2 {
			return failure("expected window operation and optional operand")
		}
		if len(part) == 1 {
			switch part[0] {
			case "--focus",
			     "--close",
			     "--minimize",
			     "--deminimize",
			     "--raise",
			     "--lower",
			     "--center",
			     "--consume",
			     "--expel":
			case:
				return failure("window operation requires an operand")
			}
		}
	}
	selector := ""
	if len(args) > 0 && !strings.has_prefix(args[0], "--") {
		selector = args[0]
	}
	w := select_window(m, selector)
	if w == nil {
		return failure("could not locate window")
	}
	selector = fmt.tprintf("%d", w.id)
	for part in parts {
		command := [3]string{selector, part[0], ""}
		count := 2
		if len(part) == 2 {
			command[2] = part[1]; count = 3
		}
		if response := window_command_one(m, command[:count]); response.failed {
			return response
		}
	}
	return success()
}

window_command_one :: proc(m: ^Manager, args: []string) -> Response {
	args := args
	selector := ""
	if len(args) > 0 && !strings.has_prefix(args[0], "--") {
		selector = args[0]
		args = args[1:]
	}
	if len(args) == 0 {
		return failure("missing window operation")
	}
	if len(args) == 2 && args[0] == "--scratchpad" && args[1] == "recover" {
		return result(scratchpad_recover(m))
	}
	if len(args) == 2 && args[0] == "--toggle" {
		if scratch := scratchpad_by_label(m, args[1]); scratch != nil {
			return result(scratchpad_toggle(m, scratch))
		}
	}
	w := select_window(m, selector)
	// These operations accept a selector either before the command or as its operand.
	if (args[0] == "--focus" ||
		   args[0] == "--close" ||
		   args[0] == "--minimize" ||
		   args[0] == "--deminimize") &&
	   len(args) == 2 {
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
	n: ^layout.Node
	if s != nil {
		n = layout.find(s.view.root, w.id)
	}
	switch op {
	case "--cycle-column-width",
	     "--cycle-row-height",
	     "--row-height",
	     "--column-display",
	     "--consume",
	     "--expel",
	     "--consume-or-expel",
	     "--move-column",
	     "--size-limits":
		if s == nil || s.view.layout != .Scroll || n == nil {
			return failure("operation requires a scrolling column")
		}
		switch op {
		case "--cycle-row-height":
			if operand != "next" && operand != "prev" {
				return failure("cycle-row-height expects next or prev")
			}
			if err := scroll_cycle_height(m, &s.view, w, operand == "prev"); err != "" {
				return failure(err)
			}
		case "--size-limits":
			values: [4]f64
			if !parse_numbers(operand, values[:]) {
				return failure(
					"size-limits expects min-width:min-height:max-width:max-height (zero means unspecified)",
				)
			}
			for value in values {
				if value < 0 || value > 100000 {
					return failure("size limits must be between 0 and 100000")
				}
			}
			if (values[2] > 0 && values[2] < values[0]) ||
			   (values[3] > 0 && values[3] < values[1]) {
				return failure("maximum size must not be smaller than minimum size")
			}
			w.min_width, w.min_height, w.max_width, w.max_height =
				values[0], values[1], values[2], values[3]
			s.view.scroll.reveal = true
		case "--cycle-column-width":
			if operand != "next" && operand != "prev" {
				return failure("cycle-column-width expects next or prev")
			}
			layout.scroll_cycle_width(&s.view, n, operand == "prev")
		case "--row-height":
			if err := scroll_set_row(m, &s.view, w, operand); err != "" {
				return failure(err)
			}
		case "--column-display":
			if operand != "normal" && operand != "tabbed" && operand != "toggle" {
				return failure("column-display expects normal, tabbed, or toggle")
			}
			n.column_tabbed = operand == "toggle" ? !n.column_tabbed : operand == "tabbed"
			n.column_raised = 0
		case "--consume", "--expel":
			if operand != "" {
				return failure("consume and expel take no operand")
			}
			return result(scroll_transfer(m, s, w, op, "east"))
		case "--consume-or-expel", "--move-column":
			if operand != "west" && operand != "east" {
				return failure("expected west or east")
			}
			if op == "--consume-or-expel" {
				return result(scroll_transfer(m, s, w, op, operand))
			}
			layout.scroll_move_column(&s.view, n, operand == "west")
		}
	case "--column-width":
		if s == nil || s.view.layout != .Scroll {
			return failure("column-width requires scroll layout")
		}
		if err := layout.scroll_set_width(&s.view, w.id, operand); err != "" {
			return failure(err)
		}
	case "--center":
		if s == nil || s.view.layout != .Scroll || n == nil {
			return failure("center requires a scrolling column")
		}
		if operand != "" {
			return failure("center takes no operand")
		}
		layout.view_update(&s.view)
		layout.scroll_reveal(&s.view, w.id, true)
		s.view.scroll.focused = m.focused; s.view.scroll.reveal = false
	case "--scratchpad":
		return result(scratchpad_assign(m, w, operand))
	case "--focus", "--close", "--minimize", "--deminimize":
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
			if s != nil && s.view.layout == .Scroll {
				s.view.scroll.reveal = true; if err := flush(m, s); err != "" {
					return failure(err)
				}
			}
			if err := apply_window_opacity(m); err != "" {
				return failure(err)
			}
		}
		return success()
	case "--raise", "--lower":
		relative: u32
		if operand != "" {
			target := select_window(m, operand, w.id)
			if target == nil || target.id == w.id {
				return failure("invalid relative window")
			}
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
		case "column-full-width":
			if s == nil || s.view.layout != .Scroll || n == nil {
				return failure("column-full-width requires a scrolling column")
			}
			s.view.scroll.fill_after_removal = false
			n.column_full = !n.column_full
			if n.column_full {
				n.column_maximize, n.column_cover = false, false
			}
			n.column_revision += 1
			n.column_preset = nil
			s.view.scroll.reveal = true
		case "maximize", "layout-fullscreen":
			if s == nil || s.view.layout != .Scroll || n == nil {
				return failure("maximize and layout-fullscreen require a scrolling column")
			}
			s.view.scroll.fill_after_removal = false
			if operand == "layout-fullscreen" {
				n.column_cover = !n.column_cover
				if n.column_cover {
					n.column_full, n.column_maximize = false, false
				}
			} else {
				n.column_maximize = !n.column_maximize
				if n.column_maximize {
					n.column_full, n.column_cover = false, false
				}
			}
			n.column_revision += 1
			n.column_preset = nil
			s.view.scroll.reveal = true
		case "float":
			return result(window_toggle_float(m, w))
		case "zoom-parent", "zoom-fullscreen":
			if s != nil && s.view.layout == .Scroll && operand == "zoom-parent" {
				return failure("parent split zoom is unavailable in scroll layout")
			}
			if n == nil {
				return failure("window is not managed")
			}
			target := operand == "zoom-parent" ? n.parent : s.view.root
			n.zoom = n.zoom == target ? nil : target
		case "split":
			if s != nil && s.view.layout == .Scroll {
				return failure(
					"split toggling is unavailable in scroll layout; use --stack for rows",
				)
			}
			if n == nil || n.parent == nil {
				return failure("window has no split")
			}
			p := n.parent
			p.split = p.split == .Vertical ? .Horizontal : .Vertical
		case "native-fullscreen":
			return result(
				perform(m, Action{kind = .Fullscreen, window = w.id, flag = !w.fullscreen}),
			)
		case "windowed-fullscreen":
			d := display_by_id(m, w.display)
			if d == nil {
				return failure("could not locate display")
			}
			target := usable_frame(m, d)
			previous, restoring := w.windowed_frame.?
			if restoring {
				target = previous
			}
			if err := perform(m, {kind = .Frame, window = w.id, frame = target}); err != "" {
				return failure(err)
			}
			if restoring {
				w.windowed_frame = nil
			} else {
				w.windowed_frame = w.frame
			}
			w.frame = target
			return success()
		case "expose":
			return result(perform(m, {kind = .Expose, window = w.id}))
		case "pip":
			display := display_by_id(m, w.display)
			if display == nil {
				return failure("could not locate display")
			}
			bounds := display.usable
			view := space_by_id(m, display.active_space)
			if view != nil && view.view.padding_enabled {
				p := view.view.padding
				bounds.x += p.left; bounds.y += p.top
				bounds.w -= p.left + p.right; bounds.h -= p.top + p.bottom
			}
			if bounds.w < 4 || bounds.h <= 0 {
				return failure("display padding leaves no room for PiP")
			}
			return result(perform(m, {kind = .Scale, window = w.id, frame = bounds}))
		case "sticky":
			if err := perform(m, {kind = .Sticky, window = w.id, flag = !w.sticky}); err != "" {
				return failure(err)
			}
			w.sticky = !w.sticky
			if err := sync_window_membership(m, w, w.space); err != "" {
				return failure(err)
			}
			return result(flush(m, s))
		case "shadow":
			if err := perform(m, {kind = .Shadow, window = w.id, flag = !w.shadow}); err != "" {
				return failure(err)
			}
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
		if s == nil {
			return failure("window has no space")
		}
		target_space := space_by_id(m, target.space)
		if target_space == nil {
			return failure("target window has no space")
		}
		other := layout.find(target_space.view.root, target.id)
		if n == nil || other == nil {
			return failure("both windows must be managed")
		}
		if op == "--warp" && other != n && !layout.can_add(&target_space.view, target.id) {
			return failure("target stack is full")
		}
		if target_space != s {
			if op == "--stack" {
				return failure("stack target must be on the same space")
			}
			if err := perform(m, Action{kind = .Space, window = w.id, space = target_space.id});
			   err != "" {
				return failure(err)
			}
			if op == "--swap" {
				if err := perform(m, Action{kind = .Space, window = target.id, space = s.id});
				   err != "" {
					if rollback := perform(m, Action{kind = .Space, window = w.id, space = s.id});
					   rollback != "" {
						layout.remove(&s.view, w.id)
						w.space, w.display = target_space.id, target_space.display
						layout.add(&target_space.view, w.id, target.id)
						return failure(errorf("%s; rollback failed: %s", err, rollback))
					}
					return failure(err)
				}
			}
			w.space, w.display = target_space.id, target_space.display
			if op == "--swap" {
				target.space, target.display = s.id, s.display
				replace_window_id(n, w.id, target.id)
				replace_window_id(other, target.id, w.id)
			} else {
				layout.remove(&s.view, w.id)
				layout.add(&target_space.view, w.id, target.id)
			}
			if err := flush(m, s); err != "" {
				return failure(err)
			}
			if err := flush(m, target_space); err != "" {
				return failure(err)
			}
			return success()
		}
		if op == "--swap" {
			if s.view.layout == .Scroll && n == other {
				a, b := -1, -1
				for i in 0 ..< n.count {
					if n.windows[i] == w.id {
						a = i
					}; if n.windows[i] == target.id {
						b = i
					}
				}
				if a < 0 || b < 0 {
					return failure("could not locate scrolling rows")
				}
				n.windows[a], n.windows[b] = n.windows[b], n.windows[a]
				return result(flush(m, s))
			}
			swapped :=
				s.view.layout == .Scroll ? layout.swap_columns(n, other) : layout.swap(n, other)
			if !swapped {
				return failure("windows are already in the same stack")
			}
			if s.view.layout == .Scroll {
				s.view.scroll.fill_after_removal = true
			}
		}
		if s.view.layout == .Scroll {
			s.view.scroll.reveal = true
		}
		if op == "--stack" {
			if other == n || n.count == layout.MAX_STACK {
				return failure("invalid or full stack")
			}
			layout.remove(&s.view, target.id)
			n = layout.find(s.view.root, w.id)
			layout.stack_push(n, target.id)
		}
		if op == "--warp" {
			width := n.column_width
			size, preset, full := n.column_size, n.column_preset, n.column_full
			layout.remove(&s.view, w.id)
			if s.view.layout == .Scroll {
				if anchor := layout.find(s.view.root, target.id); anchor != nil {
					anchor.insert_first = operand == "west" || operand == "prev"
				}
			}
			layout.add(&s.view, w.id, target.id)
			if s.view.layout == .Scroll {
				if placed := layout.find(s.view.root, w.id); placed != nil {
					placed.column_width, placed.column_resolved = width, width
					placed.column_size, placed.column_preset, placed.column_full =
						size, preset, full
				}
			}
		}
	case "--ratio":
		if s != nil && s.view.layout == .Scroll {
			return failure("use --column-width to resize scrolling columns")
		}
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
		if s != nil && s.view.layout == .Scroll && (operand == "north" || operand == "south") {
			return failure("use --insert stack for scrolling rows, or east/west for columns")
		}
		if n == nil {
			return failure("window is not managed")
		}
		if s.view.insertion == w.id {
			matches :=
				operand == "stack" \
					? n.insert_stack \
					: (!n.insert_stack &&
						n.insert_first != nil &&
						(n.insert_first.? or_else false) ==
							(operand == "west" || operand == "north") &&
						n.split ==
							((operand == "east" || operand == "west") \
										? layout.Split.Vertical \
										: layout.Split.Horizontal))
			if matches {
				n.insert_stack = false; n.insert_first = nil
				s.view.insertion = 0
				return success()
			}
		}
		switch operand {
		case "stack":
			n.insert_stack = true
		case "east", "west":
			n.split = .Vertical; n.insert_stack = false
		case "north", "south":
			n.split = .Horizontal; n.insert_stack = false
		case:
			return failure("insert expects north, east, south, west, or stack")
		}
		n.insert_first = operand == "west" || operand == "north"
		motion_trace_record(
			&m.motion_trace,
			{kind = "insert-armed", window = w.id, space = s.id, status = n.insert_stack ? 1 : 0},
		)
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
		if err := perform(m, Action{kind = .Frame, window = w.id, frame = frame}); err != "" {
			return failure(err)
		}
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
		if s != nil && s.view.padding_enabled {
			p := s.view.padding
			r.x += p.left; r.y += p.top; r.w -= p.left + p.right
			r.h -= p.top + p.bottom
		}
		if r.w <= 0 || r.h <= 0 {
			return failure("padding leaves no room for grid")
		}
		frame := Rect {
			r.x + r.w * x / cols,
			r.y + r.h * y / rows,
			r.w * width / cols,
			r.h * height / rows,
		}
		if err := perform(m, {kind = .Frame, window = w.id, frame = frame}); err != "" {
			return failure(err)
		}
		w.frame = frame
		return success()
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
		if target != s &&
		   layout_admitted(w) &&
		   target.view.layout != .Float &&
		   !layout.can_add(&target.view) {
			return failure("target stack is full")
		}
		// Tile in the destination first so the move can carry its landing
		// position (WindowServer adapter, C4); undone if the move fails.
		landing, staged := space_landing(w, s, target)
		if err := perform(
			m,
			Action{kind = .Space, window = w.id, space = target.id, frame = landing},
		); err != "" {
			if staged {
				layout.remove(&target.view, w.id)
			}
			return failure(err)
		}
		if s != nil {
			layout.remove(&s.view, w.id)
		}
		w.space = target.id
		w.display = target.display
		if w.opening.phase == .Excluded && managed(w) {
			w.opening.phase = .Admitted
		}
		if layout_admitted(w) && !staged {
			layout.add(&target.view, w.id)
		}
		if err := flush(m, target); err != "" {
			return failure(err)
		}
	case "--opacity":
		value, ok := strconv.parse_f64(operand)
		if !ok || math.is_nan(value) || value < 0 || value > 1 {
			return failure("opacity expects 0..1")
		}
		override := value != 0
		if !override {
			value =
				m.window_opacity ? (w.id == m.focused ? m.active_opacity : m.normal_opacity) : 1.0
		}
		if err := perform(m, Action{kind = .Opacity, window = w.id, value = value}); err != "" {
			return failure(err)
		}; w.opacity = value; w.opacity_override = override; return success()
	case "--layer", "--sub-layer":
		level: f64
		switch operand {
		case "below":
			level = -1
		case "normal":
			level = 0
		case "above":
			level = 1
		case "auto":
			level = managed(w) ? -1 : 0
		case:
			return failure("invalid layer")
		}
		if err := perform(m, Action{kind = .Layer, window = w.id, value = level}); err != "" {
			return failure(err)
		}; w.layer = level < 0 ? "below" : (level > 0 ? "above" : "normal")
		w.layer_override = operand != "auto"; return success()
	case:
		return failure(errorf("unsupported window operation '%s'", op))
	}
	return result(flush(m, s))
}

replace_window_id :: proc(n: ^layout.Node, old, fresh: u32) {
	for i in 0 ..< n.count {
		if n.windows[i] == old {
			n.windows[i] = fresh
		}
		if n.order[i] == old {
			n.order[i] = fresh
		}
	}
}

resize_window :: proc(m: ^Manager, w: ^Window, handle: string, dx, dy: f64) -> string {
	if s := space_by_id(m, w.space);
	   s != nil && s.view.layout == .Scroll && layout.find(s.view.root, w.id) != nil {
		if (handle != "left" && handle != "right") || dy != 0 {
			return(
				"scroll resize supports left/right width changes; use --column-width for an absolute width" \
			)
		}
		delta := handle == "left" ? -dx : dx
		if err := layout.scroll_set_width(&s.view, w.id, fmt.tprintf("rel:%g", delta)); err != "" {
			return err
		}
		return flush(m, s)
	}
	if handle == "abs" {
		s := space_by_id(m, w.space)
		if s != nil && s.view.layout != .Float && layout.find(s.view.root, w.id) != nil {
			return "absolute resize requires a floating window"
		}
		if dx <= 0 || dy <= 0 {
			return "size must be positive"
		}
		frame := w.frame; frame.w = dx; frame.h = dy
		if err := perform(m, {kind = .Frame, window = w.id, frame = frame}); err != "" {
			return err
		}
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

// Window admission
// ------------------------------------------------------------------------

Opening_Phase :: enum {
	Admitted,
	Pending,
	Opening,
	Excluded,
}
Opening_Wait :: enum {
	Readiness,
	Space,
	Backend,
}
Opening :: struct {
	phase:             Opening_Phase,
	wait:              Opening_Wait,
	focus_origin:      u32,
	focus_superseded:  bool,
	focus_replacement: u32,
	staged:            bool,
	minimum:           Rect,
	seed:              Rect,
	restore_layer:     f64,
	original_layer:    f64,
}

Opening_Prepare :: proc(m: ^Manager, w: ^Window, seed: Rect) -> (Rect, bool, string)
Opening_Backend :: struct {
	prepare: Opening_Prepare,
	conceal: proc(m: ^Manager, w: ^Window) -> string,
}

// Discovery records intent; admission alone changes layout membership.
discover_window :: proc(m: ^Manager, value: Window) -> ^Window {
	if old := m.windows[value.id]; old != nil {
		return old
	}
	value := value
	value.opening = {
		phase        = .Pending,
		focus_origin = m.focused,
	}
	return add_window(m, value)
}

layout_admitted :: proc(w: ^Window) -> bool {
	return managed(w) && (w.opening.phase == .Admitted || w.opening.phase == .Opening)
}

opening_intended :: proc(w: ^Window) -> bool {
	value := w^; value.ordered_in = nil
	return managed(&value)
}

opening_clone_node :: proc(source, parent: ^layout.Node) -> ^layout.Node {
	if source == nil {
		return nil
	}
	n := new(layout.Node); n^ = source^; n.parent = parent; n.zoom = nil
	n.left = opening_clone_node(source.left, n)
	n.right = opening_clone_node(source.right, n)
	return n
}

opening_apply_seed :: proc(m: ^Manager, w: ^Window, seed: Rect) -> (Rect, bool, string) {
	err := perform(m, {kind = .Frame, window = w.id, frame = seed, direct = true})
	return seed, err == "", err
}

// Conceal during discovery, before a desktop scan can block on another app.
// Planning and membership changes remain deferred until collection completes.
stage_opening :: proc(m: ^Manager, w: ^Window, backend: Opening_Backend = {}) -> (bool, string) {
	if w == nil || w.opening.phase != .Pending || m.suspended || m.gesture_active {
		return false, ""
	}
	o := &w.opening
	if w.role == "" || w.subrole == "" {
		return false, ""
	}
	if !opening_intended(w) {
		return false, exclude_opening(m, w)
	}
	if !o.staged {
		o.original_layer = w.layer == "above" ? 1 : (w.layer == "below" ? -1 : 0)
		o.restore_layer =
			w.layer_override ? (w.layer == "above" ? 1 : (w.layer == "below" ? -1 : 0)) : -1
		if err := perform(m, {kind = .Layer, window = w.id, value = -1}); err != "" {
			o.wait = .Backend; return false, err
		}
		if err := perform(m, {kind = .Order, window = w.id, value = -1}); err != "" {
			o.wait = .Backend; return false, err
		}
		o.staged = true; w.layer = "below"
	}
	if backend.conceal != nil {
		if err := backend.conceal(m, w); err != "" {
			o.wait = .Backend; return false, err
		}
	}
	return true, ""
}

// All discovery sources call this same admission boundary. A candidate view is
// private until preparation succeeds, so existing tiles keep their geometry.
admit_window :: proc(m: ^Manager, w: ^Window, backend: Opening_Backend = {}) -> (bool, string) {
	staged, stage_error := stage_opening(m, w, backend)
	if !staged {
		return false, stage_error
	}
	o := &w.opening
	if w.rules_pending {
		o.wait = .Readiness; return false, ""
	}
	if m.focused != o.focus_origin && m.focused != w.id {
		o.focus_superseded = true
	}
	s := space_by_id(m, w.space)
	if s == nil ||
	   !s.visible ||
	   !(w.ordered_in.? or_else true) ||
	   w.frame.w <= 0 ||
	   w.frame.h <= 0 {
		o.wait = .Readiness; return false, ""
	}
	if s.view.layout == .Float {
		return false, exclude_opening(m, w)
	}
	v := s.view; v.root = opening_clone_node(s.view.root, nil)
	defer layout.view_destroy(&v)
	zooms := layout.capture_zooms(&s.view); layout.restore_zooms(&v, zooms[:])
	if !layout.add(&v, w.id, window_insertion(m, &v)) {
		o.wait = .Space; return false, ""
	}
	if v.layout == .BSP {
		if !bsp_constraints(m, &v) {
			o.wait = .Space; return false, ""
		}
		layout.view_update(&v)
	}
	if v.layout == .Scroll {
		v.scroll.geometry_enabled = false
		scroll_constraints(m, &v); layout.view_update(&v); scroll_rows(m, &v)
		if m.focused == w.id && !o.focus_superseded {
			layout.scroll_reveal(&v, w.id); layout.scroll_update(&v); scroll_rows(m, &v)
		}
	}
	n := layout.find(v.root, w.id)
	target :=
		v.layout == .Scroll ? layout.scroll_window_frame(&v, n, w.id, false) : layout.frame_for(n)
	if v.layout == .Scroll && target.h > v.scroll.viewport.h {
		o.wait = .Space; return false, ""
	}
	// A new column grows in from half size at its trailing edge. A new tab
	// covers its column's existing frame, so it is prepared at that final frame
	// and revealed already sized, with nothing to animate.
	joins_tabs := v.layout == .Scroll && n.column_tabbed && n.count > 1
	vertical := v.layout == .Scroll || n.parent == nil || n.parent.split == .Vertical
	trailing := !joins_tabs && (v.layout == .Scroll || n.parent == nil || n == n.parent.right)
	seed := target
	if joins_tabs {
	} else if vertical {
		seed.w = max(1, target.w * 0.5)
	} else {
		seed.h = max(1, target.h * 0.5)
	}
	seed.w = max(seed.w, max(w.min_width, o.minimum.w))
	seed.h = max(seed.h, max(w.min_height, o.minimum.h))
	if trailing {
		if vertical {
			seed.x = target.x + target.w - seed.w
		} else {
			seed.y = target.y + target.h - seed.h
		}
	}
	prepare: Opening_Prepare = opening_apply_seed
	if backend.prepare != nil {
		prepare = backend.prepare
	}
	accepted, ready, err := prepare(m, w, seed)
	if err != "" {
		o.wait = .Backend; return false, err
	}
	if !ready {
		o.wait = .Readiness; return false, ""
	}
	if math.is_nan(accepted.w) || math.is_nan(accepted.h) || accepted.w <= 0 || accepted.h <= 0 {
		o.wait = .Readiness; return false, ""
	}
	if accepted.w > seed.w + 1 {
		o.minimum.w = max(o.minimum.w, accepted.w)
	}
	if accepted.h > seed.h + 1 {
		o.minimum.h = max(o.minimum.h, accepted.h)
	}
	if accepted.w > target.w + 1 || accepted.h > target.h + 1 {
		o.wait = .Space; return false, ""
	}
	aligned := accepted; aligned.x, aligned.y = target.x, target.y
	if trailing {
		if vertical {
			aligned.x = target.x + target.w - accepted.w
		} else {
			aligned.y = target.y + target.h - accepted.h
		}
	}
	placement := aligned
	parked := v.layout == .Scroll && layout.scroll_park_frame(&v, aligned).x != aligned.x
	if parked {
		// AppKit clamps wholly off-screen AX moves to a visible edge. Keep
		// that stable native position while retaining the strip's world frame.
		placement.x = accepted.x
	}
	if !scroll_rect_near(placement, accepted, 1) {
		_, _, err := prepare(m, w, aligned)
		o.wait = .Readiness; return false, err
	}
	w.frame = accepted; o.seed = accepted
	if v.layout == .Scroll {
		world := accepted
		if parked {
			world.x = aligned.x
		}
		world.x += v.scroll.motion.initialized ? v.scroll.motion.position : v.scroll.offset
		w.scroll_frame = {
			valid   = true,
			space   = s.id,
			from    = world,
			current = world,
			target  = world,
		}
	}
	old := s.view; s.view = v; v = old
	o.phase = .Opening
	motion_trace_join(m, s, w.id, "opening-join")
	if err := flush(m, s); err != "" {
		return true, err
	}
	return true, ""
}

opening_note_focus :: proc(m: ^Manager, id: u32, deliberate: bool = false) {
	if id == 0 {
		return
	}
	for _, w in m.windows {
		if (w.opening.phase == .Pending || w.opening.phase == .Opening) &&
		   id != w.id &&
		   (deliberate || id != w.opening.focus_origin || m.focused != id) {
			w.opening.focus_superseded = true; w.opening.focus_replacement = id
		}
	}
}

exclude_opening :: proc(m: ^Manager, w: ^Window) -> string {
	if w.opening.staged {
		if err := perform(m, {kind = .Layer, window = w.id, value = w.opening.original_layer});
		   err != "" {
			return err
		}
		w.layer =
			w.opening.original_layer == 0 \
				? "normal" \
				: (w.opening.original_layer > 0 ? "above" : "below")
	}
	w.opening.phase = .Excluded
	return ""
}

finish_opening :: proc(m: ^Manager, w: ^Window) -> string {
	if w == nil || w.opening.phase != .Opening {
		return ""
	}
	if w.opening.restore_layer != -1 {
		if err := perform(m, {kind = .Layer, window = w.id, value = w.opening.restore_layer});
		   err != "" {
			return err
		}
		w.layer = w.opening.restore_layer == 1 ? "above" : "normal"
	}
	if !w.opening.focus_superseded && m.focused == w.id {
		if err := perform(m, {kind = .Order, window = w.id, value = 1}); err != "" {
			return err
		}
	}
	w.opening.phase = .Admitted
	return ""
}


// Opening readiness
// ------------------------------------------------------------------------

Opening_Guard :: struct {
	proxy:             Animation_Proxy,
	hidden:            bool,
	requested, sample: Rect,
	original:          Rect,
	samples:           int,
	checked:           time.Time,
}

// Diagnostic builds arm on discovery so a human-triggered opening cannot miss
// the bounded capture interval. Only geometry and native operation status enter it.
opening_trace_begin :: proc(state: ^State) {
	when #config(SHOJI_OPENING_TRACE, false) {
		if !state.manager.motion_trace.active {
			motion_debug(&state.manager, {"motion", "start"})
		}
	}
}

opening_trace_native :: proc(state: ^State, kind: string, id: u32, requested: Rect = {}) {
	if !state.manager.motion_trace.active {
		return
	}
	actual: Rect
	code := SLSGetWindowBounds(state.connection, id, &actual)
	motion_trace_record(
		&state.manager.motion_trace,
		{kind = kind, window = id, requested = requested, observed = actual, status = code},
	)
}

// Both native notifications and enumeration use this admission boundary.
opening_observe :: proc(
	state: ^State,
	app: Application,
	element: Ref,
	observation: Window,
) -> ^Window {
	value := observation
	old := state.manager.windows[value.id]
	if state.opening_tracking && !state.read_only && (old == nil || old.pid != value.pid) {
		opening_trace_begin(state)
		opening_trace_native(state, "opening-discovered", value.id)
		value.opening = {
			phase        = .Pending,
			focus_origin = state.manager.focused,
		}
	}
	w: ^Window
	if element != nil {
		w, _ = reconcile_window(state, app, element, value)
	} else {
		w, _ = reconcile_window_model(&state.manager, value)
	}
	if w.opening.phase == .Pending {
		if state.opening_windows == nil {
			state.opening_windows = make(map[u32]bool)
		}
		state.opening_windows[w.id] = true
		if state.opening_collecting {
			backend := state.opening_backend
			if backend.prepare == nil {
				backend = {opening_native_prepare, opening_conceal}
			}
			_, err := stage_opening(&state.manager, w, backend)
			if err != "" {
				fmt.eprintln("shoji: stage opening:", w.id, err)
			}
		} else {
			opening_attempt(state, w)
		}
	}
	if element != nil {
		reconcile_window_appearance(w, collect_window_appearance(state, element, w.id))
	}
	return w
}

opening_created :: proc(state: ^State, observer, element: Ref) {
	if state.read_only || !state.opening_tracking {
		return
	}
	id: u32
	if _AXUIElementGetWindow(element, &id) != 0 ||
	   id == 0 ||
	   attribute_text(element, "AXRole") != "AXWindow" {
		return
	}
	opening_trace_begin(state)
	opening_trace_native(state, "opening-created", id)
	for pid, app in state.applications {
		if app.observer != observer {
			continue
		}
		if state.validation_pid != 0 && state.validation_pid != pid {
			return
		}
		opening_observe(
			state,
			app,
			element,
			collect_window(state, app, element, id, pid, app.policy, app.hidden),
		)
		return
	}
}

// The transparent owned surface is a liveness token, not a screenshot. Dock's
// orphan recovery restores the real window if the token owner crashes.
opening_conceal :: proc(m: ^Manager, w: ^Window) -> string {
	state := (^State)(m.backend_user)
	guard, exists := state.opening_guards[w.id]
	if !exists {
		owner, known := animation_recovery_query_owner(state.connection, w.id)
		pid: i32
		if !known || SLSConnectionGetPID(owner, &pid) != 0 || pid != w.pid {
			return "opening window ownership is unavailable"
		}
		surface, err := surface_create(
			state,
			{0, 0, 1, 1},
			w.id,
			(1 << 1) | (1 << 3) | (1 << 9),
			13,
			1,
		)
		if err != "" {
			return err
		}
		proxy_owner, proxy_known := animation_recovery_query_owner(state.connection, surface.id)
		if !proxy_known {
			surface_destroy(state, surface)
			return "opening token ownership is unavailable"
		}
		if err := animation_journal_record(
			&state.animation_journal,
			dock.Entry{w.id, surface.id, owner, proxy_owner},
		); err != "" {
			surface_destroy(state, surface); return err
		}
		CGContextClearRect(surface.ctx, {0, 0, 1, 1})
		CGContextFlush(surface.ctx)
		guard.proxy = {
			window  = w.id,
			surface = surface,
		}
		guard.original = w.frame
		if state.opening_guards == nil {
			state.opening_guards = make(map[u32]Opening_Guard)
		}
		state.opening_guards[w.id] = guard
	}
	if guard.hidden {
		return ""
	}
	opening_trace_native(state, "opening-conceal-begin", w.id)
	if err := animation_swap(guard.proxy, true); err != "" {
		return err
	}
	opening_trace_native(state, "opening-conceal-end", w.id)
	guard.hidden = true; state.opening_guards[w.id] = guard
	return ""
}

opening_release :: proc(state: ^State, id: u32) -> string {
	guard, exists := state.opening_guards[id]
	if !exists {
		return ""
	}
	if w := state.manager.windows[id];
	   w != nil &&
	   (w.opening.phase == .Pending || w.opening.phase == .Excluded) &&
	   guard.requested.w > 0 &&
	   guard.original.w > 0 {
		if err := apply_frame_now(state, id, guard.original); err != "" {
			return err
		}
	}
	opening_trace_native(state, "opening-reveal-begin", id)
	if err := native_proxy_restore(state, guard.proxy); err != "" {
		return err
	}
	opening_trace_native(state, "opening-reveal-end", id)
	native_proxy_destroy(state, guard.proxy)
	delete_key(&state.opening_guards, id)
	return ""
}

opening_native_prepare :: proc(m: ^Manager, w: ^Window, seed: Rect) -> (Rect, bool, string) {
	state := (^State)(m.backend_user)
	element := state.windows[w.id]
	guard, exists := state.opening_guards[w.id]
	if element == nil || !exists || !guard.hidden {
		return {}, false, ""
	}
	if guard.requested != seed {
		if err := perform(m, {kind = .Frame, window = w.id, frame = seed, direct = true});
		   err != "" {
			return {}, false, err
		}
		guard.requested = seed; guard.samples = 0
		guard.checked = time.now(); state.opening_guards[w.id] = guard
		return {}, false, ""
	}
	now := time.now()
	if time.diff(guard.checked, now) < 8 * time.Millisecond {
		return {}, false, ""
	}
	accepted, valid := window_frame(element).?
	if !valid {
		return {}, false, ""
	}
	if math.abs(accepted.x - guard.sample.x) <= 1 &&
	   math.abs(accepted.y - guard.sample.y) <= 1 &&
	   math.abs(accepted.w - guard.sample.w) <= 1 &&
	   math.abs(accepted.h - guard.sample.h) <= 1 {
		guard.samples += 1
	} else {
		guard.samples = 1
	}
	guard.sample = accepted; guard.checked = now
	state.opening_guards[w.id] = guard
	return accepted, guard.samples >= 2, ""
}

opening_attempt :: proc(state: ^State, w: ^Window) {
	backend := state.opening_backend
	if backend.prepare == nil {
		backend = {opening_native_prepare, opening_conceal}
	}
	wait := w.opening.wait
	admitted, err := admit_window(&state.manager, w, backend)
	if admitted {
		opening_trace_native(state, "opening-admitted", w.id, w.opening.seed)
	}
	if err != "" && wait != .Backend {
		fmt.eprintln("shoji: opening:", w.id, err)
	}
	if admitted || w.opening.phase == .Excluded {
		if err := opening_release(state, w.id); err != "" {
			fmt.eprintln("shoji: reveal opening:", err)
		}
	}
}

opening_destroyed :: proc(state: ^State, element: Ref) {
	id: u32
	for window, ref in state.windows {
		if CFEqual(element, ref) {
			id = window; break
		}
	}
	if id == 0 {
		return
	}
	w := state.manager.windows[id]
	// Remove the decoration before AX unsubscription, recovery or reflow can
	// block. Its generation still names the real owner when ordered above a
	// proxy, and focus may already have moved to another window.
	if state.focus_ring.window == id || (w != nil && state.focus_ring.generation == w.generation) {
		focus_ring_stop(state)
	}
	for i in 0 ..< state.tab_indicator.count {
		if state.tab_indicator.tabs[i].window == id {
			tab_indicator_stop(state); break
		}
	}
	if w == nil {
		return
	}
	s := space_by_id(&state.manager, w.space)
	app := state.applications[w.pid]
	window_reference_remove(state, id, app.observer)
	remove_observed_window(state, id)
	if err := opening_release(state, id); err != "" {
		fmt.eprintln("shoji: closed opening:", err)
	}
	delete_key(&state.opening_windows, id)
	if s != nil {
		if err := flush(&state.manager, s); err != "" {
			fmt.eprintln("shoji: close layout:", err)
		}
	}
}

opening_tick :: proc(state: ^State) {
	if state.read_only || state.manager.suspended || state.manager.gesture_active {
		return
	}
	ids := make([dynamic]u32, 0, len(state.opening_windows), context.temp_allocator)
	for id in state.opening_windows {append(&ids, id)}
	sort_ids(ids[:])
	for id in ids {
		w := state.manager.windows[id]
		if w == nil || w.opening.phase == .Excluded || w.opening.phase == .Admitted {
			if err := opening_release(state, id); err == "" {
				delete_key(&state.opening_windows, id)
			}
			continue
		}
		if w.opening.phase == .Pending {
			if element := state.windows[id]; element != nil {
				w.ordered_in = window_ordered_in(state, id)
				if sid := window_space(state, id); sid != 0 {
					w.space = sid
				}
				if observed, valid := window_frame(element).?; valid {
					w.frame = observed
				}
			}
			opening_attempt(state, w)
			continue
		}
		if err := opening_release(state, id); err != "" {
			continue
		}
		busy := false
		for window in state.animations {
			if other := state.manager.windows[window]; other != nil && other.space == w.space {
				busy = true; break
			}
		}
		if s := space_by_id(&state.manager, w.space);
		   s != nil &&
		   s.view.layout == .Scroll &&
		   (s.view.scroll.motion.active || s.view.scroll.geometry_active) {
			busy = true
		}
		if !busy {
			if err := finish_opening(&state.manager, w); err != "" {
				fmt.eprintln("shoji: finish opening:", err)
			}
		}
	}
	opening_notice_tick(state)
}

opening_stop :: proc(state: ^State) {
	// Conceal can fail before it stores a guard. Stage already forced the
	// layer below, so those pending windows still need the same restore.
	for id in state.opening_windows {
		w := state.manager.windows[id]
		if w == nil || !w.opening.staged || w.opening.phase != .Pending {
			continue
		}
		if _, guarded := state.opening_guards[id]; guarded {
			continue
		}
		perform(&state.manager, {kind = .Layer, window = id, value = w.opening.original_layer})
	}
	for id, guard in state.opening_guards {
		if w := state.manager.windows[id]; w != nil && w.opening.phase == .Pending {
			perform(&state.manager, {kind = .Layer, window = id, value = w.opening.original_layer})
		}
		if err := opening_release(state, id); err != "" {
			fmt.eprintln("shoji: opening recovery:", err)
			native_proxy_destroy(state, guard.proxy)
		}
	}
	delete(state.opening_guards); delete(state.opening_windows)
	surface_destroy(state, state.opening_notice)
}

foreign import window_sls "system:SkyLight.framework"

// Window observations
// ------------------------------------------------------------------------

// A single native read, with unknown values retained explicitly. Borrowed
// strings remain valid for the refresh tick; reconciliation owns model strings.
Window_Appearance :: struct {
	sub_level:  Maybe(i32),
	ordered_in: Maybe(bool),
	tags:       Maybe(u64),
	opacity:    Maybe(f64),
	level:      Maybe(i32),
	can_move:   Maybe(bool),
}

attribute_capability :: proc(element: Ref, name: string) -> Maybe(bool) {
	key := cf_string(name); defer CFRelease(key)
	value: bool
	if AXUIElementIsAttributeSettable(element, key, &value) != 0 {
		return nil
	}
	return value
}

collect_window :: proc(
	state: ^State,
	app: Application,
	element: Ref,
	id: u32,
	pid: i32,
	policy: int,
	hidden: bool,
) -> Window {
	result: Window
	sid := window_space(state, id)
	display: u32
	if s := space_by_id(&state.manager, sid); s != nil {
		display = s.display
	}
	w := &result
	frame := window_frame(element)
	root, parent := window_is_root(state, id, element, app.element)
	w^ = {
		id                    = id,
		pid                   = pid,
		app                   = app.name,
		title                 = attribute_text(element, "AXTitle"),
		ordered_in            = window_ordered_in(state, id),
		root_window           = root,
		parent                = parent,
		frame                 = frame.? or_else Rect{},
		frame_valid           = frame != nil,
		can_resize            = attribute_capability(element, "AXSize"),
		application_accessory = policy == 1,
		space                 = sid,
		display               = display,
		hidden                = hidden,
		minimized             = attribute_bool(element, "AXMinimized"),
		fullscreen            = attribute_bool(element, "AXFullScreen"),
		opacity               = 1,
		layer                 = "normal",
	}
	// Roles are immutable for an existing window; avoid extra synchronous reads.
	if old := state.manager.windows[id];
	   old == nil || old.pid != pid || old.role == "" || old.subrole == "" {
		w.role = attribute_text(element, "AXRole")
		w.subrole = attribute_text(element, "AXSubrole")
	}
	return result
}

collect_window_appearance :: proc(state: ^State, element: Ref, id: u32) -> Window_Appearance {
	result: Window_Appearance
	result.tags, result.level = window_query_appearance(state.connection, id)
	result.sub_level = window_sublevel(state.connection, id)
	alpha: f32
	if SLSGetWindowAlpha(state.connection, id, &alpha) == 0 {
		result.opacity = f64(alpha)
	}
	result.can_move = attribute_capability(element, "AXPosition")
	result.ordered_in = window_ordered_in(state, id)
	return result
}

reconcile_window :: proc(
	state: ^State,
	app: Application,
	element: Ref,
	value: Window,
) -> (
	^Window,
	bool,
) {
	m := &state.manager
	w := m.windows[value.id]
	if w != nil && w.pid != value.pid {
		window_reference_remove(state, value.id, state.applications[w.pid].observer)
		remove_window(m, value.id)
	}
	window_reference_update(state, value.id, element, app.observer)
	return reconcile_window_model(m, value)
}

// Native queries stay in collection. Unknown capabilities and spaces preserve
// the previous observation; a failed query must not revoke a known capability.
reconcile_window_model :: proc(m: ^Manager, value: Window) -> (^Window, bool) {
	w := m.windows[value.id]
	created := w == nil
	if created {
		w = add_window(m, value)
		if w.rule_error != "" {
			fmt.eprintf("shoji: window %d rule deferred: %s\n", w.id, w.rule_error)
		}
	} else {
		if w.role == "" {
			w.role = strings.clone(value.role)
		}
		if w.subrole == "" {
			w.subrole = strings.clone(value.subrole)
		}
		if value.ordered_in != nil {
			w.ordered_in = value.ordered_in
		}
		if value.can_resize != nil {
			w.can_resize = value.can_resize
		}
		if value.root_window != nil {
			w.root_window = value.root_window
			w.parent = value.parent
		}
		w.hidden, w.minimized, w.fullscreen = value.hidden, value.minimized, value.fullscreen
		if (value.frame_valid.? or_else true) && valid_frame(value.frame) {
			w.frame = value.frame
			w.frame_valid = true
			size_feedback_late_result(w, value.frame)
		}
		if w.title != value.title {
			delete(w.title); w.title = strings.clone(value.title)
		}
		if value.space != 0 {
			w.space, w.display = value.space, value.display
		}
	}
	return w, created
}

reconcile_window_appearance :: proc(w: ^Window, appearance: Window_Appearance) {
	if tags, known := appearance.tags.?; known {
		w.sticky = tags & (1 << 11) != 0; w.shadow = tags & (1 << 3) == 0
	}
	if level, known := appearance.level.?; known {
		w.level = level
	}
	if sub_level, known := appearance.sub_level.?; known {
		w.sub_level = sub_level
		w.layer = sub_level < 0 ? "below" : (sub_level > 0 ? "above" : "normal")
	}
	if opacity, known := appearance.opacity.?; known {
		w.opacity = opacity
	}
	if can_move, known := appearance.can_move.?; known {
		w.can_move = can_move
	}
	if w.scratchpad != "" {
		if ordered, known := appearance.ordered_in.?; known {
			w.scratchpad_hidden = !ordered
		}
	}
}

refresh_window_rules :: proc(m: ^Manager, w: ^Window) {
	previous_error := strings.clone(w.rule_error, context.temp_allocator)
	if err := apply_rules(m, w); err != "" && err != previous_error {
		fmt.eprintf("shoji: window %d rule deferred: %s\n", w.id, err)
	}
}

// Visibility and reference retention
// ------------------------------------------------------------------------

Window_Presence :: enum {
	Unknown,
	Present,
	Missing,
	Reused,
}
Window_Observation :: struct {
	presence:   Window_Presence,
	ordered_in: Maybe(bool),
}
Window_Probe :: struct {
	probe: proc(user: rawptr, state: ^State, window: ^Window) -> Window_Observation,
	user:  rawptr,
}
foreign window_sls {
	SLSConnectionGetPID :: proc "c" (connection: i32, pid: ^i32) -> i32 ---
}
window_ordered_in :: proc(state: ^State, id: u32) -> Maybe(bool) {
	ordered: u8
	if SLSWindowIsOrderedIn(state.connection, id, &ordered) != 0 {
		return nil
	}
	return ordered != 0
}
native_window_probe :: proc(user: rawptr, state: ^State, window: ^Window) -> Window_Observation {
	id := window.id
	number := CFNumberCreate(nil, 3, &id); defer CFRelease(number)
	array := CFArrayCreate(nil, &number, 1, nil); defer CFRelease(array)
	query := SLSWindowQueryWindows(state.connection, array, 1)
	if query == nil {
		return {}
	}
	defer CFRelease(query)
	iterator := SLSWindowQueryResultCopyWindows(query)
	if iterator == nil {
		return {}
	}
	defer CFRelease(iterator)
	count := SLSWindowIteratorGetCount(iterator)
	if count == 0 {
		return {presence = .Missing}
	}
	if count != 1 || !SLSWindowIteratorAdvance(iterator) {
		return {}
	}
	owner, ok := animation_recovery_query_owner(state.connection, id)
	pid: i32
	if !ok || SLSConnectionGetPID(owner, &pid) != 0 {
		return {}
	}
	if pid != window.pid {
		return {presence = .Reused}
	}
	return {presence = .Present, ordered_in = window_ordered_in(state, id)}
}
retain_unlisted_windows :: proc(state: ^State, seen: ^map[u32]bool, seen_apps: map[i32]bool) {
	probe := state.window_probe.probe
	if probe == nil {
		probe = native_window_probe
	}
	for id, window in state.manager.windows {
		if seen[id] || !seen_apps[window.pid] || state.windows[id] == nil {
			continue
		}
		// Native inactive tabs can disappear from AXWindows without destruction.
		// A failed WindowServer query is inconclusive; retain the last observation.
		observation := probe(state.window_probe.user, state, window)
		if observation.presence == .Missing || observation.presence == .Reused {
			continue
		}
		seen[id] = true
		if app, exists := state.applications[window.pid]; exists {
			window.hidden = app.hidden
		}
		if observation.presence == .Present && observation.ordered_in != nil {
			window.ordered_in = observation.ordered_in
		}
	}
}
WINDOW_NOTIFICATIONS :: []string {
	"AXUIElementDestroyed",
	"AXMoved",
	"AXResized",
	"AXTitleChanged",
	"AXWindowMiniaturized",
	"AXWindowDeminiaturized",
}
window_reference_remove :: proc(state: ^State, id: u32, observer: Ref) {
	previous := state.windows[id]
	if previous == nil {
		return
	}
	if observer != nil {
		for name in WINDOW_NOTIFICATIONS {
			key := cf_string(name)
			AXObserverRemoveNotification(observer, previous, key)
			CFRelease(key)
		}
	}
	CFRelease(previous)
	delete_key(&state.windows, id)
}
window_reference_update :: proc(state: ^State, id: u32, element, observer: Ref) {
	previous := state.windows[id]
	if previous != nil && CFEqual(previous, element) {
		return
	}
	window_reference_remove(state, id, observer)
	state.windows[id] = CFRetain(element)
	if observer != nil {
		for name in WINDOW_NOTIFICATIONS {
			observe(state, observer, element, name)
		}
	}
}

foreign import sls "system:SkyLight.framework"
foreign import libc "system:c"

// Iterator getters and the sublevel RPC follow yabai's macOS 27 port:
// https://github.com/LCS-Dev-Ergos/yabai/blob/9da3923176d88e6c44a7802fa7d6374ae40414f4/src/window.c
// Unlike the exported getters, these read windows owned by other connections.
@(default_calling_convention = "c")
foreign sls {
	SLSWindowIteratorGetTags :: proc(iterator: Ref) -> u64 ---
	SLSWindowIteratorGetLevel :: proc(iterator: Ref) -> i32 ---
	SLSWindowIteratorGetWindowID :: proc(iterator: Ref) -> u32 ---
}

window_query_appearance :: proc(cid: i32, wid: u32) -> (tags: Maybe(u64), level: Maybe(i32)) {
	id := wid
	number := CFNumberCreate(nil, 3, &id)
	if number == nil {
		return
	}
	defer CFRelease(number)
	array := CFArrayCreate(nil, &number, 1, nil)
	if array == nil {
		return
	}
	defer CFRelease(array)
	query := SLSWindowQueryWindows(cid, array, 1)
	if query == nil {
		return
	}
	defer CFRelease(query)
	iterator := SLSWindowQueryResultCopyWindows(query)
	if iterator == nil {
		return
	}
	defer CFRelease(iterator)
	if SLSWindowIteratorGetCount(iterator) != 1 ||
	   !SLSWindowIteratorAdvance(iterator) ||
	   SLSWindowIteratorGetWindowID(iterator) != wid {
		return
	}
	return SLSWindowIteratorGetTags(iterator), SLSWindowIteratorGetLevel(iterator)
}

// All fields have four-byte alignment, matching the MIG wire layout. Extra
// storage accepts a receive trailer without letting it overlap the payload.
Sublevel_Message :: struct {
	bits, size, remote, local, voucher: u32,
	id:                                 i32,
	ndr:                                [8]u8,
	code:                               u32,
	value:                              i32,
	storage:                            [88]u8,
}
SUBLEVEL_NDR :: [8]u8{0, 0, 0, 0, 1, 0, 0, 0}

decode_sublevel_reply :: proc(reply: ^Sublevel_Message, request: i32) -> Maybe(i32) {
	if reply.size != 40 ||
	   reply.id != request + 100 ||
	   reply.bits & 0x80000000 != 0 ||
	   reply.ndr != SUBLEVEL_NDR ||
	   reply.code != 0 {
		return nil
	}
	return reply.value
}

@(default_calling_convention = "c")
foreign libc {
	_dyld_image_count :: proc() -> u32 ---
	_dyld_get_image_name :: proc(index: u32) -> cstring ---
	_dyld_get_image_header :: proc(index: u32) -> rawptr ---
	_dyld_get_image_vmaddr_slide :: proc(index: u32) -> uintptr ---
	mach_reply_port :: proc() -> u32 ---
	mach_task_self :: proc() -> u32 ---
	mach_port_destroy :: proc(task, port: u32) -> i32 ---
	mach_msg :: proc(message: rawptr, options, send_size, receive_size, receive_port, timeout, notify: u32) -> i32 ---
	mach_msg_destroy :: proc(message: rawptr) ---
}

Readback_Header :: struct {
	magic, cpu, subtype, kind, commands, commands_size, flags, reserved: u32,
}
Readback_Command :: struct {
	kind, size: u32,
}
Readback_Segment :: struct {
	kind, size:                          u32,
	name:                                [16]u8,
	address, vm_size, offset, file_size: u64,
	maxprot, initprot, sections, flags:  u32,
}
Readback_Symtab :: struct {
	kind, size, symbols, count, strings, strings_size: u32,
}
Readback_Symbol :: struct {
	name:          u32,
	kind, section: u8,
	description:   u16,
	value:         u64,
}

// Restrict lookup to bounded tables in the already loaded SkyLight image.
// No scanning for machine-code patterns or dependency on a fixed address.
readback_image_symbol :: proc(base: rawptr, slide: uintptr, name: string) -> rawptr {
	if base == nil {
		return nil
	}
	header := (^Readback_Header)(base)
	if header.magic != 0xfeedfacf ||
	   header.commands > 1000 ||
	   header.commands_size > 16 * 1024 * 1024 {
		return nil
	}
	address := uintptr(base)
	if address > max(uintptr) - size_of(Readback_Header) - uintptr(header.commands_size) {
		return nil
	}
	offset := uintptr(size_of(Readback_Header))
	remaining := uintptr(header.commands_size)
	linkedit, text: ^Readback_Segment
	table: ^Readback_Symtab
	for _ in 0 ..< header.commands {
		if remaining < size_of(Readback_Command) {
			return nil
		}
		command := (^Readback_Command)(address + offset)
		if command.size < size_of(Readback_Command) || uintptr(command.size) > remaining {
			return nil
		}
		if command.kind == 0x19 && command.size >= size_of(Readback_Segment) {
			segment := (^Readback_Segment)(command)
			if strings.has_prefix(string(segment.name[:]), "__LINKEDIT\x00") {
				linkedit = segment
			}
			if strings.has_prefix(string(segment.name[:]), "__TEXT\x00") {
				text = segment
			}
		} else if command.kind == 2 && command.size >= size_of(Readback_Symtab) {
			table = (^Readback_Symtab)(command)
		}
		offset += uintptr(command.size); remaining -= uintptr(command.size)
	}
	if linkedit == nil || text == nil || table == nil || linkedit.address < linkedit.offset {
		return nil
	}
	if linkedit.offset > max(u64) - linkedit.file_size {
		return nil
	}
	end := linkedit.offset + linkedit.file_size
	if u64(table.symbols) < linkedit.offset ||
	   u64(table.strings) < linkedit.offset ||
	   u64(table.symbols) + u64(table.count) * size_of(Readback_Symbol) > end ||
	   u64(table.strings) + u64(table.strings_size) > end {
		return nil
	}
	origin := linkedit.address - linkedit.offset
	if origin > max(u64) - u64(slide) || end > max(u64) - origin - u64(slide) {
		return nil
	}
	origin += u64(slide)
	symbols := ([^]Readback_Symbol)(uintptr(origin + u64(table.symbols)))
	names := ([^]u8)(uintptr(origin + u64(table.strings)))
	for index in 0 ..< table.count {
		symbol := symbols[index]
		if symbol.kind & 0xe0 != 0 ||
		   symbol.kind & 0x0e != 0x0e ||
		   symbol.name >= table.strings_size {
			continue
		}
		available := int(table.strings_size - symbol.name)
		if available <= len(name) {
			continue
		}
		candidate := names[symbol.name:][:len(name) + 1]
		if string(candidate[:len(name)]) != name || candidate[len(name)] != 0 {
			continue
		}
		if symbol.value < text.address ||
		   symbol.value - text.address >= text.vm_size ||
		   symbol.value > max(u64) - u64(slide) {
			return nil
		}
		return rawptr(uintptr(symbol.value + u64(slide)))
	}
	return nil
}

Readback_Port :: proc "c" (cid: i32) -> u32
readback_once: sync.Once
readback_port: Readback_Port
readback_request: i32

initialize_window_readback :: proc() {
	version: [64]u8
	length := uintptr(len(version))
	if sysctlbyname("kern.osproductversion", &version[0], &length, nil, 0) != 0 {
		return
	}
	major: int
	for ch in version {
		if ch < '0' || ch > '9' {
			break
		}
		major = major * 10 + int(ch - '0')
		if major > 100 {
			return
		}
	}
	switch major {
	case 11, 12, 13, 14, 15:
		readback_request = 0x73c3
	case 26, 27:
		readback_request = 0x76e3
	case:
		return
	}
	for index in 0 ..< _dyld_image_count() {
		path := _dyld_get_image_name(index)
		if path == nil {
			continue
		}
		if string(path) !=
			   "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight" &&
		   string(path) != "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight" {
			continue
		}
		readback_port = Readback_Port(
			readback_image_symbol(
				_dyld_get_image_header(index),
				_dyld_get_image_vmaddr_slide(index),
				"_CGSGetConnectionPortById",
			),
		)
		return
	}
}

window_sublevel :: proc(cid: i32, wid: u32) -> Maybe(i32) {
	sync.once_do(&readback_once, initialize_window_readback)
	if readback_port == nil || readback_request == 0 {
		return nil
	}
	remote := readback_port(cid)
	if remote == 0 {
		return nil
	}
	reply := mach_reply_port()
	if reply == 0 {
		return nil
	}
	// A private receive right avoids stale replies after a timeout. Destroy it on
	// every exit, including send failure and invalid/error replies.
	defer mach_port_destroy(mach_task_self(), reply)
	message := Sublevel_Message {
		bits   = 0x1513,
		size   = 36,
		remote = remote,
		local  = reply,
		id     = readback_request,
		ndr    = SUBLEVEL_NDR,
		code   = wid,
	}
	// SEND_MSG | RCV_MSG | SEND_TIMEOUT | RCV_TIMEOUT; milliseconds, bounded.
	if mach_msg(&message, 0x113, 36, size_of(Sublevel_Message), reply, 100, 0) != 0 {
		return nil
	}
	if message.bits & 0x80000000 != 0 {
		mach_msg_destroy(&message)
		return nil
	}
	return decode_sublevel_reply(&message, readback_request)
}
