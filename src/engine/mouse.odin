package engine

import "core:fmt"
import "core:math"

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
	modifier:                  u64,
	action1, action2:          Mouse_Action,
	focus:                     Focus_Follows_Mouse,
	follows_focus, drop_stack: bool,
}
MOUSE_MODIFIERS :: u64((1 << 17) | (1 << 18) | (1 << 19) | (1 << 20) | (1 << 23))
mouse_defaults :: proc() -> Mouse_Config {return{
		modifier = 1 << 23,
		action1 = .Move,
		action2 = .Resize,
	}}
mouse_config :: proc(m: ^Manager, s: ^Space, name, value: string, setting: bool) -> Response {
	if s != nil {return failure("mouse settings are global")}
	c := &m.mouse
	switch name {
	case "mouse_modifier":
		names := []string{"alt", "shift", "cmd", "ctrl", "fn"}
		bits := []u64{1 << 19, 1 << 17, 1 << 20, 1 << 18, 1 << 23}
		for name, i in names {
			if !setting && c.modifier == bits[i] {return success(name)}
			if setting && value == name {c.modifier = bits[i];return success()}
		}
		return failure("mouse_modifier expects alt, shift, cmd, ctrl, or fn")
	case "mouse_action1", "mouse_action2":
		action := name == "mouse_action1" ? &c.action1 : &c.action2
		names := [Mouse_Action]string {
			.None   = "none",
			.Move   = "move",
			.Resize = "resize",
		}
		if !setting {return success(names[action^])}
		for name, kind in names {if name == value {action^ = kind;return success()}}
		return failure("mouse action expects none, move, or resize")
	case "focus_follows_mouse":
		names := [Focus_Follows_Mouse]string {
			.Off       = "off",
			.Autofocus = "autofocus",
			.Autoraise = "autoraise",
		}
		if !setting {return success(names[c.focus])}
		for name, kind in names {if name == value {c.focus = kind;return success()}}
		return failure("focus_follows_mouse expects off, autofocus, or autoraise")
	case "mouse_follows_focus":
		if !setting {return success(c.follows_focus ? "on" : "off")}
		if value != "on" &&
		   value != "off" {return failure("mouse_follows_focus expects on or off")}
		c.follows_focus = value == "on"
	case "mouse_drop_action":
		if !setting {return success(c.drop_stack ? "stack" : "swap")}
		if value != "stack" &&
		   value != "swap" {return failure("mouse_drop_action expects swap or stack")}
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
	window:           u32,
	action:           Mouse_Action,
	origin, previous: Mouse_Point,
	frame:            Rect,
	left, top:        bool,
}
mouse_begin :: proc(m: ^Manager, id: u32, action: Mouse_Action, point: Mouse_Point) -> Mouse_Drag {
	w := m.windows[id]
	if w == nil || w.fullscreen || w.minimized || w.hidden || action == .None {return {}}
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
	r := d.frame;dx := point.x - d.origin.x;dy := point.y - d.origin.y
	if d.action == .Move {r.x += dx;r.y += dy;return r}
	if d.left {r.w = max(1, r.w - dx);r.x = d.frame.x + d.frame.w - r.w} else {r.w = max(1, r.w + dx)}
	if d.top {r.h = max(1, r.h - dy);r.y = d.frame.y + d.frame.h - r.h} else {r.h = max(1, r.h + dy)}
	return r
}
mouse_fence :: proc(n: ^Node, split: Split, leading: bool) -> ^Node {
	for child := n; child != nil && child.parent != nil; child = child.parent {
		parent := child.parent
		if parent.split == split &&
		   (leading ? parent.right == child : parent.left == child) {return parent}
	}
	return nil
}
mouse_update :: proc(m: ^Manager, d: ^Mouse_Drag, point: Mouse_Point) -> string {
	w := m.windows[d.window]
	if w == nil {return "dragged window no longer exists"}
	if w.fullscreen || w.minimized || w.hidden {return "dragged window is no longer available"}
	s := space_by_id(m, w.space)
	n: ^Node
	if s != nil && s.view.layout != .Float {n = find(s.view.root, w.id)}
	if n == nil {
		r := mouse_drag_frame(d^, point)
		if err := perform(m, {kind = .Frame, window = w.id, frame = r}); err != "" {return err}
		w.frame = r
	} else if d.action == .Resize {
		if fence := mouse_fence(n, .Vertical, d.left); fence != nil && fence.frame.w > 0 {
			fence.ratio = clamp(fence.ratio + (point.x - d.previous.x) / fence.frame.w, 0.1, 0.9)
		}
		if fence := mouse_fence(n, .Horizontal, d.top); fence != nil && fence.frame.h > 0 {
			fence.ratio = clamp(fence.ratio + (point.y - d.previous.y) / fence.frame.h, 0.1, 0.9)
		}
		if err := flush(m, s); err != "" {return err}
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
	if frame.w <= 0 || frame.h <= 0 {return .None}
	x := (point.x - frame.x) / frame.w;y := (point.y - frame.y) / frame.h
	if math.is_nan(x) || math.is_nan(y) || x < 0 || y < 0 || x > 1 || y > 1 {return .None}
	if source_count == 1 &&
	   x >= 0.25 &&
	   x <= 0.75 &&
	   y >= 0.25 &&
	   y <= 0.75 {return stack ? .Stack : .Swap}
	if y <= x && y <= 1 - x {return .North}
	if x >= y && x >= 1 - y {return .East}
	if y >= x && y >= 1 - x {return .South}
	return .West
}
mouse_drop :: proc(m: ^Manager, d: Mouse_Drag, target: u32, point: Mouse_Point) -> string {
	if d.action != .Move {return ""}
	source := m.windows[d.window];destination := m.windows[target]
	if source == nil || destination == nil || source == destination {return ""}
	s := space_by_id(m, source.space)
	if s == nil || s.view.layout == .Float {return ""}
	t := space_by_id(m, destination.space)
	if t == nil || t.view.layout == .Float {return ""}
	a := find(s.view.root, source.id);b := find(t.view.root, target)
	if a == nil || b == nil || a == b {return ""}
	action := mouse_drop_region(destination.frame, point, m.mouse.drop_stack, a.count)
	if action == .None {return ""}
	if s != t {
		if action == .Swap {
			return(
				window_command(m, []string{fmt.tprintf("%d", source.id), "--swap", fmt.tprintf("%d", target)}).text \
			)
		}
		if action == .Stack && b.count == MAX_STACK {return "target stack is full"}
		if err := perform(m, {kind = .Space, window = source.id, space = t.id});
		   err != "" {return err}
		remove(&s.view, source.id)
		source.space, source.display = t.id, t.display
		if action == .Stack {
			stack_push(b, source.id)
		} else {
			b.split = (action == .East || action == .West) ? .Vertical : .Horizontal
			b.insert_stack = false
			b.insert_first = action == .North || action == .West
			add(&t.view, source.id, target)
		}
		if err := flush(m, s); err != "" {return err}
		return flush(m, t)
	}
	switch action {
	case .None:
		return ""
	case .Swap:
		swap(a, b)
	case .Stack:
		if b.count == MAX_STACK {return "target stack is full"}
		remove(&s.view, source.id);b = find(s.view.root, target);stack_push(b, source.id)
	case .North, .East, .South, .West:
		remove(&s.view, source.id);b = find(s.view.root, target)
		b.split = (action == .East || action == .West) ? .Vertical : .Horizontal
		b.insert_stack = false
		b.insert_first = action == .North || action == .West
		add(&s.view, source.id, target)
	}
	return flush(m, s)
}
