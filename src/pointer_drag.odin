package shoji

import "core:fmt"
import "core:math"
import layout "layout"

// Pointer interaction
// ------------------------------------------------------------------------

Mouse_Action :: enum {
	None,
	Move,
	Resize,
}
Focus_Follows_Mouse :: enum {
	Off,
	Autofocus,
	Autoraise,
}
Mouse_Config :: struct {
	scroll: bool,
	stack_swipe: bool,
	three_finger_horizontal: bool,
	edge: Drag_Edge_Config,
	modifier: u64,
	action1, action2: Mouse_Action,
	focus: Focus_Follows_Mouse,
	follows_focus, drop_stack: bool,
}
MOUSE_MODIFIERS :: u64(
	(1 << 17) | (1 << 18) | (1 << 19) | (1 << 20) | (1 << 23),
)
mouse_defaults :: proc() -> Mouse_Config {
	return {
		modifier = 1 << 23,
		action1 = .Move,
		action2 = .Resize,
		edge = {enabled = true, width = 30, delay = .1, speed = 1500},
	}
}
mouse_config :: proc(
	m: ^Manager,
	s: ^Space,
	name, value: string,
	setting: bool,
) -> Response {
	if s != nil {
		return failure("mouse settings are global")
	}
	c := &m.mouse
	switch name {
	case "three_finger_horizontal":
		if !setting { return success(c.three_finger_horizontal ? "on" : "off") }
		if value != "on" && value != "off" { return failure("three_finger_horizontal expects on or off") }
		c.three_finger_horizontal = value == "on"
		return success()
	case "stack_swipe":
		if !setting { return success(c.stack_swipe ? "on" : "off") }
		if value != "on" && value != "off" { return failure("stack_swipe expects on or off") }
		c.stack_swipe = value == "on"
		return success()
	case "scroll_drag_edge_scroll":
		if !setting {
			return success(c.edge.enabled ? "on" : "off")
		}
		if value != "on" && value != "off" {
			return failure("scroll_drag_edge_scroll expects on or off")
		}
		c.edge.enabled = value == "on"
		return success()
	case "scroll_drag_edge_width",
	     "scroll_drag_edge_delay",
	     "scroll_drag_edge_speed":
		target :=
			name == "scroll_drag_edge_width" \
				? &c.edge.width \
				: (name == "scroll_drag_edge_delay" \
						? &c.edge.delay \
						: &c.edge.speed)
		if !setting {
			return success(fmt.tprintf("%g", target^))
		}
		values: [1]f64
		maximum :=
			name == "scroll_drag_edge_width" \
				? f64(500) \
				: (name == "scroll_drag_edge_delay" ? f64(5) : f64(10000))
		if !parse_numbers(value, values[:]) ||
		   values[0] < 0 ||
		   (name != "scroll_drag_edge_delay" && values[0] == 0) ||
		   values[0] > maximum {
			return failure(
				"invalid edge-scroll setting (width in pixels, delay in seconds, speed in pixels/second)",
			)
		}
		target^ = values[0]
		return success()
	case "scroll_gestures":
		if !setting {
			return success(c.scroll ? "on" : "off")
		}
		if value != "on" && value != "off" {
			return failure("scroll_gestures expects on or off")
		}
		c.scroll = value == "on"
		return success()
	case "mouse_modifier":
		names := []string{"alt", "shift", "cmd", "ctrl", "fn"}
		bits := []u64{1 << 19, 1 << 17, 1 << 20, 1 << 18, 1 << 23}
		for name, i in names {
			if !setting && c.modifier == bits[i] {
				return success(name)
			}
			if setting && value == name {
				c.modifier = bits[i]; return success()
			}
		}
		return failure("mouse_modifier expects alt, shift, cmd, ctrl, or fn")
	case "mouse_action1", "mouse_action2":
		action := name == "mouse_action1" ? &c.action1 : &c.action2
		names := [Mouse_Action]string {
			.None   = "none",
			.Move   = "move",
			.Resize = "resize",
		}
		if !setting {
			return success(names[action^])
		}
		for name, kind in names {
			if name == value {
				action^ = kind; return success()
			}
		}
		return failure("mouse action expects none, move, or resize")
	case "focus_follows_mouse":
		names := [Focus_Follows_Mouse]string {
			.Off       = "off",
			.Autofocus = "autofocus",
			.Autoraise = "autoraise",
		}
		if !setting {
			return success(names[c.focus])
		}
		for name, kind in names {
			if name == value {
				c.focus = kind; return success()
			}
		}
		return failure(
			"focus_follows_mouse expects off, autofocus, or autoraise",
		)
	case "mouse_follows_focus":
		if !setting {
			return success(c.follows_focus ? "on" : "off")
		}
		if value != "on" && value != "off" {
			return failure("mouse_follows_focus expects on or off")
		}
		c.follows_focus = value == "on"
	case "mouse_drop_action":
		if !setting {
			return success(c.drop_stack ? "stack" : "swap")
		}
		if value != "stack" && value != "swap" {
			return failure("mouse_drop_action expects swap or stack")
		}
		c.drop_stack = value == "stack"
	case:
		return failure("unknown mouse setting")
	}
	return success()
}
Mouse_Point :: struct {
	x, y: f64,
}
Mouse_Drag :: struct {
	window: u32,
	action: Mouse_Action,
	origin, previous: Mouse_Point,
	frame: Rect,
	left, top: bool,
	lock_x, lock_y: bool,
}
// Capture native border drags before the app can resize independently of its
// tile. Interior clicks and floating windows keep their native behavior.
mouse_border_resize :: proc(
	m: ^Manager,
	id: u32,
	point: Mouse_Point,
) -> Mouse_Drag {
	w := m.windows[id]
	if w == nil || !managed(w) || !(w.can_resize.? or_else true) {
		return {}
	}
	s := space_by_id(m, w.space)
	if s == nil ||
	   !s.visible ||
	   s.view.layout == .Float ||
	   layout.find(s.view.root, id) == nil ||
	   w.windowed_frame != nil {
		return {}
	}
	r := w.frame
	margin :: 5.0
	if r.w <= 0 ||
	   r.h <= 0 ||
	   point.x < r.x - margin ||
	   point.x > r.x + r.w + margin ||
	   point.y < r.y - margin ||
	   point.y > r.y + r.h + margin {
		return {}
	}
	x_edge :=
		math.abs(point.x - r.x) <= margin ||
		math.abs(point.x - r.x - r.w) <= margin
	y_edge :=
		math.abs(point.y - r.y) <= margin ||
		math.abs(point.y - r.y - r.h) <= margin
	if !x_edge && !y_edge {
		return {}
	}
	drag := mouse_begin(m, id, .Resize, point)
	drag.lock_x, drag.lock_y = !x_edge, !y_edge
	return drag
}
mouse_begin :: proc(
	m: ^Manager,
	id: u32,
	action: Mouse_Action,
	point: Mouse_Point,
) -> Mouse_Drag {
	w := m.windows[id]
	if w == nil ||
	   w.fullscreen ||
	   w.minimized ||
	   w.hidden ||
	   !(w.ordered_in.? or_else true) ||
	   action == .None {
		return {}
	}
	return {
		window = id,
		action = action,
		origin = point,
		previous = point,
		frame = w.frame,
		left = point.x < w.frame.x + w.frame.w / 2,
		top = point.y < w.frame.y + w.frame.h / 2,
	}
}
mouse_drag_frame :: proc(d: Mouse_Drag, point: Mouse_Point) -> Rect {
	r := d.frame; dx := point.x - d.origin.x; dy := point.y - d.origin.y
	if d.action == .Move {
		r.x += dx; r.y += dy; return r
	}
	if d.left {
		r.w = max(1, r.w - dx); r.x = d.frame.x + d.frame.w - r.w
	} else {
		r.w = max(1, r.w + dx)
	}
	if d.top {
		r.h = max(1, r.h - dy); r.y = d.frame.y + d.frame.h - r.h
	} else {
		r.h = max(1, r.h + dy)
	}
	return r
}
mouse_fence :: proc(n: ^layout.Node, split: layout.Split, leading: bool) -> ^layout.Node {
	for child := n; child != nil && child.parent != nil; child = child.parent {
		parent := child.parent
		if parent.split == split &&
		   (leading ? parent.right == child : parent.left == child) {
			return parent
		}
	}
	return nil
}
mouse_update :: proc(
	m: ^Manager,
	d: ^Mouse_Drag,
	point: Mouse_Point,
) -> string {
	point := point
	if d.lock_x {
		point.x = d.origin.x
	}
	if d.lock_y {
		point.y = d.origin.y
	}
	// Pointer motion already supplies the timing. Animating each frame would
	// make the layout trail the pointer and repeatedly create proxy windows.
	duration := m.animation_duration
	m.animation_duration = 0
	defer m.animation_duration = duration
	w := m.windows[d.window]
	if w == nil {
		return "dragged window no longer exists"
	}
	if w.fullscreen ||
	   w.minimized ||
	   w.hidden ||
	   !(w.ordered_in.? or_else true) {
		return "dragged window is no longer available"
	}
	s := space_by_id(m, w.space)
	n: ^layout.Node
	if s != nil && s.view.layout != .Float {
		n = layout.find(s.view.root, w.id)
	}
	if n == nil {
		r := mouse_drag_frame(d^, point)
		if err := perform(m, {kind = .Frame, window = w.id, frame = r});
		   err != "" {
			return err
		}
		w.frame = r
	} else if d.action == .Resize {
		if s.view.layout == .Scroll {
			delta := (point.x - d.previous.x) * (d.left ? f64(-1) : f64(1))
			if delta != 0 {
				if err := layout.scroll_set_width(
					&s.view,
					w.id,
					fmt.tprintf("rel:%g", delta),
				); err != "" {
					return err
				}
				if err := flush(m, s, true); err != "" {
					return err
				}
			}
			d.previous = point
			return ""
		}
		if n == s.view.root && n.count == 1 && n.zoom == nil {
			area := n.frame
			if area.w <= 0 || area.h <= 0 {
				return "single tile requires positive usable dimensions"
			}
			r := mouse_drag_frame(d^, point)
			minimum_w, minimum_h := min(120, area.w), min(80, area.h)
			if d.left {
				right := clamp(
					d.frame.x + d.frame.w,
					area.x + minimum_w,
					area.x + area.w,
				)
				r.x = clamp(r.x, area.x, right - minimum_w); r.w = right - r.x
			} else {
				r.x = clamp(r.x, area.x, area.x + area.w - minimum_w)
				r.w = clamp(r.w, minimum_w, area.x + area.w - r.x)
			}
			if d.top {
				bottom := clamp(
					d.frame.y + d.frame.h,
					area.y + minimum_h,
					area.y + area.h,
				)
				r.y = clamp(r.y, area.y, bottom - minimum_h)
				r.h = bottom - r.y
			} else {
				r.y = clamp(r.y, area.y, area.y + area.h - minimum_h)
				r.h = clamp(r.h, minimum_h, area.y + area.h - r.y)
			}
			if m.native_resize_window != w.id {
				if err := perform(
					m,
					{kind = .Frame, window = w.id, frame = r},
				); err != "" {
					return err
				}
			}
			w.frame = r
			w.solo_tile_frame = Rect {
				(r.x - area.x) / area.w,
				(r.y - area.y) / area.h,
				r.w / area.w,
				r.h / area.h,
			}
			d.previous = point
			return ""
		}
		if fence := mouse_fence(n, .Vertical, d.left);
		   fence != nil && fence.frame.w > 0 {
			fence.ratio = clamp(
				fence.ratio + (point.x - d.previous.x) / fence.frame.w,
				0.1,
				0.9,
			)
		}
		if fence := mouse_fence(n, .Horizontal, d.top);
		   fence != nil && fence.frame.h > 0 {
			fence.ratio = clamp(
				fence.ratio + (point.y - d.previous.y) / fence.frame.h,
				0.1,
				0.9,
			)
		}
		if err := flush(m, s); err != "" {
			return err
		}
	}
	d.previous = point
	return ""
}
Mouse_Drop :: enum {
	None,
	Swap,
	Stack,
	North,
	East,
	South,
	West,
}
mouse_drop_region :: proc(
	frame: Rect,
	point: Mouse_Point,
	stack: bool,
	source_count: int,
) -> Mouse_Drop {
	if frame.w <= 0 || frame.h <= 0 {
		return .None
	}
	x := (point.x - frame.x) / frame.w; y := (point.y - frame.y) / frame.h
	if math.is_nan(x) || math.is_nan(y) || x < 0 || y < 0 || x > 1 || y > 1 {
		return .None
	}
	if source_count == 1 && x >= 0.25 && x <= 0.75 && y >= 0.25 && y <= 0.75 {
		return stack ? .Stack : .Swap
	}
	if y <= x && y <= 1 - x {
		return .North
	}
	if x >= y && x >= 1 - y {
		return .East
	}
	if y >= x && y >= 1 - x {
		return .South
	}
	return .West
}

