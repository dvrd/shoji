package engine

Feedback_Plan :: struct {
	window: u32,
	frame:  Rect,
	color:  u32,
}

feedback_frame :: proc(v: ^View, n: ^Node, action: Mouse_Drop) -> Rect {
	if action == .Stack || action == .Swap {return frame_for(n)}
	a, b := partition(
		frame_for(n),
		(action == .East || action == .West) ? .Vertical : .Horizontal,
		v.ratio,
		v.gap_enabled ? v.gap : 0,
	)
	return action == .North || action == .West ? a : b
}

insertion_feedback :: proc(m: ^Manager, s: ^Space) -> (Feedback_Plan, bool) {
	if m.suspended || m.gesture_active || !s.visible || s.view.layout == .Float {return {}, false}
	n := find(s.view.root, s.view.insertion)
	if n == nil {return {}, false}
	action: Mouse_Drop
	if n.insert_stack {action = .Stack} else {
		leading := n.insert_first.? or_else false
		action = n.split == .Vertical ? (leading ? .West : .East) : (leading ? .North : .South)
	}
	return {s.view.insertion, feedback_frame(&s.view, n, action), m.feedback_color}, true
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
	   drag.window == target {return {}, false}
	w, destination := m.windows[drag.window], m.windows[target]
	if w == nil || destination == nil {return {}, false}
	s, t := space_by_id(m, w.space), space_by_id(m, destination.space)
	if s == nil ||
	   t == nil ||
	   !t.visible ||
	   s.view.layout == .Float ||
	   t.view.layout == .Float {return {}, false}
	a, b := find(s.view.root, w.id), find(t.view.root, target)
	if a == nil || b == nil || a == b {return {}, false}
	action := mouse_drop_region(destination.frame, point, m.mouse.drop_stack, a.count)
	if action == .None || (action == .Stack && b.count >= MAX_STACK) {return {}, false}
	return {target, feedback_frame(&t.view, b, action), m.feedback_color}, true
}
