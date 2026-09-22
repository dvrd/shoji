package engine

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

Window :: struct {
	can_move, can_resize: bool,
	manage_override: Maybe(bool),
	id: u32,
	pid: i32,
	app, title, role, subrole: string,
	frame: Rect,
	display: u32,
	space: u64,
	focused, floating, minimized, hidden, fullscreen, sticky: bool,
	shadow: bool,
	opacity: f64,
	layer: string,
	scratchpad: string,
}

Display :: struct {
	id, index: u32,
	uuid: string,
	frame, usable: Rect,
	spaces: [dynamic]u64,
	active_space: u64,
	label: string,
}

Space :: struct {
	id: u64,
	index, display: u32,
	uuid, label: string,
	visible, fullscreen: bool,
	view: View,
}

Action_Kind :: enum {
	Frame,
	Focus,
	Focus_Without_Raise,
	Close,
	Minimize,
	Deminimize,
	Fullscreen,
	Space,
	Opacity,
	Layer,
	Sticky,
	Shadow,
	Order,
	Scale,
	Space_Focus,
	Space_Create,
	Space_Destroy,
	Space_Move,
}

Action :: struct {
	kind: Action_Kind,
	window, relative: u32,
	space, destination: u64,
	frame: Rect,
	value: f64,
	flag: bool,
}

Backend :: proc(user: rawptr, action: Action) -> string
Manager :: struct {
	mouse: Mouse_Config,
	windows: map[u32]^Window,
	spaces: [dynamic]^Space,
	displays: [dynamic]Display,
	focused, last_focused: u32,
	active_space, last_space: u64,
	default_layout: Layout,
	padding: Padding,
	gap, ratio: f64,
	split: Split,
	first_child, auto_balance: bool,
	backend: Backend,
	backend_user: rawptr,
	rules: [dynamic]Rule,
	signals: [dynamic]Signal,
}

manager_init :: proc(m: ^Manager, backend: Backend = nil, user: rawptr = nil) {
	m^ = Manager {
		mouse          = mouse_defaults(),
		windows        = make(map[u32]^Window),
		ratio          = 0.5,
		default_layout = .Float,
		backend        = backend,
		backend_user   = user,
	}
}

window_destroy :: proc(w: ^Window) {
	delete(w.app)
	delete(w.title)
	delete(w.role)
	delete(w.subrole)
	delete(w.scratchpad)
	free(w)
}

manager_destroy :: proc(m: ^Manager) {
	for _, w in m.windows {
		window_destroy(w)
	}
	delete(m.windows)
	for s in m.spaces {
		view_destroy(&s.view)
		delete(s.uuid)
		delete(s.label)
		free(s)
	}
	delete(m.spaces)
	for d in m.displays {
		delete(d.uuid)
		delete(d.label)
		delete(d.spaces)
	}
	delete(m.displays)
	for &r in m.rules {
		rule_destroy(&r)
	}
	delete(m.rules)
	for &s in m.signals {
		signal_destroy(&s)
	}
	delete(m.signals)
}

space_by_id :: proc(m: ^Manager, id: u64) -> ^Space {
	for s in m.spaces {
		if s.id == id {
			return s
		}
	}
	return nil
}

display_by_id :: proc(m: ^Manager, id: u32) -> ^Display {
	for &d in m.displays {
		if d.id == id {
			return &d
		}
	}
	return nil
}

add_space :: proc(m: ^Manager, id: u64, display, index: u32, frame: Rect) -> ^Space {
	s := new(Space)
	s.id = id
	s.display = display
	s.index = index
	view_init(&s.view, frame, m.default_layout)
	s.view.padding = m.padding
	s.view.gap = m.gap
	s.view.ratio = m.ratio
	s.view.split = m.split
	s.view.auto_balance = m.auto_balance
	s.view.first_child = m.first_child
	append(&m.spaces, s)
	return s
}

