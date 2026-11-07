package shoji

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

// Window commands
// ------------------------------------------------------------------------

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
		if response := window_command_one(m, command[:count]);
		   response.failed {
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
	n: ^Node
	if s != nil {
		n = find(s.view.root, w.id)
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
			if err := scroll_cycle_height(m, &s.view, w, operand == "prev");
			   err != "" {
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
				return failure(
					"maximum size must not be smaller than minimum size",
				)
			}
			w.min_width, w.min_height, w.max_width, w.max_height =
				values[0], values[1], values[2], values[3]
			s.view.scroll.reveal = true
		case "--cycle-column-width":
			if operand != "next" && operand != "prev" {
				return failure("cycle-column-width expects next or prev")
			}
			scroll_cycle_width(&s.view, n, operand == "prev")
		case "--row-height":
			if err := scroll_set_row(m, &s.view, w, operand); err != "" {
				return failure(err)
			}
		case "--column-display":
			if operand != "normal" &&
			   operand != "tabbed" &&
			   operand != "toggle" {
				return failure(
					"column-display expects normal, tabbed, or toggle",
				)
			}
			n.column_tabbed =
				operand == "toggle" ? !n.column_tabbed : operand == "tabbed"
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
			scroll_move_column(&s.view, n, operand == "west")
		}
	case "--column-width":
		if s == nil || s.view.layout != .Scroll {
			return failure("column-width requires scroll layout")
		}
		if err := scroll_set_width(&s.view, w.id, operand); err != "" {
			return failure(err)
		}
	case "--center":
		if s == nil || s.view.layout != .Scroll || n == nil {
			return failure("center requires a scrolling column")
		}
		if operand != "" {
			return failure("center takes no operand")
		}
		view_update(&s.view)
		scroll_reveal(&s.view, w.id, true)
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
			n.column_revision += 1
			n.column_preset = nil
			s.view.scroll.reveal = true
		case "float":
			if s == nil {
				return failure("window has no space")
			}
			w.floating = !w.floating
			if !w.floating && w.opening.phase == .Excluded {
				w.opening.phase = .Admitted
			}
			w.scroll_frame = {}
			if w.floating {
				remove(&s.view, w.id)
			} else if layout_admitted(w) {
				add(&s.view, w.id, m.focused)
			}
		case "zoom-parent", "zoom-fullscreen":
			if s != nil &&
			   s.view.layout == .Scroll &&
			   operand == "zoom-parent" {
				return failure(
					"parent split zoom is unavailable in scroll layout",
				)
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
				perform(
					m,
					Action {
						kind = .Fullscreen,
						window = w.id,
						flag = !w.fullscreen,
					},
				),
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
			if err := perform(
				m,
				{kind = .Frame, window = w.id, frame = target},
			); err != "" {
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
			return result(
				perform(m, {kind = .Scale, window = w.id, frame = bounds}),
			)
		case "sticky":
			if err := perform(
				m,
				{kind = .Sticky, window = w.id, flag = !w.sticky},
			); err != "" {
				return failure(err)
			}
			w.sticky = !w.sticky
			if err := sync_window_membership(m, w, w.space); err != "" {
				return failure(err)
			}
			return result(flush(m, s))
		case "shadow":
			if err := perform(
				m,
				{kind = .Shadow, window = w.id, flag = !w.shadow},
			); err != "" {
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
		other := find(target_space.view.root, target.id)
		if n == nil || other == nil {
			return failure("both windows must be managed")
		}
		if op == "--warp" &&
		   other != n &&
		   !can_add(&target_space.view, target.id) {
			return failure("target stack is full")
		}
		if target_space != s {
			if op == "--stack" {
				return failure("stack target must be on the same space")
			}
			if err := perform(
				m,
				Action{kind = .Space, window = w.id, space = target_space.id},
			); err != "" {
				return failure(err)
			}
			if op == "--swap" {
				if err := perform(
					m,
					Action{kind = .Space, window = target.id, space = s.id},
				); err != "" {
					if rollback := perform(
						m,
						Action{kind = .Space, window = w.id, space = s.id},
					); rollback != "" {
						remove(&s.view, w.id)
						w.space, w.display =
							target_space.id, target_space.display
						add(&target_space.view, w.id, target.id)
						return failure(
							errorf("%s; rollback failed: %s", err, rollback),
						)
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
				remove(&s.view, w.id)
				add(&target_space.view, w.id, target.id)
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
			if !swap(n, other) {
				return failure("windows are already in the same stack")
			}
			if s.view.layout == .Scroll { s.view.scroll.fill_after_removal = true }
		}
		if s.view.layout == .Scroll {
			s.view.scroll.reveal = true
		}
		if op == "--stack" {
			if other == n || n.count == MAX_STACK {
				return failure("invalid or full stack")
			}
			remove(&s.view, target.id)
			n = find(s.view.root, w.id)
			stack_push(n, target.id)
		}
		if op == "--warp" {
			width := n.column_width
			size, preset, full := n.column_size, n.column_preset, n.column_full
			remove(&s.view, w.id)
			if s.view.layout == .Scroll {
				if anchor := find(s.view.root, target.id); anchor != nil {
					anchor.insert_first =
						operand == "west" || operand == "prev"
				}
			}
			add(&s.view, w.id, target.id)
			if s.view.layout == .Scroll {
				if placed := find(s.view.root, w.id); placed != nil {
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
		if s != nil &&
		   s.view.layout == .Scroll &&
		   (operand == "north" || operand == "south") {
			return failure(
				"use --insert stack for scrolling rows, or east/west for columns",
			)
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
										? Split.Vertical \
										: Split.Horizontal))
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
		s.view.insertion = w.id
	case "--move", "--resize":
		parts := strings.split(operand, ":", context.temp_allocator)
		if len(parts) != 3 {
			return failure("expected mode:x:y")
		}
		values: [2]f64
		if !parse_numbers(
			strings.join(parts[1:], ":", context.temp_allocator),
			values[:],
		) {
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
		if err := perform(
			m,
			Action{kind = .Frame, window = w.id, frame = frame},
		); err != "" {
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
		if err := perform(m, {kind = .Frame, window = w.id, frame = frame});
		   err != "" {
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
		   !can_add(&target.view) {
			return failure("target stack is full")
		}
		// Tile in the destination first so the move can carry its landing
		// position (WindowServer adapter, C4); undone if the move fails.
		landing, staged := space_landing(w, s, target)
		if err := perform(
			m,
			Action{kind = .Space, window = w.id, space = target.id, frame = landing},
		); err != "" {
			if staged {remove(&target.view, w.id)}
			return failure(err)
		}
		if s != nil {
			remove(&s.view, w.id)
		}
		w.space = target.id
		w.display = target.display
		if w.opening.phase == .Excluded && managed(w) {
			w.opening.phase = .Admitted
		}
		if layout_admitted(w) && !staged {
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
		override := value != 0
		if !override {
			value =
				m.window_opacity \
					? (w.id == m.focused \
							? m.active_opacity \
							: m.normal_opacity) \
					: 1.0
		}
		if err := perform(
			m,
			Action{kind = .Opacity, window = w.id, value = value},
		); err != "" {
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
		if err := perform(
			m,
			Action{kind = .Layer, window = w.id, value = level},
		); err != "" {
			return failure(err)
		}; w.layer = level < 0 ? "below" : (level > 0 ? "above" : "normal")
		w.layer_override = operand != "auto"; return success()
	case:
		return failure(errorf("unsupported window operation '%s'", op))
	}
	return result(flush(m, s))
}

replace_window_id :: proc(n: ^Node, old, fresh: u32) {
	for i in 0 ..< n.count {
		if n.windows[i] == old {
			n.windows[i] = fresh
		}
		if n.order[i] == old {
			n.order[i] = fresh
		}
	}
}

resize_window :: proc(
	m: ^Manager,
	w: ^Window,
	handle: string,
	dx, dy: f64,
) -> string {
	if s := space_by_id(m, w.space);
	   s != nil && s.view.layout == .Scroll && find(s.view.root, w.id) != nil {
		if (handle != "left" && handle != "right") || dy != 0 {
			return(
				"scroll resize supports left/right width changes; use --column-width for an absolute width" \
			)
		}
		delta := handle == "left" ? -dx : dx
		if err := scroll_set_width(
			&s.view,
			w.id,
			fmt.tprintf("rel:%g", delta),
		); err != "" {
			return err
		}
		return flush(m, s)
	}
	if handle == "abs" {
		s := space_by_id(m, w.space)
		if s != nil &&
		   s.view.layout != .Float &&
		   find(s.view.root, w.id) != nil {
			return "absolute resize requires a floating window"
		}
		if dx <= 0 || dy <= 0 {
			return "size must be positive"
		}
		frame := w.frame; frame.w = dx; frame.h = dy
		if err := perform(m, {kind = .Frame, window = w.id, frame = frame});
		   err != "" {
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
		return(
			"resize expects abs, top, bottom, left, right, or a corner handle" \
		)
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
