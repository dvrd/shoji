package shoji

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

// Manager state and reconciliation
// ------------------------------------------------------------------------

Scroll_Return :: struct {
	space: u64,
	previous, next: u32,
	column_index, row: int,
	peers: [MAX_STACK]u32,
	peer_count: int,
	width: f64,
	size: Scroll_Size,
	preset: Maybe(int),
	full, tabbed: bool,
}

Window :: struct {
	generation: u64,
	frame_valid: Maybe(bool),
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
	ordered_in: Maybe(bool),
	root_window: Maybe(bool),
	rules_pending, grabbed: bool,
	rule_error: string,
	windowed_frame: Maybe(Rect),
	scroll_return: Maybe(Scroll_Return),
	// Relative to the usable tile area; retained only during a lone-tile drag.
	solo_tile_frame: Maybe(Rect),
	can_move: bool,
	can_resize: Maybe(bool),
	application_accessory: bool,
	// A gated WindowServer move (C1 batch, C4 landing) already shows the new
	// position, but the owning app was not told; the next frame write must
	// send AXPosition even though WindowServer's bounds match the target.
	server_placed: bool,
	manage_override: Maybe(bool),
	id: u32,
	pid: i32,
	app, title, role, subrole: string,
	frame: Rect,
	level, sub_level: i32,
	display: u32,
	space: u64,
	focused, floating, minimized, hidden, fullscreen, sticky: bool,
	shadow: bool,
	opacity: f64,
	opacity_override, scratchpad_hidden: bool,
	layer_override: bool,
	mouse_follows_focus: Maybe(bool),
	layer: string,
	scratchpad: string,
}

Display :: struct {
	id, index: u32,
	native_index: u32,
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
	overrides: map[string]bool,
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
	kind: Action_Kind,
	window, relative: u32,
	display: u32,
	space, destination: u64,
	frame: Rect,
	value: f64,
	duration: f64,
	flag: bool,
	live_resize: bool,
}

Backend :: proc(user: rawptr, action: Action) -> string
Layout_Move :: struct {
	window: u32,
	x, y:   f64,
}
LAYOUT_BATCH_LIMIT :: 8
Layout_Batch :: #type proc(user: rawptr, moves: []Layout_Move) -> bool
Manager :: struct {
	window_generation: u64,
	resize_fade: bool,
	motion_trace: Motion_Trace,
	scroll_animate: bool,
	scroll_frame_pacing: bool,
	scroll_time: f64,
	scroll_options: Scroll_Options,
	native_resize_window: u32,
	feedback_color: u32,
	focus_ring: Focus_Ring_Config,
	tab_indicator_top: bool,
	tab_indicator_width: f64,
	tab_indicator_gap: f64,
	tab_indicator_active_color, tab_indicator_inactive_color: Maybe(u32),
	main_display: u32,
	display_order: enum {
		Default,
		Vertical,
		Horizontal,
	},
	origin_display: enum {
		Default,
		Focused,
		Cursor,
	},
	external_bar: enum {
		Off,
		Main,
		All,
	},
	bar_top, bar_bottom: f64,
	shadow_mode: enum {
		On,
		Off,
		Float,
	},
	shadow_configured: bool,
	suspended: bool,
	gesture_active: bool,
	mouse: Mouse_Config,
	windows: map[u32]^Window,
	spaces: [dynamic]^Space,
	displays: [dynamic]Display,
	focused, last_focused: u32,
	active_space, last_space: u64,
	last_display, mouse_window, mouse_display: u32,
	default_layout: Layout,
	padding: Padding,
	gap, ratio: f64,
	opacity_duration: f64,
	animation_duration: f64,
	animation_easing: Easing,
	balance_axis: Split,
	active_opacity, normal_opacity: f64,
	window_opacity: bool,
	split: Split,
	first_child, auto_balance: bool,
	zoom_persist: bool,
	insertion_point: enum {
		Focused,
		First,
		Last,
	},
	backend: Backend,
	backend_user: rawptr,
	// Frame-atomic position batch through the WindowServer gate (C1). Called with backend_user;
	// true only when every move was applied. Nil → per-window frames.
	layout_batch: Layout_Batch,
	// Daemon-only WindowServer diagnostics (`debug ws`); nil elsewhere.
	ws_debug: proc(user: rawptr, dump: bool) -> string,
	// Daemon-only runtime health JSON (`query --health`); nil elsewhere.
	health_report: proc(user: rawptr) -> string,
	health_user: rawptr,
	// Daemon-only `notify test`: posts a test notification; nil elsewhere.
	health_notify_test: proc(user: rawptr) -> Response,
	// Daemon-only `config windowserver_gate [on|off]`; "" queries. Nil elsewhere.
	ws_gate_control: proc(user: rawptr, value: string) -> Response,
	ws_gate_user: rawptr,
	rules: [dynamic]Rule,
	signals: [dynamic]Signal,
}