managed :: proc(w: ^Window) -> bool {
	if w.floating || w.minimized || w.hidden || w.fullscreen {
		return false
	}
	if override, ok := w.manage_override.?; ok {
		return override
	}
	return w.role == "AXWindow" && w.subrole == "AXStandardWindow"
}

add_window :: proc(m: ^Manager, window: Window) -> ^Window {
	if w, ok := m.windows[window.id]; ok {
		return w
	}
	w := new(Window)
	w^ = window
	w.app = strings.clone(window.app)
	w.title = strings.clone(window.title)
	w.role = strings.clone(window.role)
	w.subrole = strings.clone(window.subrole)
	w.scratchpad = strings.clone(window.scratchpad)
	m.windows[w.id] = w
	apply_rules(m, w)
	if s := space_by_id(m, w.space); s != nil && managed(w) {
		add(&s.view, w.id, m.focused)
	}
	return w
}

remove_window :: proc(m: ^Manager, id: u32) {
	if w, ok := m.windows[id]; ok {
		if s := space_by_id(m, w.space); s != nil {
			remove(&s.view, id)
		}
		if m.focused == id {
			m.focused = 0
		}
		if m.last_focused == id {
			m.last_focused = 0
		}
		delete_key(&m.windows, id)
		window_destroy(w)
	}
}

focus_window :: proc(m: ^Manager, id: u32) {
	if id == m.focused {
		return
	}
	if w, ok := m.windows[m.focused]; ok {
		w.focused = false
	}
	m.last_focused = m.focused
	m.focused = id
	if w, ok := m.windows[id]; ok {
		w.focused = true
		if s := space_by_id(m, w.space); s != nil {
			focus_order(find(s.view.root, id), id)
		}
	}
}

perform :: proc(m: ^Manager, a: Action) -> string {
	if m.backend == nil {
		return "no macOS backend is attached"
	}
	return m.backend(m.backend_user, a)
}

flush :: proc(m: ^Manager, s: ^Space) -> string {
	if s == nil || s.view.layout == .Float {
		return ""
	}
	view_update(&s.view)
	for n := first(s.view.root); n != nil; n = next(n) {
		for i in 0 ..< n.count {
			w := m.windows[n.windows[i]]
			if w == nil {
				continue
			}
			r := frame_for(n)
			if math.abs(w.frame.x - r.x) < 1.5 &&
			   math.abs(w.frame.y - r.y) < 1.5 &&
			   math.abs(w.frame.w - r.w) < 1.5 &&
			   math.abs(w.frame.h - r.h) < 1.5 {
				continue
			}
			if err := perform(m, Action{kind = .Frame, window = w.id, frame = r}); err != "" {
				return err
			}
			w.frame = r
		}
	}
	return ""
}

select_space :: proc(m: ^Manager, text: string) -> ^Space {
	if text == "" {
		return space_by_id(m, m.active_space)
	}
	if text == "recent" {
		return space_by_id(m, m.last_space)
	}
	current := space_by_id(m, m.active_space)
	if text == "first" && len(m.spaces) > 0 {
		return m.spaces[0]
	}
	if text == "last" && len(m.spaces) > 0 {
		return m.spaces[len(m.spaces) - 1]
	}
	if current != nil && (text == "next" || text == "prev") {
		for s, i in m.spaces {
			if s == current {
				j := text == "next" ? i + 1 : i - 1
				if j >= 0 && j < len(m.spaces) {
					return m.spaces[j]
				}
				return nil
			}
		}
	}
	number, numeric := strconv.parse_u64(text)
	for s in m.spaces {
		if (numeric && u64(s.index) == number) || s.label == text {
			return s
		}
	}
	return nil
}

