package engine

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

Window :: struct {
	opening: Opening,
	resize_transitioning: bool,
	size_feedback_reflow: bool,
	size_intent: Size_Intent,
	size_feedback: Size_Feedback,
	row_revision: u64,
	scroll_frame: Scroll_Frame,
	row_fixed, row_weight: f64,
	row_preset: Maybe(int),
	min_width, min_height, max_width, max_height: f64,
	ordered_in:                                               Maybe(bool),
	root_window:                                              Maybe(bool),
	rules_pending, grabbed:                                   bool,
	rule_error:                                               string,
	windowed_frame:                                           Maybe(Rect),
	// Relative to the usable tile area; retained only during a lone-tile drag.
	solo_tile_frame:                                          Maybe(Rect),
	can_move:                                                 bool,
	can_resize:                                               Maybe(bool),
	application_accessory:                                    bool,
	manage_override:                                          Maybe(bool),
	id:                                                       u32,
	pid:                                                      i32,
	app, title, role, subrole:                                string,
	frame:                                                    Rect,
	level, sub_level:                                         i32,
	display:                                                  u32,
	space:                                                    u64,
	focused, floating, minimized, hidden, fullscreen, sticky: bool,
	shadow:                                                   bool,
	opacity:                                                  f64,
	opacity_override, scratchpad_hidden:                      bool,
	layer_override:                                           bool,
	mouse_follows_focus:                                      Maybe(bool),
	layer:                                                    string,
	scratchpad:                                               string,
}

Display :: struct {
	id, index:     u32,
	native_index:  u32,
	uuid:          string,
	frame, usable: Rect,
	spaces:        [dynamic]u64,
	active_space:  u64,
	label:         string,
}

Space :: struct {
	id:                  u64,
	index, display:      u32,
	uuid, label:         string,
	visible, fullscreen: bool,
	view:                View,
	overrides:           map[string]bool,
}

Action_Kind :: enum {
	Frame,
	Focus,
	Focus_Without_Raise,
	Close,
	Minimize,
	Deminimize,
	Fullscreen,
	Expose,
	Space,
	Opacity,
	Layer,
	Sticky,
	Shadow,
	Order,
	Scale,
	Display_Focus,
	Space_Focus,
	Space_Create,
	Space_Destroy,
	Space_Move,
}

Action :: struct {
	direct: bool,
	kind:               Action_Kind,
	window, relative:   u32,
	display:            u32,
	space, destination: u64,
	frame:              Rect,
	value:              f64,
	duration:           f64,
	flag:               bool,
	live_resize:        bool,
}

Backend :: proc(user: rawptr, action: Action) -> string
Manager :: struct {
	resize_fade: bool,
	motion_trace: Motion_Trace,
	scroll_animate: bool,
	scroll_frame_pacing: bool,
	scroll_time: f64,
	scroll_options: Scroll_Options,
	native_resize_window:                      u32,
	feedback_color:                            u32,
	main_display:                              u32,
	display_order:                             enum {
		Default,
		Vertical,
		Horizontal,
	},
	origin_display:                            enum {
		Default,
		Focused,
		Cursor,
	},
	external_bar:                              enum {
		Off,
		Main,
		All,
	},
	bar_top, bar_bottom:                       f64,
	shadow_mode:                               enum {
		On,
		Off,
		Float,
	},
	shadow_configured:                         bool,
	suspended:                                 bool,
	gesture_active:                            bool,
	mouse:                                     Mouse_Config,
	windows:                                   map[u32]^Window,
	spaces:                                    [dynamic]^Space,
	displays:                                  [dynamic]Display,
	focused, last_focused:                     u32,
	active_space, last_space:                  u64,
	last_display, mouse_window, mouse_display: u32,
	default_layout:                            Layout,
	padding:                                   Padding,
	gap, ratio:                                f64,
	opacity_duration:                          f64,
	animation_duration:                        f64,
	animation_easing:                          Easing,
	balance_axis:                              Split,
	active_opacity, normal_opacity:            f64,
	window_opacity:                            bool,
	split:                                     Split,
	first_child, auto_balance:                 bool,
	zoom_persist:                              bool,
	insertion_point:                           enum {
		Focused,
		First,
		Last,
	},
	backend:                                   Backend,
	backend_user:                              rawptr,
	rules:                                     [dynamic]Rule,
	signals:                                   [dynamic]Signal,
}

