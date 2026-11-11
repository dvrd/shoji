package shoji

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:time"
import dock "dock"
import layout "layout"

// Manager state and reconciliation
// ------------------------------------------------------------------------

Scroll_Return :: struct {
	space:             u64,
	previous, next:    u32,
	column_index, row: int,
	peers:             [layout.MAX_STACK]u32,
	peer_count:        int,
	width:             f64,
	size:              layout.Scroll_Size,
	preset:            Maybe(int),
	full, tabbed:      bool,
}

Window :: struct {
	generation:                                               u64,
	frame_valid:                                              Maybe(bool),
	opening:                                                  Opening,
	resize_transitioning:                                     bool,
	size_feedback_reflow:                                     bool,
	size_intent:                                              Size_Intent,
	size_feedback:                                            Size_Feedback,
	// The narrowest width the app has kept: learned when it refuses a
	// narrower one, lowered when it accepts one. Keyboard shrink stops here.
	learned_min_width:                                        f64,
	row_revision:                                             u64,
	scroll_frame:                                             Scroll_Frame,
	row_fixed, row_weight:                                    f64,
	row_preset:                                               Maybe(int),
	min_width, min_height, max_width, max_height:             f64,
	ordered_in:                                               Maybe(bool),
	root_window:                                              Maybe(bool),
	// SLS parent window. Unmanaged children follow this window's frame delta.
	parent:                                                   u32,
	rules_pending, grabbed:                                   bool,
	rule_error:                                               string,
	// Last matched scroll-opening rule. Applied when this window is in a
	// scrolling column, including a later switch onto the scroll layout.
	rule_maximize:                                            Maybe(bool),
	rule_column_width, rule_column_display:                   string,
	windowed_frame:                                           Maybe(Rect),
	scroll_return:                                            Maybe(Scroll_Return),
	// Relative to the usable tile area; retained only during a lone-tile drag.
	solo_tile_frame:                                          Maybe(Rect),
	can_move:                                                 bool,
	can_resize:                                               Maybe(bool),
	application_accessory:                                    bool,
	// A gated WindowServer move (C1 batch, C4 landing) already shows the new
	// position, but the owning app was not told; the next frame write must
	// send AXPosition even though WindowServer's bounds match the target.
	server_placed:                                            bool,
	// Moved by a gated camera batch during scroll motion: WindowServer shows
	// the frame, the app has not been told. The first unbatched flush resyncs.
	ax_stale:                                                 bool,
	// Inactive tab hidden through the Dock payload (not drawn, not hit-tested).
	concealed:                                                bool,
	// Keyboard scroll resize, niri style: the final size is sent once per
	// target, and whatever buffer the app has (`resize_basis`) is scaled onto
	// the animated rect. `frame` is that visual rect until the spring settles.
	resize_basis, resize_request:                             Rect,
	resize_scaled, resize_transformed:                        bool,
	// A hidden tab made transparent for a keyboard resize. It keeps its old
	// size until Settle and would show around a shrinking active tab.
	resize_faded:                                             bool,
	// When the last scaled resize settled. A late app move shifts the reset
	// transform, so it is re-checked against the bounds for a moment.
	resize_settled_at:                                        f64,
	// Parked frame clipped to the viewport. Coords are window-local. Cleared
	// once the frame sits fully inside again.
	viewport_clipped:                                         bool,
	clip_repaired:                                            bool,
	clip_x, clip_y, clip_w, clip_h:                           i32,
	// The payload refused to conceal; retried once the window is active again.
	conceal_refused:                                          bool,
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
	// Shadow tag cleared while this tab is concealed. The desired shadow stays
	// in `shadow`; this only means the tag has to come back on reveal.
	shadow_held:                                              bool,
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
	id:                                                 u64,
	index, display:                                     u32,
	uuid, label:                                        string,
	visible, fullscreen, ephemeral, kept, home_visible: bool,
	home_uuid:                                          string,
	view:                                               layout.View,
	overrides:                                          map[string]bool,
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
	Conceal,
}

