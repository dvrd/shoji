package engine

import "core:fmt"
import "core:math"

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
	   find(s.view.root, id) == nil ||
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
mouse_fence :: proc(n: ^Node, split: Split, leading: bool) -> ^Node {
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
	n: ^Node
	if s != nil && s.view.layout != .Float {
		n = find(s.view.root, w.id)
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
				if err := scroll_set_width(
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
	v: ^View,
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
	if v.layout != .Scroll || action == .None || action == .Stack {
		return action
	}
	// Scrolling drops insert a column at an explicit boundary. A center drop
	// must not unexpectedly swap the source and target like a BSP drop.
	return point.x < frame.x + frame.w / 2 ? .West : .East
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
		n := find(s.view.root, w.id)
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
	a := find(s.view.root, source.id); b := find(t.view.root, target)
	if a == nil || b == nil || a == b {
		return ""
	}
	source_width := s.view.layout == .Scroll ? a.column_width : f64(0)
	source_size, source_preset, source_full :=
		a.column_size, a.column_preset, a.column_full
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
	if s != t {
		if action == .Swap {
			return(
				window_command(m, []string{fmt.tprintf("%d", source.id), "--swap", fmt.tprintf("%d", target)}).text \
			)
		}
		if (action == .Stack || t.view.layout == .Stack) &&
		   b.count == MAX_STACK {
			return "target stack is full"
		}
		if err := perform(
			m,
			{kind = .Space, window = source.id, space = t.id},
		); err != "" {
			return err
		}
		remove(&s.view, source.id)
		source.space, source.display = t.id, t.display
		if action == .Stack {
			stack_push(b, source.id)
		} else {
			b.split =
				(action == .East || action == .West) ? .Vertical : .Horizontal
			b.insert_stack = false
			b.insert_first = action == .North || action == .West
			add(&t.view, source.id, target)
			if t.view.layout == .Scroll && source_width > 0 {
				if placed := find(t.view.root, source.id); placed != nil {
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
		swap(a, b)
	case .Stack:
		if b.count == MAX_STACK {
			return "target stack is full"
		}
		remove(&s.view, source.id); b = find(s.view.root, target)
		stack_push(b, source.id)
	case .North, .East, .South, .West:
		remove(&s.view, source.id); b = find(s.view.root, target)
		b.split =
			(action == .East || action == .West) ? .Vertical : .Horizontal
		b.insert_stack = false
		b.insert_first = action == .North || action == .West
		add(&s.view, source.id, target)
		if s.view.layout == .Scroll && source_width > 0 {
			if placed := find(s.view.root, source.id); placed != nil {
				placed.column_width = source_width
				placed.column_resolved = source_width
				placed.column_size, placed.column_preset, placed.column_full =
					source_size, source_preset, source_full
			}
		}
	}
	return flush(m, s)
}

// Gesture routing
// ------------------------------------------------------------------------

Scroll_Sample :: struct {
	x, y: f64,
	modifiers: u64,
	phase: u64,
	momentum: i64,
}
Scroll_Gesture :: struct {
	owned: bool,
	space: u64,
	last: f64,
	layout: Layout,
	travel: f64,
	switched: bool,
}

// Latch the operation as well as the originating Space. Crossing to a scroll
// Space must not turn the tail of a BSP swipe into column movement.
layout_gesture_route :: proc(
	g: ^Scroll_Gesture,
	sample: Scroll_Sample,
	space: u64,
	layout: Layout,
	modifier: u64,
	enabled: bool,
	now: f64,
) -> (
	bool,
	f64,
	int,
) {
	fresh :=
		g.space == 0 ||
		sample.phase & (1 | 128) != 0 ||
		now - g.last > 1 ||
		(sample.phase == 0 && sample.momentum == 0 && now - g.last > 0.25)
	if fresh {
		g.layout, g.travel, g.switched = layout, 0, false
	}
	consume, delta := scroll_gesture_route(
		g,
		sample,
		space,
		modifier,
		enabled,
		now,
	)
	if !consume {
		return false, 0, 0
	}
	if g.layout != .BSP {
		return true, delta, 0
	}
	if sample.momentum == 0 && sample.phase & 8 == 0 && !g.switched {
		g.travel += delta
		if math.abs(g.travel) >= 80 {
			g.switched = true
			return true, 0, g.travel > 0 ? 1 : -1
		}
	}
	return true, 0, 0
}

space_gesture_switch :: proc(
	m: ^Manager,
	origin: u64,
	direction: int,
) -> string {
	s := space_by_id(m, origin)
	if direction == 0 ||
	   s == nil ||
	   !s.visible ||
	   s.view.layout != .BSP ||
	   m.suspended ||
	   m.gesture_active {
		return ""
	}
	d := display_by_id(m, s.display)
	if d == nil || d.active_space != origin {
		return ""
	}
	// Native indices are ordered across displays. Filter by the originating
	// display for both adjacency and cyclic wraparound.
	target: ^Space
	wrapped: ^Space
	for candidate in m.spaces {
		if candidate.display != s.display {
			continue
		}
		if wrapped == nil ||
		   (direction > 0 \
					   ? candidate.index < wrapped.index \
					   : candidate.index > wrapped.index) {
			wrapped = candidate
		}
		if direction > 0 &&
		   candidate.index > s.index &&
		   (target == nil || candidate.index < target.index) {
			target = candidate
		}
		if direction < 0 &&
		   candidate.index < s.index &&
		   (target == nil || candidate.index > target.index) {
			target = candidate
		}
	}
	if target == nil {
		target = wrapped
	}
	if target == nil || target.id == origin {
		return ""
	}
	return perform(m, {kind = .Space_Focus, space = target.id})
}
// Physical scroll phase is a bitmask; CG momentum phase is a separate enum.
// Once captured, the tail stays with its original Space, even if the modifier
// is released. Unclaimed application momentum is never intercepted.
scroll_gesture_route :: proc(
	g: ^Scroll_Gesture,
	sample: Scroll_Sample,
	space, modifier: u64,
	enabled: bool,
	now: f64,
) -> (
	bool,
	f64,
) {
	if !enabled ||
	   math.is_nan(sample.x) ||
	   math.is_inf(sample.x) ||
	   math.is_nan(sample.y) ||
	   math.is_inf(sample.y) {
		g.owned = false; return false, 0
	}
	if now - g.last > 1 || sample.phase & (1 | 128) != 0 {
		g.owned = false
	}
	g.last = now
	if sample.momentum != 0 {
		owned := g.owned
		if sample.momentum == 3 {
			g.owned = false
		}
		return owned, owned ? -sample.x : 0
	}
	if sample.phase == 0 {
		g.owned = false
		if space != 0 &&
		   sample.modifiers == modifier &&
		   math.abs(sample.x) > math.abs(sample.y) {
			g.space = space; return true, -sample.x
		}
		return false, 0
	}
	if !g.owned &&
	   space != 0 &&
	   sample.modifiers == modifier &&
	   math.abs(sample.x) > math.abs(sample.y) {
		g.owned, g.space = true, space
	}
	owned := g.owned
	if sample.phase & 8 != 0 {
		g.owned = false
	}
	return owned, owned ? -sample.x : 0
}

scroll_gesture_pan :: proc(m: ^Manager, space: u64, delta: f64) -> string {
	s := space_by_id(m, space)
	if s == nil ||
	   !s.visible ||
	   s.view.layout != .Scroll ||
	   m.suspended ||
	   m.gesture_active {
		return ""
	}
	if math.is_nan(delta) || math.is_inf(delta) {
		return "invalid scroll delta"
	}
	scroll_pan(&s.view, s.view.scroll.offset + delta)
	if m.scroll_animate {
		return flush(m, s)
	}
	// Input already carries the system's momentum curve. Applying another
	// window animation per sample would lag behind the pointer.
	duration := m.animation_duration
	m.animation_duration = 0
	defer m.animation_duration = duration
	return flush(m, s)
}

// Interaction feedback
// ------------------------------------------------------------------------

Drag_Edge_Config :: struct {
	enabled: bool,
	width, delay, speed: f64,
}
Drag_Edge :: struct {
	space: u64,
	direction: int,
	entered, last: f64,
}

// Only an owned window move may pan here. Ordinary application drag-and-drop
// needs a separately verified ownership route; mouse button state alone is not it.
drag_edge_scroll :: proc(
	m: ^Manager,
	edge: ^Drag_Edge,
	drag: Mouse_Drag,
	point: Mouse_Point,
	now: f64,
) -> (
	bool,
	string,
) {
	w := m.windows[drag.window]
	if !m.mouse.edge.enabled ||
	   m.suspended ||
	   m.gesture_active ||
	   drag.action != .Move ||
	   w == nil ||
	   !managed(w) ||
	   w.fullscreen ||
	   w.hidden ||
	   w.minimized ||
	   !(w.ordered_in.? or_else true) ||
	   math.is_nan(now) ||
	   math.is_inf(now) ||
	   math.is_nan(point.x) ||
	   math.is_nan(point.y) {
		edge^ = {}; return false, ""
	}
	target: ^Space
	for s in m.spaces {
		r := s.view.scroll.viewport
		if s.visible &&
		   s.view.layout == .Scroll &&
		   r.w > 0 &&
		   r.h > 0 &&
		   point.x >= r.x &&
		   point.x <= r.x + r.w &&
		   point.y >= r.y &&
		   point.y <= r.y + r.h {
			target = s; break
		}
	}
	if target == nil {
		edge^ = {}; return false, ""
	}
	r := target.view.scroll.viewport
	width := min(m.mouse.edge.width, r.w / 2)
	distance := min(point.x - r.x, r.x + r.w - point.x)
	if width <= 0 || distance >= width {
		edge^ = {}; return false, ""
	}
	direction := point.x < r.x + r.w / 2 ? -1 : 1
	if edge.space != target.id ||
	   edge.direction != direction ||
	   now < edge.last {
		edge^ = {target.id, direction, now, now}; return false, ""
	}
	previous := edge.last; edge.last = now
	dt := clamp(now - max(previous, edge.entered + m.mouse.edge.delay), 0, .05)
	if dt <= 0 {
		return false, ""
	}
	delta := f64(direction) * m.mouse.edge.speed * (1 - distance / width) * dt
	before := target.view.scroll.offset
	dragging := target.view.scroll.dragging
	target.view.scroll.dragging = true
	defer target.view.scroll.dragging = dragging
	scroll_pan(&target.view, before + delta)
	if target.view.scroll.offset == before {
		return false, ""
	}
	duration := m.animation_duration; m.animation_duration = 0
	defer m.animation_duration = duration
	err := flush(m, target, true)
	return err == "", err
}

drag_target_at :: proc(
	m: ^Manager,
	drag: Mouse_Drag,
	point: Mouse_Point,
) -> u32 {
	if source := m.windows[drag.window]; source != nil {
		r := source.frame
		if point.x >= r.x &&
		   point.x <= r.x + r.w &&
		   point.y >= r.y &&
		   point.y <= r.y + r.h {
			return 0
		}
	}
	target: u32; best := f64(1e300)
	for _, w in m.windows {
		if w.id == drag.window ||
		   !managed(w) ||
		   w.hidden ||
		   w.minimized ||
		   !(w.ordered_in.? or_else true) {
			continue
		}
		s := space_by_id(m, w.space)
		if s == nil || !s.visible || s.view.layout == .Float {
			continue
		}
		viewport :=
			s.view.layout == .Scroll ? s.view.scroll.viewport : s.view.frame
		if point.x < viewport.x ||
		   point.x > viewport.x + viewport.w ||
		   point.y < viewport.y ||
		   point.y > viewport.y + viewport.h {
			continue
		}
		n := find(s.view.root, w.id)
		if n == nil || (n.column_tabbed && n.order[0] != w.id) {
			continue
		}
		r := w.frame
		dx := max(r.x - point.x, point.x - r.x - r.w, 0)
		dy := max(r.y - point.y, point.y - r.y - r.h, 0)
		distance := dx * dx + dy * dy
		if distance < best || (distance == best && w.id < target) {
			best, target = distance, w.id
		}
	}
	return target
}

Feedback_Plan :: struct {
	window: u32,
	frame: Rect,
	color: u32,
	solid: bool,
	corner: Feedback_Corner,
	stroke_width: f64,
}

Feedback_Corner :: enum {
	None,
	Top_Left,
	Top_Right,
	Bottom_Left,
	Bottom_Right,
}

Focus_Ring_Config :: struct {
	enabled: bool,
	width, radius: f64,
	color: u32,
}

// Straight strips stretch along one axis; the four small corner pieces only
// translate. Neither thickness nor corner curvature scales during a resize.
focus_ring_plans :: proc(
	m: ^Manager,
	frame: Rect,
) -> (
	plans: [8]Feedback_Plan,
	valid: bool,
) {
	w := m.windows[m.focused]
	if !m.focus_ring.enabled ||
	   m.suspended ||
	   m.gesture_active ||
	   w == nil ||
	   w.role != "AXWindow" ||
	   !(w.root_window.? or_else true) ||
	   w.hidden ||
	   w.minimized ||
	   w.scratchpad_hidden ||
	   w.fullscreen ||
	   !(w.ordered_in.? or_else true) ||
	   frame.w <= 0 ||
	   frame.h <= 0 ||
	   math.is_nan(frame.x) ||
	   math.is_nan(frame.y) ||
	   math.is_nan(frame.w) ||
	   math.is_nan(frame.h) ||
	   math.is_inf(frame.x) ||
	   math.is_inf(frame.y) ||
	   math.is_inf(frame.w) ||
	   math.is_inf(frame.h) {
		return
	}
	s := space_by_id(m, w.space)
	if s == nil || !s.visible {
		return
	}
	visible := 0
	for _, other in m.windows {
		// Browser link-status bubbles are AXHelpTag surfaces, not another
		// independent window to choose. Real floating AXWindows still count.
		if other.space == w.space &&
		   other.role == "AXWindow" &&
		   (other.root_window.? or_else true) &&
		   !other.hidden &&
		   !other.minimized &&
		   other.opening.phase != .Pending &&
		   !other.scratchpad_hidden &&
		   (other.ordered_in.? or_else true) {
			visible += 1
			if visible > 1 {
				break
			}
		}
	}
	if visible < 2 {
		return
	}
	width := min(m.focus_ring.width, min(frame.w, frame.h) / 2)
	if width <= 0 || m.focus_ring.color >> 24 == 0 {
		return
	}
	radius := min(max(width, m.focus_ring.radius), min(frame.w, frame.h) / 2)
	rects := [8]Rect {
		{frame.x + radius, frame.y, frame.w - 2 * radius, width},
		{
			frame.x + radius,
			frame.y + frame.h - width,
			frame.w - 2 * radius,
			width,
		},
		{frame.x, frame.y + radius, width, frame.h - 2 * radius},
		{
			frame.x + frame.w - width,
			frame.y + radius,
			width,
			frame.h - 2 * radius,
		},
		{frame.x, frame.y, radius, radius},
		{frame.x + frame.w - radius, frame.y, radius, radius},
		{frame.x, frame.y + frame.h - radius, radius, radius},
		{
			frame.x + frame.w - radius,
			frame.y + frame.h - radius,
			radius,
			radius,
		},
	}
	for r, i in rects {
		plans[i] = {
			window       = w.id,
			frame        = r,
			color        = m.focus_ring.color,
			solid        = true,
			corner       = i < 4 ? .None : Feedback_Corner(i - 3),
			stroke_width = i < 4 ? 0 : width,
		}
	}
	valid = true
	return
}

feedback_frame :: proc(v: ^View, n: ^Node, action: Mouse_Drop) -> Rect {
	frame := frame_for(n)
	if v.layout == .Scroll && n.count > 0 {
		frame = scroll_window_frame(v, n, n.order[0])
	}
	if action == .Stack || action == .Swap {
		return frame
	}
	a, b := partition(
		frame,
		(action == .East || action == .West) ? .Vertical : .Horizontal,
		v.ratio,
		v.gap_enabled ? v.gap : 0,
	)
	return action == .North || action == .West ? a : b
}

insertion_feedback :: proc(m: ^Manager, s: ^Space) -> (Feedback_Plan, bool) {
	if m.suspended ||
	   m.gesture_active ||
	   !s.visible ||
	   s.view.layout == .Float {
		return {}, false
	}
	n := find(s.view.root, s.view.insertion)
	if n == nil {
		return {}, false
	}
	action: Mouse_Drop
	if n.insert_stack {
		action = .Stack
	} else {
		leading := n.insert_first.? or_else false
		action =
			n.split == .Vertical \
				? (leading ? .West : .East) \
				: (leading ? .North : .South)
	}
	return {
			window = s.view.insertion,
			frame = feedback_frame(&s.view, n, action),
			color = m.feedback_color,
		},
		true
}

drag_feedback :: proc(
	m: ^Manager,
	drag: Mouse_Drag,
	target: u32,
	point: Mouse_Point,
) -> (
	Feedback_Plan,
	bool,
) {
	if m.suspended ||
	   m.gesture_active ||
	   drag.action != .Move ||
	   drag.window == target {
		return {}, false
	}
	w, destination := m.windows[drag.window], m.windows[target]
	if w == nil || destination == nil {
		return {}, false
	}
	s, t := space_by_id(m, w.space), space_by_id(m, destination.space)
	if s == nil ||
	   t == nil ||
	   !t.visible ||
	   s.view.layout == .Float ||
	   t.view.layout == .Float {
		return {}, false
	}
	a, b := find(s.view.root, w.id), find(t.view.root, target)
	if a == nil || b == nil || a == b {
		return {}, false
	}
	action := layout_drop_region(
		&t.view,
		destination.frame,
		point,
		m.mouse.drop_stack,
		a.count,
	)
	if action == .None || (action == .Stack && b.count >= MAX_STACK) {
		return {}, false
	}
	if t.view.layout == .Scroll && (action == .West || action == .East) {
		viewport := t.view.scroll.viewport
		x :=
			action == .West \
				? destination.frame.x \
				: destination.frame.x + destination.frame.w
		x +=
			action == .West \
				? -scroll_gap(&t.view) / 2 \
				: scroll_gap(&t.view) / 2
		frame := Rect {
			clamp(
				x - 2,
				viewport.x,
				max(viewport.x, viewport.x + viewport.w - 4),
			),
			viewport.y + scroll_gap(&t.view),
			min(4, viewport.w),
			max(1, viewport.h - 2 * scroll_gap(&t.view)),
		}
		return {
				window = target,
				frame = frame,
				color = m.feedback_color,
				solid = true,
			},
			true
	}
	return {
			window = target,
			frame = feedback_frame(&t.view, b, action),
			color = m.feedback_color,
		},
		true
}