manager_init :: proc(m: ^Manager, backend: Backend = nil, user: rawptr = nil) {
	m^ = Manager {
		scroll_options = scroll_options_defaults(),
		feedback_color   = 0xffd75f5f,
		mouse            = mouse_defaults(),
		windows          = make(map[u32]^Window),
		ratio            = 0.5,
		active_opacity   = 1.0,
		normal_opacity   = 1.0,
		default_layout   = .Float,
		zoom_persist     = true,
		animation_easing = .Out_Circ,
		backend          = backend,
		backend_user     = user,
	}
}

window_destroy :: proc(w: ^Window) {
	delete(w.rule_error)
	delete(w.app)
	delete(w.title)
	delete(w.role)
	delete(w.subrole)
	delete(w.scratchpad)
	free(w)
}

manager_destroy :: proc(m: ^Manager) {
	delete(m.motion_trace.events)
	for _, w in m.windows {
		window_destroy(w)
	}
	delete(m.windows)
	for s in m.spaces {
		view_destroy(&s.view)
		delete(s.overrides)
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
	s.overrides = make(map[string]bool)
	s.id = id
	s.display = display
	s.index = index
	view_init(&s.view, frame, m.default_layout)
	s.view.padding = m.padding
	s.view.scroll_options = m.scroll_options
	s.view.gap = m.gap
	s.view.ratio = m.ratio
	s.view.split = m.split
	s.view.auto_balance = m.auto_balance
	s.view.balance_axis = m.balance_axis
	s.view.first_child = m.first_child
	s.view.zoom_persist = m.zoom_persist
	append(&m.spaces, s)
	if d := display_by_id(m, display); d != nil {s.view.frame = usable_frame(m, d)}
	return s
}

managed :: proc(w: ^Window) -> bool {
	if !(w.ordered_in.? or_else true) ||
	   w.floating ||
	   w.minimized ||
	   w.hidden ||
	   w.fullscreen ||
	   w.sticky ||
	   !(w.root_window.? or_else true) {
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
	// A confirmed fixed-size window must keep its native geometry. Unknown
	// capabilities remain eligible; explicit management rules run afterward.
	if resizable, known := w.can_resize.?; w.application_accessory || (known && !resizable) {w.floating = true}
	m.windows[w.id] = w
	if m.origin_display != .Default && managed(w) {
		d :=
			m.origin_display == .Focused \
			? select_display(m, "") \
			: display_by_id(m, m.mouse_display)
		if d != nil && d.active_space != w.space {
			if err := perform(m, {kind = .Space, window = w.id, space = d.active_space});
			   err == "" {w.space, w.display = d.active_space, d.id}
		}
	}
	apply_rules(m, w, initial = true)
	if s := space_by_id(m, w.space); s != nil && layout_admitted(w) {
		add(&s.view, w.id, window_insertion(m, &s.view))
	}
	return w
}

window_insertion :: proc(m: ^Manager, v: ^View) -> u32 {
	if m.insertion_point != .Focused {
		n := m.insertion_point == .First ? first(v.root) : last(v.root)
		if n != nil && n.count > 0 {return n.order[0]}
	}
	return m.focused
}

remove_window :: proc(m: ^Manager, id: u32) {
	if w, ok := m.windows[id]; ok {
		for &rule in m.rules {if rule.pending_window == id {rule.pending_window = 0}}
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

sync_window_membership :: proc(m: ^Manager, w: ^Window, previous_space: u64) -> string {
	if previous := space_by_id(m, previous_space);
	   previous != nil && (previous_space != w.space || !managed(w)) {remove(&previous.view, w.id)}
	if current := space_by_id(m, w.space);
	   current != nil &&
	   layout_admitted(w) &&
	   current.view.layout != .Float &&
	   find(current.view.root, w.id) == nil {
		w.scroll_frame = {}
		if !add(&current.view, w.id, m.focused) {return "destination tiling tree is full"}
	}
	return ""
}

// Remove stale membership before adding newly visible windows. A tab switch
// in a full stack must release the outgoing slot before inserting its replacement.
reconcile_window_memberships :: proc(m: ^Manager) -> string {
	for space in m.spaces {
		remove_ids := make([dynamic]u32, context.temp_allocator)
		for node := first(space.view.root); node != nil; node = next(node) {
			for i in 0 ..< node.count {
				id := node.windows[i]
				window := m.windows[id]
				if window == nil ||
				   !layout_admitted(window) ||
				   window.space != space.id {append(&remove_ids, id)}
			}
		}
		for id in remove_ids {remove(&space.view, id)}
	}
	ids := make([dynamic]u32, context.temp_allocator)
	for id in m.windows {append(&ids, id)}
	sort_ids(ids[:])
	for id in ids {
		window := m.windows[id]
		if err := sync_window_membership(m, window, window.space); err != "" {return err}
	}
	return ""
}

focus_window :: proc(m: ^Manager, id: u32) {
	if id == m.focused {
		return
	}
	opening_note_focus(m, id)
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
	a := a
	if a.kind == .Frame {a.duration = a.direct ? 0 : m.animation_duration}
	return m.backend(m.backend_user, a)
}

flush :: proc(m: ^Manager, s: ^Space, live_resize: bool = false) -> string {
	if m.suspended || m.gesture_active || s == nil || s.view.layout == .Float {
		return ""
	}
	live_resize := live_resize
	if s.view.layout == .BSP && !bsp_constraints(m, &s.view) {return "BSP needs more room for native window constraints"}
	for _, w in m.windows {if w.space == s.id && w.size_feedback_reflow {live_resize = true; break}}
	s.view.scroll.geometry_enabled = m.scroll_animate && m.animation_duration > 0 && !live_resize && m.native_resize_window == 0
	if s.view.layout == .Scroll {
		scroll_constraints(m, &s.view)
		for n := first(s.view.root); n != nil; n = next(n) {n.column_observed = 0}
	}
	view_update(&s.view)
	if s.view.layout == .Scroll {
		scroll_rows(m, &s.view)
		scroll_feedback_prepare(m, s)
		scroll_update(&s.view)
		scroll_rows(m, &s.view, true)
	}
	if s.view.layout == .Scroll && (s.view.scroll.viewport.w <= 0 || s.view.scroll.viewport.h <= 0) {return "scroll layout requires positive usable display dimensions"}
	if s.view.layout == .Scroll {
		// Floating focus and the gap between close and the next AX focus event
		// must not discard this Space's active scrolling column.
		target := m.focused
		if find(s.view.root, target) == nil {target = s.view.scroll.focused}
		if !s.view.scroll.dragging && (s.view.scroll.reveal || s.view.scroll.focused != target) {
			scroll_reveal(&s.view, target)
			s.view.scroll.focused = target
			s.view.scroll.reveal = false
		}
		if m.scroll_animate {
			scroll_motion_prepare(&s.view, m.scroll_time, m.animation_duration > 0 && !live_resize && m.native_resize_window == 0)
			scroll_geometry_prepare(m, s)
		}
	}
	for n := first(s.view.root); n != nil; n = next(n) {
		for i in 0 ..< n.count {
			w := m.windows[n.windows[i]]
			if w == nil || !managed(w) {
				continue
			}
			if w.windowed_frame != nil {continue}
			r := frame_for(n)
			if s.view.layout == .Scroll {
				if m.scroll_animate {
					r = w.scroll_frame.current
					r.x -= s.view.scroll.motion.position
					r.w, r.h = max(1, r.w), max(1, r.h)
					r = n.zoom != nil ? size_feedback_frame(w, s.view.scroll.viewport) : scroll_park_frame(&s.view, r)
				} else {r = scroll_park_frame(&s.view, size_feedback_frame(w, scroll_window_frame(&s.view, n, w.id, false)))}
			}
			if s.view.layout != .Scroll && n == s.view.root && n.count == 1 && n.zoom == nil {
				if relative, chosen := w.solo_tile_frame.?; chosen {
					r = {r.x + relative.x * r.w, r.y + relative.y * r.h, relative.w * r.w, relative.h * r.h}
				}
			}
			if math.abs(w.frame.x - r.x) < 1.5 &&
			   math.abs(w.frame.y - r.y) < 1.5 &&
			   math.abs(w.frame.w - r.w) < 1.5 &&
			   math.abs(w.frame.h - r.h) < 1.5 {
				continue
			}
			if w.id == m.native_resize_window {w.frame = r;continue}
			if err := perform(m, Action{kind = .Frame, window = w.id, frame = r, live_resize = live_resize, direct = s.view.layout == .Scroll && m.scroll_animate}); err != "" {
				return err
			}
			w.frame = r
		}
		if s.view.layout == .Scroll && n.column_tabbed && n.count > 0 && n.column_raised != n.order[0] {
			if err := perform(m, {kind = .Order, window = n.order[0], value = 1}); err != "" {return err}
			n.column_raised = n.order[0]
		}
	}
	for _, w in m.windows {if w.space == s.id {w.size_feedback_reflow = false}}
	return ""
}

select_space :: proc(m: ^Manager, text: string) -> ^Space {
	if text ==
	   "mouse" {if d := display_by_id(m, m.mouse_display); d != nil {return space_by_id(m, d.active_space)};return nil}
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
	if text == "mouse" {return m.windows[m.mouse_window]}
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
		if active == nil {return nil}
		best: ^Node
		best_area: f64
		for candidate := first(active.view.root); candidate != nil; candidate = next(candidate) {
			if candidate.count == 0 {continue}
			area := math.floor(candidate.frame.w * candidate.frame.h)
			if best == nil ||
			   (text == "largest" \
					   ? area > best_area \
					   : area <= best_area) {best = candidate;best_area = area}
		}
		if best != nil {return m.windows[best.order[0]]}
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
	if s.view.layout == .Scroll && (text == "north" || text == "south" || text == "east" || text == "west") {
		return scroll_direction(m, s, w, text)
	}
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
			if branch == nil {return nil};branch = branch.parent
		}
		if branch == nil || branch.parent == nil {return nil}
		target = branch.parent.left == branch ? branch.parent.right : branch.parent.left
		if text == "first_nephew" || text == "first_cousin" {
			if target == nil {return nil};target = target.left
		} else if text == "second_nephew" || text == "second_cousin" {
			if target == nil {return nil};target = target.right
		}
		if target != nil && !leaf(target) {return nil}
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
		if ok && index > 0 && index <= n.count {return m.windows[n.windows[index - 1]]}
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
	zooms := capture_zooms(&s.view)
	defer restore_zooms(&s.view, zooms[:])
	s.view.layout = layout
	s.view.scroll = Scroll_State{reveal = true}
	for _, w in m.windows {if w.space == s.id {w.scroll_frame = {}}}
	node_destroy(s.view.root)
	s.view.root = new(Node)
	// Stable window-id order makes a layout rebuild deterministic.
	ids: [dynamic]u32
	defer delete(ids)
	for id, w in m.windows {
		// Choosing a tiled layout explicitly adopts existing eligible windows;
		// a newcomer still preparing must continue through admission.
		if w.space == s.id && layout != .Float && w.opening.phase == .Excluded && managed(w) {w.opening.phase = .Admitted}
		if w.space == s.id && layout_admitted(w) {
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
	for id, i in ids {
		insertion := layout == .Scroll && i > 0 ? ids[i-1] : u32(0)
		add(&s.view, id, insertion)
	}
	view_update(&s.view)
}

errorf :: proc(format: string, args: ..any) -> string {
	return fmt.tprintf(format, ..args)
}