Action :: struct {
	direct:             bool,
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
Layout_Move :: struct {
	window: u32,
	x, y:   f64,
}
// Window moves in one camera frame. Owned focus-ring and tab-indicator moves
// are added on top, up to the gate's LAYOUT_LIMIT (32 + 8 + 32).
LAYOUT_BATCH_LIMIT :: 32
OWNED_BATCH_LIMIT :: 40
Layout_Batch :: #type proc(user: rawptr, moves: []Layout_Move) -> bool
Manager :: struct {
	window_generation:                                            u64,
	resize_fade:                                                  bool,
	motion_trace:                                                 Motion_Trace,
	scroll_animate:                                               bool,
	// B02: conceal inactive tabs instead of only ordering them behind.
	tab_conceal:                                                  bool,
	scroll_frame_pacing:                                          bool,
	scroll_time:                                                  f64,
	scroll_options:                                               layout.Scroll_Options,
	native_resize_window:                                         u32,
	// Set for one flush by a keyboard scroll resize. The geometry retarget
	// then starts at speed omega*distance, which neither sits nor overshoots.
	resize_chase:                                                 bool,
	// While set, an in-flight keyboard resize scales through scale_present
	// instead of sending the app every intermediate size.
	resize_scale:                                                 bool,
	resize_scale_noted:                                           bool,
	feedback_color:                                               u32,
	focus_ring:                                                   Focus_Ring_Config,
	tab_indicator_top:                                            bool,
	tab_indicator_width:                                          f64,
	tab_indicator_gap:                                            f64,
	tab_indicator_active_color, tab_indicator_inactive_color:     Maybe(u32),
	main_display:                                                 u32,
	display_order:                                                enum {
		Default,
		Vertical,
		Horizontal,
	},
	origin_display:                                               enum {
		Default,
		Focused,
		Cursor,
	},
	external_bar:                                                 enum {
		Off,
		Main,
		All,
	},
	bar_top, bar_bottom:                                          f64,
	shadow_mode:                                                  enum {
		On,
		Off,
		Float,
	},
	shadow_configured:                                            bool,
	suspended:                                                    bool,
	gesture_active:                                               bool,
	mouse:                                                        Mouse_Config,
	windows:                                                      map[u32]^Window,
	spaces:                                                       [dynamic]^Space,
	displays:                                                     [dynamic]Display,
	focused, last_focused:                                        u32,
	active_space, last_space:                                     u64,
	last_display, mouse_window, mouse_display:                    u32,
	default_layout:                                               layout.Layout,
	padding:                                                      layout.Padding,
	gap, ratio:                                                   f64,
	opacity_duration:                                             f64,
	animation_duration:                                           f64,
	animation_easing:                                             Easing,
	balance_axis:                                                 layout.Split,
	active_opacity, normal_opacity:                               f64,
	window_opacity:                                               bool,
	split:                                                        layout.Split,
	first_child, auto_balance:                                    bool,
	zoom_persist:                                                 bool,
	insertion_point:                                              enum {
		Focused,
		First,
		Last,
	},
	backend:                                                      Backend,
	backend_user:                                                 rawptr,
	// Frame-atomic position batch through the WindowServer gate (C1). Called with backend_user;
	// true only when every move was applied. Nil → per-window frames.
	layout_batch:                                                 Layout_Batch,
	// Dock presentation for viewport clip. Nil skips it (tests, no payload).
	present:                                                      proc(
		user: rawptr,
		req: dock.Present_Request,
	) -> string,
	// Sends a scaled resize's final size without blocking the frame loop. Nil
	// (tests) sends it as a Frame action.
	resize_configure:                                             proc(
		user: rawptr,
		id: u32,
		request: Rect,
	) -> string,
	// Settled hidden tab: position and size written off the main loop.
	resize_configure_hidden:                                      proc(
		user: rawptr,
		id: u32,
		request: Rect,
	) -> string,
	// Size WindowServer holds for the window's buffer. Nil (tests) assumes the
	// app took the last size write.
	window_bounds:                                                proc(
		user: rawptr,
		id: u32,
	) -> (
		Rect,
		bool,
	),
	// Direct Dock transform for a keyboard resize. Nil keeps per-frame size
	// writes. Not the gated present path: that hold would run every frame.
	scale_present:                                                proc(
		user: rawptr,
		req: dock.Present_Request,
	) -> string,
	clip_noted:                                                   bool,
	// Viewport clip is off until GlobalClipShape's coordinate space is
	// live-checked: window-local rects cut windows at the bottom on 26B123.
	// Off, each window gets one unbounded clip to undo an earlier cut.
	viewport_clip:                                                bool,
	// While set, scroll_camera_apply stores moves instead of sending them.
	// layout_frame_submit sends those moves and any owned surfaces together.
	camera_hold:                                                  bool,
	camera_held:                                                  int,
	camera_moves:                                                 [LAYOUT_BATCH_LIMIT]Layout_Move,
	// Empty skips the Dock-restart check. The daemon sets the journal path.
	conceal_journal:                                              string,
	conceal_boot:                                                 u64,
	conceal_stamp:                                                i64,
	// Daemon-only WindowServer diagnostics (`debug ws`); nil elsewhere.
	ws_debug:                                                     proc(
		user: rawptr,
		dump: bool,
	) -> string,
	// Daemon-only runtime health JSON (`query --health`); nil elsewhere.
	health_report:                                                proc(user: rawptr) -> string,
	health_user:                                                  rawptr,
	// Daemon-only `notify test`: posts a test notification; nil elsewhere.
	health_notify_test:                                           proc(user: rawptr) -> Response,
	// Daemon-only: tells the user why a command did less than asked. Nil
	// elsewhere (tests record it through their own hook).
	health_notice:                                                proc(user: rawptr, title, body: string),
	// Daemon-only `config windowserver_gate [on|off]`; "" queries. Nil elsewhere.
	ws_gate_control:                                              proc(
		user: rawptr,
		value: string,
	) -> Response,
	ws_gate_user:                                                 rawptr,
	rules:                                                        [dynamic]Rule,
	signals:                                                      [dynamic]Signal,
	// Opt-in. See workspaces.odin. Both stay off so existing Spaces are left alone.
	dynamic_workspaces, workspace_hotplug, workspace_reconciling: bool,
	workspace_seq:                                                u64,
	workspace_pending_display:                                    [WORKSPACE_PENDING_MAX]u32,
	workspace_pending_space:                                      [WORKSPACE_PENDING_MAX]u64,
	workspace_pending_count:                                      int,
	overview:                                                     Overview,
}

manager_init :: proc(m: ^Manager, backend: Backend = nil, user: rawptr = nil) {
	m^ = Manager {
		scroll_options = layout.scroll_options_defaults(),
		tab_indicator_width = 4,
		feedback_color = 0xffd75f5f,
		focus_ring = {enabled = true, width = 3, radius = 10, color = 0xff7fc8ff},
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
	delete(w.rule_column_width)
	delete(w.rule_column_display)
	delete(w.app)
	delete(w.title)
	delete(w.role)
	delete(w.subrole)
	delete(w.scratchpad)
	free(w)
}

manager_destroy :: proc(m: ^Manager) {
	overview_free_for_destroy(m)
	delete(m.conceal_journal)
	delete(m.motion_trace.events)
	for _, w in m.windows {
		window_destroy(w)
	}
	delete(m.windows)
	for s in m.spaces {
		layout.view_destroy(&s.view)
		delete(s.overrides)
		delete(s.uuid)
		delete(s.label)
		delete(s.home_uuid)
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
	layout.view_init(&s.view, frame, m.default_layout)
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
	if resizable, known := w.can_resize.?; w.application_accessory || (known && !resizable) {
		w.floating = true
	}
	m.windows[w.id] = w
	if m.origin_display != .Default && managed(w) {
		d :=
			m.origin_display == .Focused \
				? select_display(m, "") \
				: display_by_id(m, m.mouse_display)
		if d != nil && d.active_space != w.space {
			if err := perform(m, {kind = .Space, window = w.id, space = d.active_space});
			   err == "" {
				w.space, w.display = d.active_space, d.id
			}
		}
	}
	apply_rules(m, w, initial = true)
	if s := space_by_id(m, w.space); s != nil && layout_admitted(w) {
		insertion := s.view.insertion
		layout.add(&s.view, w.id, window_insertion(m, &s.view))
		scroll_rule_realize(m, w)
		motion_trace_join(m, s, w.id, "layout-join")
		if insertion != 0 && s.view.insertion == 0 {
			motion_trace_record(
				&m.motion_trace,
				{kind = "insert-consumed", window = w.id, space = s.id, value = f64(insertion)},
			)
		}
	}
	workspace_reconcile(m)
	return w
}

window_insertion :: proc(m: ^Manager, v: ^layout.View) -> u32 {
	if m.insertion_point != .Focused {
		n := m.insertion_point == .First ? layout.first(v.root) : layout.last(v.root)
		if n != nil && n.count > 0 {
			return n.order[0]
		}
	}
	return m.focused
}

remove_window :: proc(m: ^Manager, id: u32) {
	if w, ok := m.windows[id]; ok {
		motion_trace_record(
			&m.motion_trace,
			{kind = "window-removed", window = id, space = w.space},
		)
		for &rule in m.rules {
			if rule.pending_window == id {
				rule.pending_window = 0
			}
		}
		if s := space_by_id(m, w.space); s != nil {
			layout.remove(&s.view, id)
		}
		if m.focused == id {
			m.focused = 0
		}
		if m.last_focused == id {
			m.last_focused = 0
		}
		delete_key(&m.windows, id)
		window_destroy(w)
		workspace_reconcile(m)
	}
}

sync_window_membership :: proc(m: ^Manager, w: ^Window, previous_space: u64) -> string {
	if previous := space_by_id(m, previous_space);
	   previous != nil && (previous_space != w.space || !managed(w)) {
		layout.remove(&previous.view, w.id)
	}
	if current := space_by_id(m, w.space);
	   current != nil &&
	   !current.fullscreen &&
	   layout_admitted(w) &&
	   current.view.layout != .Float &&
	   layout.find(current.view.root, w.id) == nil {
		w.scroll_frame = {}
		restored := scroll_return_restore(w, current)
		if !restored && !layout.add(&current.view, w.id, m.focused) {
			return "destination tiling tree is full"
		}
	}
	workspace_reconcile(m)
	return ""
}

scroll_return_remember :: proc(w: ^Window, space: ^Space, node: ^layout.Node) {
	if space.view.layout != .Scroll || w.scroll_return != nil {
		return
	}
	r := Scroll_Return {
		space  = space.id,
		width  = node.column_width,
		size   = node.column_size,
		preset = node.column_preset,
		full   = node.column_full,
		tabbed = node.column_tabbed,
	}
	for n := layout.first(space.view.root);
	    n != nil && n != node;
	    n = layout.next(n) {r.column_index += 1}
	if n := layout.previous(node); n != nil && n.count > 0 {
		r.previous = n.windows[0]
	}
	if n := layout.next(node); n != nil && n.count > 0 {
		r.next = n.windows[0]
	}
	for i in 0 ..< node.count {
		if node.windows[i] == w.id {
			r.row = i; continue
		}
		r.peers[r.peer_count] = node.windows[i]; r.peer_count += 1
	}
	w.scroll_return = r
}

scroll_return_restore :: proc(w: ^Window, space: ^Space) -> bool {
	r, saved := w.scroll_return.?
	if !saved {
		return false
	}
	if r.space != space.id || space.view.layout != .Scroll {
		w.scroll_return = nil; return false
	}
	v := &space.view
	for id in r.peers[:r.peer_count] {
		n := layout.find(v.root, id)
		if n == nil || n.count == layout.MAX_STACK {
			continue
		}
		if !layout.stack_push(n, w.id) {
			continue
		}
		// stack_push inserts after the active row; restore the saved row order.
		at := 0
		for n.windows[at] != w.id {at += 1}
		row := min(r.row, n.count - 1)
		for at > row {n.windows[at] = n.windows[at - 1]; at -= 1}
		for at < row {n.windows[at] = n.windows[at + 1]; at += 1}
		n.windows[row] = w.id
		w.scroll_return = nil; return true
	}
	anchor := layout.find(v.root, r.previous)
	before := false
	if anchor == nil {
		anchor = layout.find(v.root, r.next); before = anchor != nil
	}
	if anchor == nil {
		anchor = layout.first(v.root)
		index := 0
		for index < r.column_index &&
		    layout.next(anchor) != nil {anchor = layout.next(anchor); index += 1}
		before = anchor != nil && anchor.count > 0 && index == r.column_index
	}
	if anchor == nil {
		return false
	}
	anchor_id := anchor.windows[0]
	insert_first, insert_stack, insertion := anchor.insert_first, anchor.insert_stack, v.insertion
	anchor.insert_first, anchor.insert_stack = before, false
	ok := layout.add(v, w.id, anchor_id)
	if old := layout.find(v.root, anchor_id); old != nil {
		old.insert_first, old.insert_stack = insert_first, insert_stack
	}
	v.insertion = insertion
	if !ok {
		return false
	}
	n := layout.find(v.root, w.id)
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
		for node := layout.first(space.view.root); node != nil; node = layout.next(node) {
			for i in 0 ..< node.count {
				id := node.windows[i]
				window := m.windows[id]
				if window != nil {
					destination := space_by_id(m, window.space)
					if !layout_admitted(window) || (destination != nil && destination.fullscreen) {
						scroll_return_remember(window, space, node)
					}
				}
				if window == nil ||
				   space.fullscreen ||
				   !layout_admitted(window) ||
				   window.space != space.id {
					if window != nil && m.motion_trace.active {
						reason: i32
						if window.fullscreen {
							reason |= 1
						}
						if window.hidden {
							reason |= 2
						}
						if window.minimized {
							reason |= 4
						}
						if !(window.ordered_in.? or_else true) {
							reason |= 8
						}
						if window.floating {
							reason |= 16
						}
						if window.sticky {
							reason |= 32
						}
						if !(window.root_window.? or_else true) {
							reason |= 64
						}
						if !layout_admitted(window) {
							reason |= 128
						}
						if window.space != space.id {
							reason |= 256
						}
						motion_trace_record(
							&m.motion_trace,
							{
								kind = "scroll-membership-remove",
								window = id,
								space = space.id,
								value = f64(window.space),
								status = reason,
							},
						)
					}
					append(&remove_ids, id)
				}
			}
		}
		for id in remove_ids {layout.remove(&space.view, id)}
	}
	ids := make([dynamic]u32, context.temp_allocator)
	for id in m.windows {append(&ids, id)}
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
			layout.focus_order(layout.find(s.view.root, id), id)
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
	if m.layout_batch == nil ||
	   live_resize ||
	   m.animation_duration > 0 ||
	   len(deferred) == 0 ||
	   len(deferred) > LAYOUT_BATCH_LIMIT {
		return false
	}
	for d in deferred {
		if math.abs(d.window.frame.w - d.frame.w) >= 1.5 ||
		   math.abs(d.window.frame.h - d.frame.h) >= 1.5 {
			return false
		}
	}
	return true
}

// E2: a scroll camera frame moves whole columns without resizing them. While
// a finger drags the strip or the camera spring runs, those moves go through
// one gated batch per frame so every window lands in the same WindowServer
// frame. Accessibility learns the final position from the first flush after
// the camera is still (Window.ax_stale): the release flush when the spring is
// off, otherwise the flush that settles the spring.
scroll_camera_batching :: proc(m: ^Manager, s: ^Space, live_resize: bool) -> bool {
	moving := s.view.scroll.dragging || (m.scroll_animate && s.view.scroll.motion.active)
	return(
		m.layout_batch != nil &&
		s.view.layout == .Scroll &&
		moving &&
		!live_resize &&
		m.native_resize_window == 0 \
	)
}

// A later flush in the same held frame replaces a window's position.
// False when this flush's new windows do not fit; nothing from it is stored.
camera_hold_store :: proc(m: ^Manager, moves: []Deferred_Frame) -> bool {
	fresh := 0
	for d in moves {
		seen := false
		for i in 0 ..< m.camera_held {
			if m.camera_moves[i].window == d.window.id {
				seen = true; break
			}
		}
		if !seen {
			fresh += 1
		}
	}
	if m.camera_held + fresh > LAYOUT_BATCH_LIMIT {
		return false
	}
	for d in moves {
		move := Layout_Move{d.window.id, d.frame.x, d.frame.y}
		replaced := false
		for i in 0 ..< m.camera_held {
			if m.camera_moves[i].window == move.window {
				m.camera_moves[i] = move
				replaced = true
				break
			}
		}
		if !replaced {
			m.camera_moves[m.camera_held] = move
			m.camera_held += 1
		}
	}
	return true
}

layout_frame_fallback :: proc(m: ^Manager, moves: []Layout_Move) {
	for move in moves {
		w := m.windows[move.window]
		if w == nil {
			continue
		}
		if err := perform(
			m,
			Action{kind = .Frame, window = move.window, frame = w.frame, direct = true},
		); err != "" {
			continue
		}
		w.ax_stale = false
		w.server_placed = false
	}
}

// Sends the held camera moves and `owned` surfaces in one layout batch.
// False means `owned` was not in a successful batch; the caller places those
// surfaces itself. Held window moves are still applied, by the batch or by
// the per-window fallback.
layout_frame_submit :: proc(m: ^Manager, owned: []Layout_Move) -> bool {
	held := m.camera_held
	windows := m.camera_moves[:held]
	m.camera_held = 0
	if held == 0 && len(owned) == 0 {
		return true
	}
	if m.layout_batch == nil {
		layout_frame_fallback(m, windows)
		return false
	}
	if len(owned) == 0 {
		if m.layout_batch(m.backend_user, windows) {
			return true
		}
		layout_frame_fallback(m, windows)
		return false
	}
	combined := make([dynamic]Layout_Move, 0, held + len(owned), context.temp_allocator)
	append(&combined, ..windows)
	append(&combined, ..owned)
	if m.layout_batch(m.backend_user, combined[:]) {
		return true
	}
	if held > 0 && m.layout_batch(m.backend_user, windows) {
		return false
	}
	layout_frame_fallback(m, windows)
	return false
}

// Batches the frame's pure moves; any failure (too many windows, a window
// still animating, the gate refusing) falls back to per-window writes.
scroll_camera_apply :: proc(m: ^Manager, moves: []Deferred_Frame, live_resize: bool) -> string {
	if len(moves) == 0 {
		return ""
	}
	if m.camera_hold && m.layout_batch != nil {
		if camera_hold_store(m, moves) {
			for d in moves {
				d.window.frame = d.frame
				d.window.server_placed = true
				d.window.ax_stale = true
			}
			return ""
		}
		// This flush does not fit. Keep earlier holds, refresh any window
		// already in them, and place only the new windows one by one.
		for d in moves {
			replaced := false
			for i in 0 ..< m.camera_held {
				if m.camera_moves[i].window == d.window.id {
					m.camera_moves[i] = {d.window.id, d.frame.x, d.frame.y}
					d.window.frame = d.frame
					d.window.server_placed = true
					d.window.ax_stale = true
					replaced = true
					break
				}
			}
			if replaced {
				continue
			}
			action := Action {
				kind        = .Frame,
				window      = d.window.id,
				frame       = d.frame,
				live_resize = live_resize,
				direct      = true,
			}
			if err := perform(m, action); err != "" {
				return err
			}
			d.window.frame = d.frame
			d.window.ax_stale = false
		}
		return ""
	}
	if len(moves) <= LAYOUT_BATCH_LIMIT {
		batch := make([]Layout_Move, len(moves), context.temp_allocator)
		for d, i in moves {batch[i] = {d.window.id, d.frame.x, d.frame.y}}
		if m.layout_batch(m.backend_user, batch) {
			for d in moves {
				d.window.frame = d.frame
				d.window.server_placed = true
				d.window.ax_stale = true
			}
			return ""
		}
	}
	for d in moves {
		action := Action {
			kind        = .Frame,
			window      = d.window.id,
			frame       = d.frame,
			live_resize = live_resize,
			direct      = true,
		}
		if err := perform(m, action); err != "" {
			return err
		}
		d.window.frame = d.frame
		d.window.ax_stale = false
	}
	return ""
}

layout_batch_apply :: proc(m: ^Manager, deferred: []Deferred_Frame, live_resize: bool) -> bool {
	if !layout_batch_eligible(m, deferred, live_resize) {
		return false
	}
	moves := make([]Layout_Move, len(deferred), context.temp_allocator)
	for d, i in deferred {moves[i] = {d.window.id, d.frame.x, d.frame.y}}
	return m.layout_batch(m.backend_user, moves)
}

// Maps the committed buffer onto the visual rect. The inverse form matches
// the identity WindowServer stores for an unscaled window, {1, 0, 0, 1, -x, -y}.
resize_scale_matrix :: proc(basis, visual: Rect) -> (a, d, tx, ty: f64, ok: bool) {
	if basis.w < 1 || basis.h < 1 || visual.w < 1 || visual.h < 1 {
		return
	}
	a, d = basis.w / visual.w, basis.h / visual.h
	tx, ty = -visual.x * a, -visual.y * d
	return a, d, tx, ty, true
}

resize_scale_send :: proc(m: ^Manager, w: ^Window, a, d, tx, ty: f64) -> string {
	if m.scale_present == nil {
		return "resize scale is unavailable"
	}
	started := time.tick_now()
	err := m.scale_present(
		m.backend_user,
		dock.Present_Request {
			window = w.id,
			mask = dock.PRESENT_TRANSFORM,
			a = a,
			d = d,
			tx = tx,
			ty = ty,
		},
	)
	motion_trace_record(
		&m.motion_trace,
		{
			kind = "resize-scale",
			window = w.id,
			value = a,
			duration_ms = f64(time.tick_since(started)) / 1e6,
		},
	)
	return err
}

// Hold sizes the app to the target once and scales its current buffer onto
// the animated rect. Settle writes the final position and drops the scale.
Resize_Scale :: enum {
	Normal,
	Hold,
	Settle,
}

// Alpha only: a hidden tab's transform is never touched.
resize_fade_send :: proc(m: ^Manager, w: ^Window, visible: bool) -> string {
	alpha := f32(1)
	if visible && w.opacity > 0 {
		alpha = f32(w.opacity)
	}
	return m.scale_present(
		m.backend_user,
		dock.Present_Request{window = w.id, mask = dock.PRESENT_ALPHA, alpha = visible ? alpha : 0},
	)
}

// Reveals a settled hidden tab once WindowServer shows its new size, it
// becomes the front tab, or a second has passed. Revealing right after the
// size write showed the old, wider tab around the active one until a slow
// app (Chrome, Mail) caught up.
resize_fade_tick :: proc(m: ^Manager) {
	for _, w in m.windows {
		if w == nil || !w.resize_faded || w.resize_scaled {
			continue
		}
		reveal := m.scroll_time - w.resize_settled_at >= 1
		if s := space_by_id(m, w.space); s != nil {
			if n := layout.find(s.view.root, w.id); n == nil || !n.column_tabbed || n.order[0] == w.id {
				reveal = true
			}
		} else {
			reveal = true
		}
		if !reveal && m.window_bounds != nil {
			if b, ok := m.window_bounds(m.backend_user, w.id); ok &&
			   math.abs(b.w - w.frame.w) < 2 &&
			   math.abs(b.h - w.frame.h) < 2 {
				reveal = true
			}
		}
		if reveal {
			resize_fade_restore(m, w)
		}
	}
}

resize_fade_restore :: proc(m: ^Manager, w: ^Window) {
	if !w.resize_faded {
		return
	}
	w.resize_faded = false
	if err := resize_fade_send(m, w, true); err != "" {
		fmt.eprintln("shoji: resize: could not show hidden tab", w.id, err)
	}
}

resize_scale_abort :: proc(m: ^Manager, w: ^Window, err: string) -> Resize_Scale {
	if w.resize_transformed {
		_ = resize_scale_send(m, w, 1, 1, -w.frame.x, -w.frame.y)
	}
	resize_fade_restore(m, w)
	w.resize_scaled, w.resize_transformed = false, false
	m.resize_scale = false
	if !m.resize_scale_noted {
		m.resize_scale_noted = true
		fmt.eprintln("shoji: resize scale:", err)
	}
	return .Normal
}

resize_scale_step :: proc(m: ^Manager, s: ^Space, w: ^Window, visual: Rect) -> Resize_Scale {
	if s.view.layout != .Scroll || !m.resize_scale || m.scale_present == nil || !w.scroll_frame.valid {
		return .Normal
	}
	target := w.scroll_frame.target
	if !s.view.scroll.geometry_active {
		return w.resize_scaled ? .Settle : .Normal
	}
	if !w.resize_scaled {
		if math.abs(target.w - w.frame.w) <= 1.5 && math.abs(target.h - w.frame.h) <= 1.5 {
			return .Normal
		}
		w.resize_scaled, w.resize_transformed = true, false
		w.resize_request = w.frame
	}
	// One configure per target, like niri: the app redraws at the final size
	// while the spring runs, so the stretch shrinks to 1:1 instead of growing.
	// A hidden tab sits behind the active one: no transform, no snapshot,
	// and its one size write waits for Settle. Until then it keeps its old
	// size, so it is made transparent rather than showing around a
	// shrinking active tab.
	if n := layout.find(s.view.root, w.id); w.concealed || (n != nil && n.column_tabbed && n.order[0] != w.id) {
		if !w.concealed && !w.resize_faded {
			err := resize_fade_send(m, w, false)
			if err == "" {
				w.resize_faded = true
			} else {
				fmt.eprintln("shoji: resize: could not hide tab", w.id, err)
			}
			motion_trace_record(&m.motion_trace, {kind = "resize-fade", window = w.id, space = s.id})
		}
		w.frame = visual
		return .Hold
	}
	if math.abs(target.w - w.resize_request.w) > 1.5 || math.abs(target.h - w.resize_request.h) > 1.5 {
		request := Rect{visual.x, visual.y, target.w, target.h}
		err: string
		if m.resize_configure != nil {
			err = m.resize_configure(m.backend_user, w.id, request)
		} else {
			err = perform(m, Action{kind = .Frame, window = w.id, frame = request, direct = true})
		}
		if err != "" {
			return resize_scale_abort(m, w, err)
		}
		w.resize_request = request
	}
	w.resize_basis = w.resize_request
	if m.window_bounds != nil {
		if bounds, ok := m.window_bounds(m.backend_user, w.id); ok && bounds.w >= 1 && bounds.h >= 1 {
			w.resize_basis = bounds
		}
	}
	a, d, tx, ty, ok := resize_scale_matrix(w.resize_basis, visual)
	if !ok {
		return resize_scale_abort(m, w, "resize scale has an empty rect")
	}
	if err := resize_scale_send(m, w, a, d, tx, ty); err != "" {
		return resize_scale_abort(m, w, err)
	}
	w.resize_transformed = true
	w.frame = visual
	return .Hold
}

flush :: proc(m: ^Manager, s: ^Space, live_resize: bool = false) -> string {
	if m.suspended || m.gesture_active || s == nil || s.view.layout == .Float {
		return ""
	}
	// Thumbnail overview owns frames on this display until it closes.
	if m.overview.active && s.display == m.overview.display {
		return ""
	}
	// Parent frames before this flush moves them. dialog_follow adds the delta
	// to unmanaged children, including a held camera batch.
	parent_before := make(map[u32]Rect, context.temp_allocator)
	for _, w in m.windows {
		if w == nil || w.parent == 0 || w.space != s.id {
			continue
		}
		if p := m.windows[w.parent]; p != nil && p.space == s.id {
			parent_before[p.id] = p.frame
		}
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
		m.scroll_animate && m.animation_duration > 0 && !live_resize && m.native_resize_window == 0
	if s.view.layout == .Scroll {
		scroll_constraints(m, &s.view)
		for n := layout.first(s.view.root); n != nil; n = layout.next(n) {n.column_observed = 0}
	}
	if d := display_by_id(m, s.display); d != nil {
		s.view.scroll.output = d.frame
	}
	layout.view_update(&s.view)
	if s.view.layout == .Scroll {
		scroll_rows(m, &s.view)
		scroll_feedback_prepare(m, s)
		layout.scroll_update(&s.view)
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
		if layout.find(s.view.root, target) == nil {
			target = s.view.scroll.focused
		}
		if !s.view.scroll.dragging && (s.view.scroll.reveal || s.view.scroll.focused != target) {
			layout.scroll_reveal(&s.view, target)
			s.view.scroll.focused = target
			s.view.scroll.reveal = false
		}
		if m.scroll_animate {
			scroll_motion_prepare(
				&s.view,
				m.scroll_time,
				m.animation_duration > 0 && !live_resize && m.native_resize_window == 0,
			)
			scroll_geometry_prepare(m, s)
		}
	}
	deferred := make([dynamic]Deferred_Frame, 0, 16, context.temp_allocator)
	camera := scroll_camera_batching(m, s, live_resize)
	camera_moves := make([dynamic]Deferred_Frame, 0, LAYOUT_BATCH_LIMIT, context.temp_allocator)
	for n := layout.first(s.view.root); n != nil; n = layout.next(n) {
		for i in 0 ..< n.count {
			w := m.windows[n.windows[i]]
			if w == nil || !managed(w) {
				continue
			}
			if w.windowed_frame != nil {
				continue
			}
			r := layout.frame_for(n)
			if s.view.layout == .Scroll {
				if m.scroll_animate {
					r = w.scroll_frame.current
					r.x -= s.view.scroll.motion.position
					r.w, r.h = max(1, r.w), max(1, r.h)
					r =
						n.zoom != nil \
							? size_feedback_frame(w, s.view.scroll.viewport) \
							: layout.scroll_park_frame(&s.view, r)
				} else {
					r = layout.scroll_park_frame(
						&s.view,
						size_feedback_frame(
							w,
							layout.scroll_window_frame(&s.view, n, w.id, false),
						),
					)
				}
			}
			if s.view.layout != .Scroll && n == s.view.root && n.count == 1 && n.zoom == nil {
				if relative, chosen := w.solo_tile_frame.?; chosen {
					r = {
						r.x + relative.x * r.w,
						r.y + relative.y * r.h,
						relative.w * r.w,
						relative.h * r.h,
					}
				}
			}
			scale := resize_scale_step(m, s, w, r)
			if scale == .Hold {
				w.ax_stale = false
				continue
			}
			if scale != .Settle &&
			   math.abs(w.frame.x - r.x) < 1.5 &&
			   math.abs(w.frame.y - r.y) < 1.5 &&
			   math.abs(w.frame.w - r.w) < 1.5 &&
			   math.abs(w.frame.h - r.h) < 1.5 &&
			   (camera || !w.ax_stale) {
				continue
			}
			if w.id == m.native_resize_window {
				w.frame = r; continue
			}
			if s.view.layout != .Scroll {
				append(&deferred, Deferred_Frame{w, r})
				continue
			}
			if camera && math.abs(w.frame.w - r.w) < 1.5 && math.abs(w.frame.h - r.h) < 1.5 {
				append(&camera_moves, Deferred_Frame{w, r})
				continue
			}
			// A settled hidden tab is transparent until its frame lands, so
			// its write goes to the async writer instead of
			// blocking this flush on each app's layout (25-50 ms apiece).
			frame_err: string
			if scale == .Settle && w.resize_faded && m.resize_configure_hidden != nil {
				frame_err = m.resize_configure_hidden(m.backend_user, w.id, r)
			} else {
				frame_err = perform(
					m,
					Action {
						kind = .Frame,
						window = w.id,
						frame = r,
						live_resize = live_resize,
						direct = s.view.layout == .Scroll && m.scroll_animate,
					},
				)
			}
			if err := frame_err; err != "" {
				// A hidden tab must not stay transparent on a failed write.
				resize_fade_restore(m, w)
				return err
			}
			w.frame = r
			w.ax_stale = false
			if scale == .Settle {
				if w.resize_transformed {
					_ = resize_scale_send(m, w, 1, 1, -r.x, -r.y)
				}
				// The app applies the size write on its own time; the tab
				// stays hidden until resize_fade_tick sees the new size.
				w.resize_scaled, w.resize_transformed = false, false
				w.resize_settled_at = m.scroll_time
			}
		}
		if m.resize_scale && !s.view.scroll.geometry_active {
			pending := false
			for _, scaled in m.windows {
				if scaled != nil && scaled.resize_scaled {
					pending = true
					break
				}
			}
			if !pending {
				m.resize_scale = false
			}
		}
		if s.view.layout == .Scroll &&
		   n.column_tabbed &&
		   n.count > 0 &&
		   n.column_raised != n.order[0] {
			if err := perform(m, {kind = .Order, window = n.order[0], value = 1}); err != "" {
				return err
			}
			n.column_raised = n.order[0]
		}
	}
	if err := scroll_camera_apply(m, camera_moves[:], live_resize); err != "" {
		return err
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
			Action {
				kind = .Frame,
				window = d.window.id,
				frame = d.frame,
				live_resize = live_resize,
			},
		); err != "" {
			return err
		}
		d.window.frame = d.frame
		d.window.ax_stale = false
	}
	tab_conceal_sync(m, s)
	dialog_follow(m, s, parent_before)
	viewport_clip_sync(m, s)
	for _, w in m.windows {
		if w.space == s.id {
			w.size_feedback_reflow = false
		}
	}
	return ""
}

// The most recent inactive tab (order[1]) stays drawn as a standby directly
// behind the active one. Closing the active tab or opening a new, not yet
// drawn one then exposes that tab instead of the desktop until the next flush.
TAB_STANDBY :: 1

tab_concealable :: proc(s: ^Space, id: u32) -> bool {
	if s.view.layout != .Scroll {
		return false
	}
	n := layout.find(s.view.root, id)
	if n == nil || !n.column_tabbed {
		return false
	}
	for i in TAB_STANDBY + 1 ..< n.count {
		if n.order[i] == id {
			return true
		}
	}
	return false
}

// B02: ordering alone leaves an inactive tab's edges visible and its frame
// clickable. Concealment hides it from drawing and hit-testing; the payload
// reveals it on its own if this daemon dies.
// Reveals run before conceals: a tab switch shows the new tab (already raised
// above) before hiding the old one, so no frame shows neither.
// A Dock restart rewrites the conceal journal with a new boot. Windows that
// the previous payload refused can be tried again; a rewrite that keeps the
// boot (the same payload saving the table) does not retry.
conceal_payload_changed :: proc(m: ^Manager) {
	if m.conceal_journal == "" {
		return
	}
	mtime, boot, ok := dock.conceal_journal_stamp(m.conceal_journal)
	if !ok || mtime == m.conceal_stamp {
		return
	}
	m.conceal_stamp = mtime
	if boot == 0 || boot == m.conceal_boot {
		return
	}
	m.conceal_boot = boot
	for _, w in m.windows {
		if w != nil {
			w.conceal_refused = false
		}
	}
}

tab_conceal_sync :: proc(m: ^Manager, s: ^Space) {
	conceal_payload_changed(m)
	for pass in ([2]bool{false, true}) {tab_conceal_pass(m, s, pass)}
}

// An unmanaged child (a sheet, modal, or popover with an SLS parent) moves by
// the same delta as its owner. Movement-group symbols take an unproven
// argument, so this is a frame translation. A held camera stores the child
// in that frame's batch; a full batch falls through to a direct move.
dialog_follow :: proc(m: ^Manager, s: ^Space, before: map[u32]Rect) {
	for _, w in m.windows {
		if w == nil || w.parent == 0 || w.space != s.id || managed(w) {
			continue
		}
		p := m.windows[w.parent]
		if p == nil || p.space != s.id {
			continue
		}
		old, ok := before[p.id]
		if !ok {
			continue
		}
		dx := p.frame.x - old.x
		dy := p.frame.y - old.y
		if math.abs(dx) < 0.5 && math.abs(dy) < 0.5 {
			continue
		}
		frame := w.frame
		frame.x += dx
		frame.y += dy
		if m.camera_hold && m.layout_batch != nil {
			held := [1]Deferred_Frame{{w, frame}}
			if camera_hold_store(m, held[:]) {
				w.frame = frame
				w.server_placed = true
				w.ax_stale = true
				continue
			}
		}
		if err := perform(m, {kind = .Frame, window = w.id, frame = frame, direct = true});
		   err != "" {
			fmt.eprintln("shoji: dialog follow:", err)
			continue
		}
		w.frame = frame
	}
}

// Clip the parked frame to this space's viewport. Parking keeps a sliver on
// the current display; the clip hides the part that would spill onto the next
// one, and drops hit-testing there too. A frame that fits again restores the
// full window-local rect. An unchanged rect is not sent.
viewport_clip_sync :: proc(m: ^Manager, s: ^Space) {
	if m.present == nil {
		return
	}
	if !m.viewport_clip {
		viewport_clip_repair(m, s)
		return
	}
	if s.view.layout != .Scroll {
		return
	}
	viewport := s.view.scroll.viewport
	for _, win in m.windows {
		if win == nil || win.space != s.id || !managed(win) || win.concealed {
			continue
		}
		x, y, w, h, partial := layout.viewport_clip(win.frame, viewport)
		kind: u8 = 1
		if partial && (w <= 0 || h <= 0) {
			kind = 0
			x, y, w, h = 0, 0, 0, 0
		} else if !partial {
			if !win.viewport_clipped {
				continue
			}
			x, y = 0, 0
			w = i32(math.round(win.frame.w))
			h = i32(math.round(win.frame.h))
			if w <= 0 || h <= 0 {
				continue
			}
		}
		if win.viewport_clipped == partial &&
		   win.clip_x == x &&
		   win.clip_y == y &&
		   win.clip_w == w &&
		   win.clip_h == h {
			continue
		}
		req := dock.Present_Request {
			window     = win.id,
			mask       = dock.PRESENT_CLIP | dock.PRESENT_EVENT,
			event_kind = kind,
			x          = x,
			y          = y,
			w          = w,
			h          = h,
		}
		if err := m.present(m.backend_user, req); err != "" {
			if !m.clip_noted {
				m.clip_noted = true
				fmt.eprintln("shoji: viewport clip:", err)
			}
			continue
		}
		win.viewport_clipped = partial
		win.clip_x, win.clip_y, win.clip_w, win.clip_h = x, y, w, h
	}
}

// Sends one unbounded clip per window to undo a cut left by an earlier daemon.
// A failure stops this flush; the next flush retries.
viewport_clip_repair :: proc(m: ^Manager, s: ^Space) {
	for _, win in m.windows {
		if win == nil || win.space != s.id || !managed(win) || win.clip_repaired {
			continue
		}
		// GlobalClipShape is not window-local. A rect of the window's own size
		// at the origin cuts the bottom (and the right) by the window origin.
		clip := dock.Present_Request {
			window     = win.id,
			mask       = dock.PRESENT_CLIP,
			event_kind = 1,
			x          = -32768,
			y          = -32768,
			w          = 65536,
			h          = 65536,
		}
		if err := m.present(m.backend_user, clip); err != "" {
			if !m.clip_noted {
				m.clip_noted = true
				fmt.eprintln("shoji: viewport clip repair:", err)
			}
			return
		}
		ew := i32(math.round(win.frame.w))
		eh := i32(math.round(win.frame.h))
		if ew > 0 && eh > 0 {
			event := dock.Present_Request {
				window     = win.id,
				mask       = dock.PRESENT_EVENT,
				event_kind = 1,
				x          = 0,
				y          = 0,
				w          = ew,
				h          = eh,
			}
			if err := m.present(m.backend_user, event); err != "" {
				if !m.clip_noted {
					m.clip_noted = true
					fmt.eprintln("shoji: viewport clip repair:", err)
				}
				return
			}
		}
		win.clip_repaired = true
		win.viewport_clipped = false
	}
}

tab_conceal_pass :: proc(m: ^Manager, s: ^Space, conceal: bool) {
	for _, w in m.windows {
		if w == nil || w.space != s.id {
			continue
		}
		want := m.tab_conceal && managed(w) && w.windowed_frame == nil && tab_concealable(s, w.id)
		if !want {
			w.conceal_refused = false
		}
		if want != conceal {
			continue
		}
		// Before the early-out: a reveal that already matched still has to
		// retry a shadow the payload did not put back.
		if !want && w.shadow_held {
			tab_shadow_restore(m, w)
		}
		if want == w.concealed || (want && w.conceal_refused) {
			if want && w.shadow && !w.shadow_held {
				tab_shadow_hold(m, w)
			}
			continue
		}
		if err := perform(m, {kind = .Conceal, window = w.id, flag = want}); err != "" {
			// A refused conceal keeps today's ordered-behind tab. A failed
			// reveal stays recorded and is retried by the next flush.
			if want {
				w.conceal_refused = true
			}
			fmt.eprintln("shoji: tab concealment:", err)
			continue
		}
		w.concealed = want
		if want && w.shadow {
			tab_shadow_hold(m, w)
		}
		motion_trace_record(
			&m.motion_trace,
			{kind = want ? "tab-conceal" : "tab-reveal", window = w.id, space = s.id},
		)
	}
}

tab_shadow_hold :: proc(m: ^Manager, w: ^Window) {
	if !w.shadow || w.shadow_held {
		return
	}
	if err := perform(m, {kind = .Shadow, window = w.id, flag = false}); err != "" {
		fmt.eprintln("shoji: tab shadow:", err)
		return
	}
	w.shadow_held = true
}

tab_shadow_restore :: proc(m: ^Manager, w: ^Window) {
	if !w.shadow_held {
		return
	}
	if err := perform(m, {kind = .Shadow, window = w.id, flag = true}); err != "" {
		fmt.eprintln("shoji: tab shadow:", err)
		return
	}
	w.shadow = true
	w.shadow_held = false
}

// Reveals every concealed window, at shutdown or when concealment is disabled.
tab_conceal_release :: proc(m: ^Manager) {
	for _, w in m.windows {
		if w == nil || !w.concealed {
			continue
		}
		if err := perform(m, {kind = .Conceal, window = w.id, flag = false}); err != "" {
			fmt.eprintln("shoji: tab reveal:", err)
			continue
		}
		w.concealed = false
		tab_shadow_restore(m, w)
	}
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

select_window :: proc(m: ^Manager, text: string, reference: u32 = 0) -> ^Window {
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
		best: ^layout.Node
		best_area: f64
		for candidate := layout.first(active.view.root);
		    candidate != nil;
		    candidate = layout.next(candidate) {
			if candidate.count == 0 {
				continue
			}
			area := math.floor(candidate.frame.w * candidate.frame.h)
			if best == nil || (text == "largest" ? area > best_area : area <= best_area) {
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
	n := layout.find(s.view.root, w.id)
	if s.view.layout == .Scroll &&
	   (text == "north" || text == "south" || text == "east" || text == "west") {
		return scroll_direction(m, s, w, text)
	}
	target: ^layout.Node
	switch text {
	case "first":
		target = layout.first(s.view.root)
	case "last":
		target = layout.last(s.view.root)
	case "next":
		target = layout.next(n)
	case "prev":
		target = layout.previous(n)
	case "north":
		target = layout.neighbor(s.view.root, n, .North)
	case "east":
		target = layout.neighbor(s.view.root, n, .East)
	case "south":
		target = layout.neighbor(s.view.root, n, .South)
	case "west":
		target = layout.neighbor(s.view.root, n, .West)
	case "sibling", "first_nephew", "second_nephew", "uncle", "first_cousin", "second_cousin":
		branch := n
		if text == "uncle" || text == "first_cousin" || text == "second_cousin" {
			if branch == nil {
				return nil
			}; branch = branch.parent
		}
		if branch == nil || branch.parent == nil {
			return nil
		}
		target = branch.parent.left == branch ? branch.parent.right : branch.parent.left
		if text == "first_nephew" || text == "first_cousin" {
			if target == nil {
				return nil
			}; target = target.left
		} else if text == "second_nephew" || text == "second_cousin" {
			if target == nil {
				return nil
			}; target = target.right
		}
		if target != nil && !layout.leaf(target) {
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

set_layout :: proc(m: ^Manager, s: ^Space, mode: layout.Layout) {
	if s.view.layout == mode {
		return
	}
	zooms := layout.capture_zooms(&s.view)
	defer layout.restore_zooms(&s.view, zooms[:])
	s.view.layout = mode
	s.view.scroll = layout.Scroll_State {
		reveal = true,
	}
	for _, w in m.windows {
		if w.space == s.id {
			w.scroll_frame = {}
		}
	}
	layout.node_destroy(s.view.root)
	s.view.root = new(layout.Node)
	// Stable window-id order makes a layout rebuild deterministic.
	ids: [dynamic]u32
	defer delete(ids)
	for id, w in m.windows {
		// Choosing a tiled layout explicitly adopts existing eligible windows;
		// a newcomer still preparing must continue through admission.
		if w.space == s.id && mode != .Float && w.opening.phase == .Excluded && managed(w) {
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
		insertion := mode == .Scroll && i > 0 ? ids[i - 1] : u32(0)
		layout.add(&s.view, id, insertion)
		if mode == .Scroll {
			scroll_rule_realize(m, m.windows[id])
		}
	}
	layout.view_update(&s.view)
}

errorf :: proc(format: string, args: ..any) -> string {
	return fmt.tprintf(format, ..args)
}