layout_drop_region :: proc(
	v: ^layout.View,
	frame: Rect,
	point: Mouse_Point,
	stack: bool,
	source_count: int,
) -> Mouse_Drop {
	point := point
	if v.layout == .Scroll {
		r := v.scroll.viewport
		if math.is_nan(point.x) ||
		   math.is_nan(point.y) ||
		   point.x < r.x ||
		   point.x > r.x + r.w ||
		   point.y < r.y ||
		   point.y > r.y + r.h {
			return .None
		}
		point.x, point.y =
			clamp(point.x, frame.x, frame.x + frame.w),
			clamp(point.y, frame.y, frame.y + frame.h)
	}
	action := mouse_drop_region(frame, point, stack, source_count)
	if v.layout != .Scroll || action == .None || action == .Stack ||
	   action == .North || action == .South {
		return action
	}
	// A center drop inserts a column. It does not swap the way a BSP drop does.
	return point.x < frame.x + frame.w / 2 ? .West : .East
}
scroll_drop_row :: proc(
	m: ^Manager,
	source, destination: ^Window,
	s, t: ^Space,
	action: Mouse_Drop,
) -> string {
	b := layout.find(t.view.root, destination.id)
	if b == nil {return "target column is gone"}
	same := layout.find(s.view.root, source.id) == b
	if !same && b.count >= layout.MAX_STACK {return "target column is full"}
	index := 0
	for i in 0 ..< b.count {
		if b.windows[i] == destination.id {index = i; break}
	}
	if action == .South {index += 1}
	if same {
		source_index := 0
		for i in 0 ..< b.count {
			if b.windows[i] == source.id {source_index = i; break}
		}
		if source_index < index {index -= 1}
	}
	if s != t {
		if err := perform(m, {kind = .Space, window = source.id, space = t.id}); err != "" {
			return err
		}
		source.space, source.display = t.id, t.display
	}
	layout.remove(&s.view, source.id)
	b = layout.find(t.view.root, destination.id)
	if b == nil {return "target column is gone"}
	// A row drop shows every window in the column. A tabbed column becomes rows.
	b.column_tabbed = false
	if !layout.scroll_insert_row(b, source.id, index) {return "target column is full"}
	if s != t {
		if err := flush(m, s); err != "" {return err}
	}
	return flush(m, t)
}