select_window :: proc(m: ^Manager, text: string, reference: u32 = 0) -> ^Window {
	reference := reference
	if reference == 0 {
		reference = m.focused
	}
	if text == "" {
		return m.windows[reference]
	}
	if text == "recent" {
		return m.windows[m.last_focused]
	}
	if id, ok := strconv.parse_u64(text); ok && id <= 0xffffffff {
		return m.windows[u32(id)]
	}
	if text == "largest" || text == "smallest" {
		active := space_by_id(m, m.active_space)
		if active == nil { return nil }
		best: ^Node
		best_area: f64
		for candidate := first(active.view.root); candidate != nil; candidate = next(candidate) {
			if candidate.count == 0 { continue }
			area := math.floor(candidate.frame.w * candidate.frame.h)
			if best == nil ||
			   (text == "largest" ? area > best_area : area <= best_area) { best = candidate; best_area = area }
		}
		if best != nil { return m.windows[best.order[0]] }
		return nil
	}
	w := m.windows[reference]
	if w == nil {
		return nil
	}
	s := space_by_id(m, w.space)
	if s == nil {
		return nil
	}
	n := find(s.view.root, w.id)
	target: ^Node
	switch text {
	case "first":
		target = first(s.view.root)
	case "last":
		target = last(s.view.root)
	case "next":
		target = next(n)
	case "prev":
		target = previous(n)
	case "north":
		target = neighbor(s.view.root, n, .North)
	case "east":
		target = neighbor(s.view.root, n, .East)
	case "south":
		target = neighbor(s.view.root, n, .South)
	case "west":
		target = neighbor(s.view.root, n, .West)
	case "sibling", "first_nephew", "second_nephew", "uncle", "first_cousin", "second_cousin":
		branch := n
		if text == "uncle" || text == "first_cousin" || text == "second_cousin" {
			if branch == nil { return nil }; branch = branch.parent
		}
		if branch == nil || branch.parent == nil { return nil }
		target = branch.parent.left == branch ? branch.parent.right : branch.parent.left
		if text == "first_nephew" || text == "first_cousin" {
			if target == nil { return nil }; target = target.left
		} else if text == "second_nephew" || text == "second_cousin" {
			if target == nil { return nil }; target = target.right
		}
		if target != nil && !leaf(target) { return nil }
	case "stack.first":
		if n != nil && n.count > 0 {
			return m.windows[n.windows[0]]
		}
	case "stack.last":
		if n != nil && n.count > 0 {
			return m.windows[n.windows[n.count - 1]]
		}
	case "stack.next", "stack.prev", "stack.recent":
		if n != nil {
			if text == "stack.recent" && n.count > 1 {
				return m.windows[n.order[1]]
			}
			for i in 0 ..< n.count {
				if n.windows[i] == w.id {
					j := text == "stack.next" ? i + 1 : i - 1
					if j >= 0 && j < n.count {
						return m.windows[n.windows[j]]
					}
				}
			}
		}
	}
	if n != nil && strings.has_prefix(text, "stack.") {
		index, ok := strconv.parse_int(text[len("stack."):])
		if ok && index > 0 && index <= n.count { return m.windows[n.windows[index - 1]] }
	}
	if target != nil && target.count > 0 {
		return m.windows[target.order[0]]
	}
	return nil
}

set_layout :: proc(m: ^Manager, s: ^Space, layout: Layout) {
	if s.view.layout == layout {
		return
	}
	s.view.layout = layout
	node_destroy(s.view.root)
	s.view.root = new(Node)
	// Stable window-id order makes a layout rebuild deterministic.
	ids: [dynamic]u32
	defer delete(ids)
	for id, w in m.windows {
		if w.space == s.id && managed(w) {
			append(&ids, id)
		}
	}
	for i in 1 ..< len(ids) {
		j := i
		for j > 0 && ids[j] < ids[j - 1] {
			ids[j], ids[j - 1] = ids[j - 1], ids[j]
			j -= 1
		}
	}
	for id in ids {
		add(&s.view, id)
	}
	view_update(&s.view)
}

errorf :: proc(format: string, args: ..any) -> string {
	return fmt.tprintf(format, ..args)
}