manager_init :: proc(m: ^Manager, backend: Backend = nil, user: rawptr = nil) {
	m^ = Manager {
		scroll_options = scroll_options_defaults(),
		tab_indicator_width = 4,
		feedback_color = 0xffd75f5f,
		focus_ring = {
			enabled = true,
			width = 3,
			radius = 10,
			color = 0xff7fc8ff,
		},
		mouse = mouse_defaults(),
		windows = make(map[u32]^Window),
		ratio = 0.5,
		active_opacity = 1.0,
		normal_opacity = 1.0,
		default_layout = .Float,
		zoom_persist = true,
		animation_easing = .Out_Circ,
		backend = backend,
		backend_user = user,
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

add_space :: proc(
	m: ^Manager,
	id: u64,
	display, index: u32,
	frame: Rect,
) -> ^Space {
	s := new(Space)
	s.overrides = make(map[string]bool)
	s.id = id
	s.display = display
	s.index = index
	view_init(&s.view, frame, m.default_layout)
	s.view.tab_indicator_top = m.tab_indicator_top
	s.view.tab_indicator_width = m.tab_indicator_width
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
	if d := display_by_id(m, display); d != nil {
		s.view.frame = usable_frame(m, d)
	}
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
	m.window_generation += 1
	w.generation = m.window_generation
	w.app = strings.clone(window.app)
	w.title = strings.clone(window.title)
	w.role = strings.clone(window.role)
	w.subrole = strings.clone(window.subrole)
	w.scratchpad = strings.clone(window.scratchpad)
	// A confirmed fixed-size window must keep its native geometry. Unknown
	// capabilities remain eligible; explicit management rules run afterward.
	if resizable, known := w.can_resize.?;
	   w.application_accessory || (known && !resizable) {
		w.floating = true
	}
	m.windows[w.id] = w
	if m.origin_display != .Default && managed(w) {
		d :=
			m.origin_display == .Focused \
				? select_display(m, "") \
				: display_by_id(m, m.mouse_display)
		if d != nil && d.active_space != w.space {
			if err := perform(
				m,
				{kind = .Space, window = w.id, space = d.active_space},
			); err == "" {
				w.space, w.display = d.active_space, d.id
			}
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
		if n != nil && n.count > 0 {
			return n.order[0]
		}
	}
	return m.focused
}

remove_window :: proc(m: ^Manager, id: u32) {
	if w, ok := m.windows[id]; ok {
		for &rule in m.rules {
			if rule.pending_window == id {
				rule.pending_window = 0
			}
		}
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

sync_window_membership :: proc(
	m: ^Manager,
	w: ^Window,
	previous_space: u64,
) -> string {
	if previous := space_by_id(m, previous_space);
	   previous != nil && (previous_space != w.space || !managed(w)) {
		remove(&previous.view, w.id)
	}
	if current := space_by_id(m, w.space);
	   current != nil &&
	   !current.fullscreen &&
	   layout_admitted(w) &&
	   current.view.layout != .Float &&
	   find(current.view.root, w.id) == nil {
		w.scroll_frame = {}
		restored := scroll_return_restore(w, current)
		if !restored && !add(&current.view, w.id, m.focused) {
			return "destination tiling tree is full"
		}
	}
	return ""
}

scroll_return_remember :: proc(w: ^Window, space: ^Space, node: ^Node) {
	if space.view.layout != .Scroll || w.scroll_return != nil { return }
	r := Scroll_Return {
		space = space.id, width = node.column_width, size = node.column_size,
		preset = node.column_preset, full = node.column_full, tabbed = node.column_tabbed,
	}
	for n := first(space.view.root); n != nil && n != node; n = next(n) { r.column_index += 1 }
	if n := previous(node); n != nil && n.count > 0 { r.previous = n.windows[0] }
	if n := next(node); n != nil && n.count > 0 { r.next = n.windows[0] }
	for i in 0 ..< node.count {
		if node.windows[i] == w.id { r.row = i; continue }
		r.peers[r.peer_count] = node.windows[i]; r.peer_count += 1
	}
	w.scroll_return = r
}

scroll_return_restore :: proc(w: ^Window, space: ^Space) -> bool {
	r, saved := w.scroll_return.?
	if !saved { return false }
	if r.space != space.id || space.view.layout != .Scroll {
		w.scroll_return = nil; return false
	}
	v := &space.view
	for id in r.peers[:r.peer_count] {
		n := find(v.root, id)
		if n == nil || n.count == MAX_STACK { continue }
		if !stack_push(n, w.id) { continue }
		// stack_push inserts after the active row; restore the saved row order.
		at := 0
		for n.windows[at] != w.id { at += 1 }
		row := min(r.row, n.count - 1)
		for at > row { n.windows[at] = n.windows[at - 1]; at -= 1 }
		for at < row { n.windows[at] = n.windows[at + 1]; at += 1 }
		n.windows[row] = w.id
		w.scroll_return = nil; return true
	}
	anchor := find(v.root, r.previous)
	before := false
	if anchor == nil { anchor = find(v.root, r.next); before = anchor != nil }
	if anchor == nil {
		anchor = first(v.root)
		index := 0
		for index < r.column_index && next(anchor) != nil { anchor = next(anchor); index += 1 }
		before = anchor != nil && anchor.count > 0 && index == r.column_index
	}
	if anchor == nil { return false }
	anchor_id := anchor.windows[0]
	insert_first, insert_stack, insertion := anchor.insert_first, anchor.insert_stack, v.insertion
	anchor.insert_first, anchor.insert_stack = before, false
	ok := add(v, w.id, anchor_id)
	if old := find(v.root, anchor_id); old != nil { old.insert_first, old.insert_stack = insert_first, insert_stack }
	v.insertion = insertion
	if !ok { return false }
	n := find(v.root, w.id)
	n.column_width, n.column_resolved = r.width, r.width
	n.column_size, n.column_preset = r.size, r.preset
	n.column_full, n.column_tabbed = r.full, r.tabbed
	w.scroll_return = nil
	return true
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
				if window != nil {
					destination := space_by_id(m, window.space)
					if !layout_admitted(window) ||
					   (destination != nil && destination.fullscreen) {
						scroll_return_remember(window, space, node)
					}
				}
				if window == nil ||
				   space.fullscreen ||
				   !layout_admitted(window) ||
				   window.space != space.id {
					if window != nil && m.motion_trace.active {
						reason: i32
						if window.fullscreen { reason |= 1 }
						if window.hidden { reason |= 2 }
						if window.minimized { reason |= 4 }
						if !(window.ordered_in.? or_else true) { reason |= 8 }
						if window.floating { reason |= 16 }
						if window.sticky { reason |= 32 }
						if !(window.root_window.? or_else true) { reason |= 64 }
						if !layout_admitted(window) { reason |= 128 }
						if window.space != space.id { reason |= 256 }
						motion_trace_record(&m.motion_trace, {
							kind = "scroll-membership-remove", window = id, space = space.id,
							value = f64(window.space), status = reason,
						})
					}
					append(&remove_ids, id)
				}
			}
		}
		for id in remove_ids { remove(&space.view, id) }
	}
	ids := make([dynamic]u32, context.temp_allocator)
	for id in m.windows { append(&ids, id) }
	sort_ids(ids[:])
	for id in ids {
		window := m.windows[id]
		if err := sync_window_membership(m, window, window.space); err != "" {
			return err
		}
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
	if a.kind == .Frame {
		a.duration = a.direct ? 0 : m.animation_duration
	}
	return m.backend(m.backend_user, a)
}

Deferred_Frame :: struct {
	window: ^Window,
	frame:  Rect,
}

// C1: a tiled relayout made only of moves (sizes unchanged), unanimated and
// small enough for the gate's plan, lands in one WindowServer frame before
// the per-window writes. Any other shape skips the batch.
layout_batch_eligible :: proc(m: ^Manager, deferred: []Deferred_Frame, live_resize: bool) -> bool {
	if m.layout_batch == nil || live_resize || m.animation_duration > 0 ||
	   len(deferred) == 0 || len(deferred) > LAYOUT_BATCH_LIMIT {
		return false
	}
	for d in deferred {
		if math.abs(d.window.frame.w - d.frame.w) >= 1.5 || math.abs(d.window.frame.h - d.frame.h) >= 1.5 {
			return false
		}
	}
	return true
}

layout_batch_apply :: proc(m: ^Manager, deferred: []Deferred_Frame, live_resize: bool) -> bool {
	if !layout_batch_eligible(m, deferred, live_resize) {return false}
	moves := make([]Layout_Move, len(deferred), context.temp_allocator)
	for d, i in deferred {moves[i] = {d.window.id, d.frame.x, d.frame.y}}
	return m.layout_batch(m.backend_user, moves)
}

flush :: proc(m: ^Manager, s: ^Space, live_resize: bool = false) -> string {
	if m.suspended || m.gesture_active || s == nil || s.view.layout == .Float {
		return ""
	}
	live_resize := live_resize
	if s.view.layout == .BSP && !bsp_constraints(m, &s.view) {
		return "BSP needs more room for native window constraints"
	}
	for _, w in m.windows {
		if w.space == s.id && w.size_feedback_reflow {
			live_resize = true; break
		}
	}
	s.view.scroll.geometry_enabled =
		m.scroll_animate &&
		m.animation_duration > 0 &&
		!live_resize &&
		m.native_resize_window == 0
	if s.view.layout == .Scroll {
		scroll_constraints(m, &s.view)
		for n := first(s.view.root);
		    n != nil;
		    n = next(n) { n.column_observed = 0 }
	}
	view_update(&s.view)
	if s.view.layout == .Scroll {
		scroll_rows(m, &s.view)
		scroll_feedback_prepare(m, s)
		scroll_update(&s.view)
		scroll_rows(m, &s.view, true)
	}
	if s.view.layout == .Scroll &&
	   (s.view.scroll.viewport.w <= 0 || s.view.scroll.viewport.h <= 0) {
		return "scroll layout requires positive usable display dimensions"
	}
	if s.view.layout == .Scroll {
		// Floating focus and the gap between close and the next AX focus event
		// must not discard this Space's active scrolling column.
		target := m.focused
		if find(s.view.root, target) == nil {
			target = s.view.scroll.focused
		}
		if !s.view.scroll.dragging &&
		   (s.view.scroll.reveal || s.view.scroll.focused != target) {
			scroll_reveal(&s.view, target)
			s.view.scroll.focused = target
			s.view.scroll.reveal = false
		}
		if m.scroll_animate {
			scroll_motion_prepare(
				&s.view,
				m.scroll_time,
				m.animation_duration > 0 &&
				!live_resize &&
				m.native_resize_window == 0,
			)
			scroll_geometry_prepare(m, s)
		}
	}
	deferred := make([dynamic]Deferred_Frame, 0, 16, context.temp_allocator)
	for n := first(s.view.root); n != nil; n = next(n) {
		for i in 0 ..< n.count {
			w := m.windows[n.windows[i]]
			if w == nil || !managed(w) {
				continue
			}
			if w.windowed_frame != nil {
				continue
			}
			r := frame_for(n)
			if s.view.layout == .Scroll {
				if m.scroll_animate {
					r = w.scroll_frame.current
					r.x -= s.view.scroll.motion.position
					r.w, r.h = max(1, r.w), max(1, r.h)
					r =
						n.zoom != nil \
							? size_feedback_frame(w, s.view.scroll.viewport) \
							: scroll_park_frame(&s.view, r)
				} else {
					r = scroll_park_frame(
						&s.view,
						size_feedback_frame(
							w,
							scroll_window_frame(&s.view, n, w.id, false),
						),
					)
				}
			}
			if s.view.layout != .Scroll &&
			   n == s.view.root &&
			   n.count == 1 &&
			   n.zoom == nil {
				if relative, chosen := w.solo_tile_frame.?; chosen {
					r = {
						r.x + relative.x * r.w,
						r.y + relative.y * r.h,
						relative.w * r.w,
						relative.h * r.h,
					}
				}
			}
			if math.abs(w.frame.x - r.x) < 1.5 &&
			   math.abs(w.frame.y - r.y) < 1.5 &&
			   math.abs(w.frame.w - r.w) < 1.5 &&
			   math.abs(w.frame.h - r.h) < 1.5 {
				continue
			}
			if w.id == m.native_resize_window {
				w.frame = r; continue
			}
			if s.view.layout != .Scroll {
				append(&deferred, Deferred_Frame{w, r})
				continue
			}
			if err := perform(
				m,
				Action {
					kind = .Frame,
					window = w.id,
					frame = r,
					live_resize = live_resize,
					direct = s.view.layout == .Scroll && m.scroll_animate,
				},
			); err != "" {
				return err
			}
			w.frame = r
		}
		if s.view.layout == .Scroll &&
		   n.column_tabbed &&
		   n.count > 0 &&
		   n.column_raised != n.order[0] {
			if err := perform(
				m,
				{kind = .Order, window = n.order[0], value = 1},
			); err != "" {
				return err
			}
			n.column_raised = n.order[0]
		}
	}
	// The batch is a visual pre-apply: WindowServer moves every window in one
	// frame, but owning apps are not told (c1c2-foreign-20261105). The normal
	// per-window writes below then resync each app at the position it already
	// shows, so they cause no visible movement.
	if layout_batch_apply(m, deferred[:], live_resize) {
		for d in deferred {d.window.server_placed = true}
	}
	for d in deferred {
		if err := perform(
			m,
			Action{kind = .Frame, window = d.window.id, frame = d.frame, live_resize = live_resize},
		); err != "" {
			return err
		}
		d.window.frame = d.frame
	}
	for _, w in m.windows {
		if w.space == s.id {
			w.size_feedback_reflow = false
		}
	}
	return ""
}

select_space :: proc(m: ^Manager, text: string) -> ^Space {
	if text == "mouse" {
		if d := display_by_id(m, m.mouse_display); d != nil {
			return space_by_id(m, d.active_space)
		}; return nil
	}
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

select_window :: proc(
	m: ^Manager,
	text: string,
	reference: u32 = 0,
) -> ^Window {
	if text == "mouse" {
		return m.windows[m.mouse_window]
	}
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
		if active == nil {
			return nil
		}
		best: ^Node
		best_area: f64
		for candidate := first(active.view.root);
		    candidate != nil;
		    candidate = next(candidate) {
			if candidate.count == 0 {
				continue
			}
			area := math.floor(candidate.frame.w * candidate.frame.h)
			if best == nil ||
			   (text == "largest" ? area > best_area : area <= best_area) {
				best = candidate; best_area = area
			}
		}
		if best != nil {
			return m.windows[best.order[0]]
		}
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
	if s.view.layout == .Scroll &&
	   (text == "north" ||
			   text == "south" ||
			   text == "east" ||
			   text == "west") {
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
	case "sibling",
	     "first_nephew",
	     "second_nephew",
	     "uncle",
	     "first_cousin",
	     "second_cousin":
		branch := n
		if text == "uncle" ||
		   text == "first_cousin" ||
		   text == "second_cousin" {
			if branch == nil {
				return nil
			}; branch = branch.parent
		}
		if branch == nil || branch.parent == nil {
			return nil
		}
		target =
			branch.parent.left == branch \
				? branch.parent.right \
				: branch.parent.left
		if text == "first_nephew" || text == "first_cousin" {
			if target == nil {
				return nil
			}; target = target.left
		} else if text == "second_nephew" || text == "second_cousin" {
			if target == nil {
				return nil
			}; target = target.right
		}
		if target != nil && !leaf(target) {
			return nil
		}
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
		if ok && index > 0 && index <= n.count {
			return m.windows[n.windows[index - 1]]
		}
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
	s.view.scroll = Scroll_State {
		reveal = true,
	}
	for _, w in m.windows {
		if w.space == s.id {
			w.scroll_frame = {}
		}
	}
	node_destroy(s.view.root)
	s.view.root = new(Node)
	// Stable window-id order makes a layout rebuild deterministic.
	ids: [dynamic]u32
	defer delete(ids)
	for id, w in m.windows {
		// Choosing a tiled layout explicitly adopts existing eligible windows;
		// a newcomer still preparing must continue through admission.
		if w.space == s.id &&
		   layout != .Float &&
		   w.opening.phase == .Excluded &&
		   managed(w) {
			w.opening.phase = .Admitted
		}
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
		insertion := layout == .Scroll && i > 0 ? ids[i - 1] : u32(0)
		add(&s.view, id, insertion)
	}
	view_update(&s.view)
}

errorf :: proc(format: string, args: ..any) -> string {
	return fmt.tprintf(format, ..args)
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
	phase: Opening_Phase,
	wait: Opening_Wait,
	focus_origin: u32,
	focus_superseded: bool,
	focus_replacement: u32,
	staged: bool,
	minimum: Rect,
	seed: Rect,
	restore_layer: f64,
	original_layer: f64,
}

Opening_Prepare :: proc(
	m: ^Manager,
	w: ^Window,
	seed: Rect,
) -> (
	Rect,
	bool,
	string,
)
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
	return(
		managed(w) &&
		(w.opening.phase == .Admitted || w.opening.phase == .Opening) \
	)
}

opening_intended :: proc(w: ^Window) -> bool {
	value := w^; value.ordered_in = nil
	return managed(&value)
}

opening_clone_node :: proc(source, parent: ^Node) -> ^Node {
	if source == nil {
		return nil
	}
	n := new(Node); n^ = source^; n.parent = parent; n.zoom = nil
	n.left = opening_clone_node(source.left, n)
	n.right = opening_clone_node(source.right, n)
	return n
}

opening_apply_seed :: proc(
	m: ^Manager,
	w: ^Window,
	seed: Rect,
) -> (
	Rect,
	bool,
	string,
) {
	err := perform(
		m,
		{kind = .Frame, window = w.id, frame = seed, direct = true},
	)
	return seed, err == "", err
}

// Conceal during discovery, before a desktop scan can block on another app.
// Planning and membership changes remain deferred until collection completes.
stage_opening :: proc(
	m: ^Manager,
	w: ^Window,
	backend: Opening_Backend = {},
) -> (
	bool,
	string,
) {
	if w == nil ||
	   w.opening.phase != .Pending ||
	   m.suspended ||
	   m.gesture_active {
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
		o.original_layer =
			w.layer == "above" ? 1 : (w.layer == "below" ? -1 : 0)
		o.restore_layer =
			w.layer_override \
				? (w.layer == "above" ? 1 : (w.layer == "below" ? -1 : 0)) \
				: -1
		if err := perform(m, {kind = .Layer, window = w.id, value = -1});
		   err != "" {
			o.wait = .Backend; return false, err
		}
		if err := perform(m, {kind = .Order, window = w.id, value = -1});
		   err != "" {
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
admit_window :: proc(
	m: ^Manager,
	w: ^Window,
	backend: Opening_Backend = {},
) -> (
	bool,
	string,
) {
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
	defer view_destroy(&v)
	zooms := capture_zooms(&s.view); restore_zooms(&v, zooms[:])
	if !add(&v, w.id, window_insertion(m, &v)) {
		o.wait = .Space; return false, ""
	}
	if v.layout == .BSP {
		if !bsp_constraints(m, &v) {
			o.wait = .Space; return false, ""
		}
		view_update(&v)
	}
	if v.layout == .Scroll {
		v.scroll.geometry_enabled = false
		scroll_constraints(m, &v); view_update(&v); scroll_rows(m, &v)
		if m.focused == w.id && !o.focus_superseded {
			scroll_reveal(&v, w.id); scroll_update(&v); scroll_rows(m, &v)
		}
	}
	n := find(v.root, w.id)
	target :=
		v.layout == .Scroll \
			? scroll_window_frame(&v, n, w.id, false) \
			: frame_for(n)
	if v.layout == .Scroll && target.h > v.scroll.viewport.h {
		o.wait = .Space; return false, ""
	}
	vertical :=
		v.layout == .Scroll || n.parent == nil || n.parent.split == .Vertical
	trailing := v.layout == .Scroll || n.parent == nil || n == n.parent.right
	seed := target
	if vertical {
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
	if math.is_nan(accepted.w) ||
	   math.is_nan(accepted.h) ||
	   accepted.w <= 0 ||
	   accepted.h <= 0 {
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
	parked := v.layout == .Scroll && scroll_park_frame(&v, aligned).x != aligned.x
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
		if parked { world.x = aligned.x }
		world.x +=
			v.scroll.motion.initialized \
				? v.scroll.motion.position \
				: v.scroll.offset
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
		if err := perform(
			m,
			{kind = .Layer, window = w.id, value = w.opening.original_layer},
		); err != "" {
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
		if err := perform(
			m,
			{kind = .Layer, window = w.id, value = w.opening.restore_layer},
		); err != "" {
			return err
		}
		w.layer = w.opening.restore_layer == 1 ? "above" : "normal"
	}
	if !w.opening.focus_superseded && m.focused == w.id {
		if err := perform(m, {kind = .Order, window = w.id, value = 1});
		   err != "" {
			return err
		}
	}
	w.opening.phase = .Admitted
	return ""
}

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

// Scratchpad
// ------------------------------------------------------------------------

// Destination tile position for a window moving to a BSP/Stack Space. The
// window is inserted into the destination tree (staged) so the frame is the
// one flush will apply. Scroll and Float destinations carry no landing.
space_landing :: proc(w: ^Window, source, target: ^Space) -> (landing: Rect, staged: bool) {
	if target == nil || target == source || !layout_admitted(w) ||
	   (target.view.layout != .BSP && target.view.layout != .Stack) {
		return
	}
	if !add(&target.view, w.id) {return}
	view_update(&target.view)
	if n := find(target.view.root, w.id); n != nil {landing = frame_for(n)}
	return landing, true
}

scratchpad_by_label :: proc(m: ^Manager, label: string) -> ^Window {
	if label == "" {
		return nil
	}
	for _, w in m.windows {
		if w.scratchpad == label {
			return w
		}
	}
	return nil
}

scratchpad_show :: proc(m: ^Manager, w: ^Window) -> string {
	s := space_by_id(m, m.active_space)
	if s == nil {
		return "could not locate active space"
	}
	if w.space != s.id {
		if err := perform(m, {kind = .Space, window = w.id, space = s.id});
		   err != "" {
			return err
		}
		if previous := space_by_id(m, w.space); previous != nil {
			remove(&previous.view, w.id)
		}
		w.space, w.display = s.id, s.display
	}
	if err := perform(m, {kind = .Order, window = w.id, value = 1});
	   err != "" {
		return err
	}
	w.scratchpad_hidden = false
	w.ordered_in = true
	if err := perform(m, {kind = .Focus, window = w.id}); err != "" {
		return err
	}
	focus_window(m, w.id)
	return ""
}

scratchpad_toggle :: proc(m: ^Manager, w: ^Window) -> string {
	if w.scratchpad_hidden || (w.space != m.active_space && !w.sticky) {
		return scratchpad_show(m, w)
	}
	if err := perform(m, {kind = .Order, window = w.id, value = 0});
	   err != "" {
		return err
	}
	w.scratchpad_hidden = true
	w.ordered_in = false
	return ""
}

scratchpad_assign :: proc(m: ^Manager, w: ^Window, label: string) -> string {
	if label != "" {
		if scratchpad_by_label(m, label) != nil {
			return "scratchpad label is already assigned"
		}
		copy := strings.clone(label)
		delete(w.scratchpad); w.scratchpad = copy
		w.floating = true; w.manage_override = false
		if s := space_by_id(m, w.space); s != nil {
			remove(&s.view, w.id); return flush(m, s)
		}
	} else {
		if w.scratchpad == "" {
			return "window is not a scratchpad"
		}
		if err := scratchpad_show(m, w); err != "" {
			return err
		}
		delete(w.scratchpad); w.scratchpad = ""
		w.floating = false; w.manage_override = nil
		if w.opening.phase == .Excluded {
			w.opening.phase = .Admitted
		}
		if s := space_by_id(m, w.space); s != nil && layout_admitted(w) {
			add(&s.view, w.id); return flush(m, s)
		}
	}
	return ""
}

scratchpad_recover :: proc(m: ^Manager) -> string {
	for _, w in m.windows {
		if w.scratchpad == "" {
			continue
		}
		if err := perform(m, {kind = .Order, window = w.id, value = 1});
		   err != "" {
			return err
		}
		w.scratchpad_hidden = false
		w.ordered_in = true
	}
	return ""
}

// Accepted-size feedback
// ------------------------------------------------------------------------

// A settled observation applies to one intent/context, not a learned universal
// minimum or maximum. Explicit retries and changed layout contexts invalidate it.
Size_Intent :: struct {
	w, h: f64,
	width_revision, height_revision: u64,
	viewport: Rect,
	space: u64,
	display: u32,
	pid: i32,
	zoomed, tabbed: bool,
}
Size_Feedback :: struct {
	intent: Size_Intent,
	accepted: Rect,
	width_valid, height_valid: bool,
	pending: bool,
	generation: u64,
	expected, sample: Rect,
	requested_at, checked_at, sampled_at: f64,
	observations: int,
}
size_feedback_invalidate :: proc(w: ^Window) {
	f := &w.size_feedback
	i := w.size_intent
	context_changed :=
		f.intent.viewport != i.viewport ||
		f.intent.space != i.space ||
		f.intent.display != i.display ||
		f.intent.pid != i.pid ||
		f.intent.zoomed != i.zoomed ||
		f.intent.tabbed != i.tabbed
	width_changed :=
		context_changed ||
		f.intent.w != i.w ||
		f.intent.width_revision != i.width_revision
	height_changed :=
		context_changed ||
		f.intent.h != i.h ||
		f.intent.height_revision != i.height_revision
	if width_changed || height_changed {
		// Application constraints may couple width and height (for example an
		// aspect ratio), so changing either intent invalidates both adjustments.
		f.width_valid, f.height_valid = false, false
		f.pending = false; f.generation += 1; f.observations = 0
	}
	f.intent = i
}
size_feedback_request :: proc(
	w: ^Window,
	requested, previous: Rect,
	now: f64,
) {
	size_feedback_invalidate(w)
	f := &w.size_feedback
	if math.abs(requested.w - previous.w) <= 1 &&
	   math.abs(requested.h - previous.h) <= 1 {
		return
	}
	if f.pending &&
	   math.abs(f.expected.w - requested.w) <= 1 &&
	   math.abs(f.expected.h - requested.h) <= 1 {
		return
	}
	f.generation += 1
	f.expected, f.requested_at, f.checked_at = requested, now, now
	f.pending, f.observations = true, 0
}
size_feedback_duplicate :: proc(w: ^Window, requested: Rect) -> bool {
	f := &w.size_feedback
	return(
		f.pending &&
		math.abs(f.expected.w - requested.w) <= 1 &&
		math.abs(f.expected.h - requested.h) <= 1 \
	)
}
size_feedback_observe :: proc(
	w: ^Window,
	generation: u64,
	observed: Rect,
	now: f64,
) -> bool {
	f := &w.size_feedback
	if generation != f.generation ||
	   !f.pending ||
	   now - f.requested_at < 0.15 ||
	   now - f.checked_at < 0.06 {
		return false
	}
	f.checked_at = now
	if math.is_nan(observed.w) ||
	   math.is_nan(observed.h) ||
	   math.is_inf(observed.w) ||
	   math.is_inf(observed.h) ||
	   observed.w <= 0 ||
	   observed.h <= 0 {
		return false
	}
	if f.observations == 0 ||
	   math.abs(f.sample.w - observed.w) > 1 ||
	   math.abs(f.sample.h - observed.h) > 1 {
		f.sample, f.sampled_at, f.observations = observed, now, 1
		return false
	}
	if now - f.sampled_at < 0.06 {
		return false
	}
	f.pending = false
	changed := false
	if math.abs(observed.w - f.intent.w) <= 1 {
		if f.width_valid {
			f.width_valid, changed = false, true
		}
	} else if math.abs(observed.w - f.expected.w) > 1 {
		f.accepted.w, f.width_valid, changed = observed.w, true, true
	}
	if math.abs(observed.h - f.intent.h) <= 1 {
		if f.height_valid {
			f.height_valid, changed = false, true
		}
	} else if math.abs(observed.h - f.expected.h) > 1 {
		f.accepted.h, f.height_valid, changed = observed.h, true, true
	}
	if changed {
		w.size_feedback_reflow = true
	}
	return changed
}
// A late client response that matches the original intent supersedes a
// provisional adjustment. This never fabricates a minimum from a failed read.
size_feedback_late_result :: proc(w: ^Window, observed: Rect) -> bool {
	f := &w.size_feedback
	if f.pending {
		return false
	}
	changed := false
	if f.width_valid &&
	   observed.w > 0 &&
	   math.abs(observed.w - f.intent.w) <= 1 {
		f.width_valid, changed = false, true
	}
	if f.height_valid &&
	   observed.h > 0 &&
	   math.abs(observed.h - f.intent.h) <= 1 {
		f.height_valid, changed = false, true
	}
	if changed {
		w.size_feedback_reflow = true
	}
	return changed
}

scroll_feedback_prepare :: proc(m: ^Manager, s: ^Space) {
	v := &s.view
	for n := first(v.root); n != nil; n = next(n) {
		n.column_observed = 0
		any_observed := false
		footprint: f64
		for i in 0 ..< n.count {
			w := m.windows[n.windows[i]]
			if w == nil {
				continue
			}
			width, height := n.column_width, n.row_heights[i]
			if n.column_tabbed {
				height = n.frame.h
				if v.tab_indicator_top {
					height = max(1, height - tab_indicator_gutter(v, n))
				} else {
					width = max(1, width - tab_indicator_gutter(v, n))
				}
			}
			if n.zoom != nil {
				width, height = v.scroll.viewport.w, v.scroll.viewport.h
			}
			w.size_intent = {
				w               = width,
				h               = height,
				width_revision  = n.column_revision,
				height_revision = w.row_revision,
				viewport        = v.scroll.viewport,
				space           = s.id,
				display         = s.display,
				pid             = w.pid,
				tabbed          = n.column_tabbed,
				zoomed          = n.zoom != nil,
			}
			size_feedback_invalidate(w)
			if w.size_feedback.width_valid && n.zoom == nil {
				gutter := v.tab_indicator_top ? f64(0) : tab_indicator_gutter(v, n)
				footprint = max(footprint, w.size_feedback.accepted.w + gutter)
				any_observed = true
			} else {
				footprint = max(footprint, n.column_width)
			}
		}
		if any_observed {
			n.column_observed = footprint
		}
	}
}

size_feedback_frame :: proc(w: ^Window, frame: Rect) -> Rect {
	r := frame
	if w.size_feedback.width_valid {
		r.w = w.size_feedback.accepted.w
	}
	if w.size_feedback.height_valid {
		r.h = w.size_feedback.accepted.h
	}
	return r
}