mouse_drop :: proc(
	m: ^Manager,
	d: Mouse_Drag,
	target: u32,
	point: Mouse_Point,
) -> string {
	if d.action == .Resize {
		w := m.windows[d.window]
		if w == nil || !managed(w) {
			return ""
		}
		s := space_by_id(m, w.space)
		if s == nil || s.view.layout == .Float {
			return ""
		}
		n := layout.find(s.view.root, w.id)
		if n == nil || n != s.view.root || n.count != 1 {
			return ""
		}
		// A lone tile may track the pointer, but fills its workspace again
		// after release. Multi-window drags retain their adjusted split ratios.
		w.solo_tile_frame = nil
		if s.view.layout == .Scroll {
			s.view.scroll.reveal = true
		}
		// Pointer tracking is immediate; the post-release fill uses the
		// configured layout animation so it does not appear as a sudden jump.
		return flush(m, s, true)
	}
	if d.action != .Move {
		return ""
	}
	source := m.windows[d.window]; destination := m.windows[target]
	if source == nil || destination == nil || source == destination {
		return ""
	}
	s := space_by_id(m, source.space)
	if s == nil || s.view.layout == .Float {
		return ""
	}
	t := space_by_id(m, destination.space)
	if t == nil || t.view.layout == .Float {
		return ""
	}
	a := layout.find(s.view.root, source.id); b := layout.find(t.view.root, target)
	if a == nil || b == nil {
		return ""
	}
	action := layout_drop_region(
		&t.view,
		destination.frame,
		point,
		m.mouse.drop_stack,
		a.count,
	)
	if action == .None {
		return ""
	}
	// Top and bottom of a scrolling window insert a row. Left and right still
	// insert a column. Focus is left where it was.
	if t.view.layout == .Scroll && (action == .North || action == .South) {
		if a == b && a.count < 2 {return ""}
		return scroll_drop_row(m, source, destination, s, t, action)
	}
	if a == b {
		return ""
	}
	source_width := s.view.layout == .Scroll ? a.column_width : f64(0)
	source_size, source_preset, source_full :=
		a.column_size, a.column_preset, a.column_full
	if s != t {
		if action == .Swap {
			return(
				window_command(m, []string{fmt.tprintf("%d", source.id), "--swap", fmt.tprintf("%d", target)}).text \
			)
		}
		if (action == .Stack || t.view.layout == .Stack) &&
		   b.count == layout.MAX_STACK {
			return "target stack is full"
		}
		if err := perform(
			m,
			{kind = .Space, window = source.id, space = t.id},
		); err != "" {
			return err
		}
		layout.remove(&s.view, source.id)
		source.space, source.display = t.id, t.display
		if action == .Stack {
			layout.stack_push(b, source.id)
		} else {
			b.split =
				(action == .East || action == .West) ? .Vertical : .Horizontal
			b.insert_stack = false
			b.insert_first = action == .North || action == .West
			layout.add(&t.view, source.id, target)
			if t.view.layout == .Scroll && source_width > 0 {
				if placed := layout.find(t.view.root, source.id); placed != nil {
					placed.column_width = source_width
					placed.column_resolved = source_width
					placed.column_size, placed.column_preset, placed.column_full =
						source_size, source_preset, source_full
				}
			}
		}
		if err := flush(m, s); err != "" {
			return err
		}
		return flush(m, t)
	}
	switch action {
	case .None:
		return ""
	case .Swap:
		layout.swap(a, b)
	case .Stack:
		if b.count == layout.MAX_STACK {
			return "target stack is full"
		}
		layout.remove(&s.view, source.id); b = layout.find(s.view.root, target)
		layout.stack_push(b, source.id)
	case .North, .East, .South, .West:
		layout.remove(&s.view, source.id); b = layout.find(s.view.root, target)
		b.split =
			(action == .East || action == .West) ? .Vertical : .Horizontal
		b.insert_stack = false
		b.insert_first = action == .North || action == .West
		layout.add(&s.view, source.id, target)
		if s.view.layout == .Scroll && source_width > 0 {
			if placed := layout.find(s.view.root, source.id); placed != nil {
				placed.column_width = source_width
				placed.column_resolved = source_width
				placed.column_size, placed.column_preset, placed.column_full =
					source_size, source_preset, source_full
			}
		}
	}
	return flush(m, s)
}
