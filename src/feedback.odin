package shoji

import "core:fmt"
import "core:math"

foreign import feedback_sls "system:SkyLight.framework"
foreign import feedback_cg "system:CoreGraphics.framework"

// Interaction feedback
// ------------------------------------------------------------------------

Feedback_Window :: struct {
	plan: Feedback_Plan,
	surface: Owned_Surface,
}
Feedback_Backend :: struct {
	create: proc(
		state: ^State,
		plan: Feedback_Plan,
	) -> (
		Owned_Surface,
		string,
	),
	destroy: proc(state: ^State, surface: Owned_Surface),
	update: proc(
		state: ^State,
		surface: Owned_Surface,
		frame: Rect,
	) -> string,
	reorder: proc(
		state: ^State,
		owner: u32,
		surfaces: []Owned_Surface,
	) -> string,
}

Focus_Ring :: struct {
	window, owner: u32,
	generation: u64,
	config: Focus_Ring_Config,
	failed: bool,
	order_dirty: bool,
	bars: [8]Feedback_Window,
}

Tab_Indicator_State :: struct {
	bars: [MAX_STACK]Feedback_Window,
	tabs: [MAX_STACK]Tab_Indicator,
	count: int,
	order_dirty: bool,
}

tab_indicator_stop :: proc(state: ^State) {
	backend := feedback_backend(state)
	for bar in state.tab_indicator.bars {
		if bar.surface.id != 0 { backend.destroy(state, bar.surface) }
	}
	state.tab_indicator = {}
}

tab_indicator_tick :: proc(state: ^State, frame: Rect, relative: u32) {
	tabs, count := tab_indicators(&state.manager, frame)
	backend := feedback_backend(state)
	indicator := &state.tab_indicator
	for i in 0 ..< MAX_STACK {
		bar := &indicator.bars[i]
		if i >= count {
			if bar.surface.id != 0 { backend.destroy(state, bar.surface) }
			bar^ = {}; indicator.tabs[i] = {}; continue
		}
		color := tabs[i].active \
			? (state.manager.tab_indicator_active_color.? or_else state.manager.focus_ring.color) \
			: (state.manager.tab_indicator_inactive_color.? or_else u32(0xff505050))
		plan := Feedback_Plan{window = relative, frame = tabs[i].frame, color = color, solid = true}
		if plan != bar.plan {
			indicator.order_dirty = true
			if bar.surface.id != 0 && bar.plan.window == plan.window && bar.plan.color == plan.color && backend.update != nil {
				if err := backend.update(state, bar.surface, plan.frame); err != "" {
					backend.destroy(state, bar.surface); bar.surface = {}
					fmt.eprintln("shoji: tab indicator:", err)
				}
			} else {
				if bar.surface.id != 0 { backend.destroy(state, bar.surface) }
				err: string
				bar.surface, err = backend.create(state, plan)
				if err != "" { fmt.eprintln("shoji: tab indicator:", err) }
			}
			bar.plan = plan
		}
		indicator.tabs[i] = tabs[i]
	}
	indicator.count = count
	if count > 0 && indicator.order_dirty && backend.reorder != nil {
		indicator.order_dirty = false
		surfaces: [MAX_STACK]Owned_Surface; surface_count := 0
		for i in 0 ..< count {
			if indicator.bars[i].surface.id != 0 {
				surfaces[surface_count] = indicator.bars[i].surface
				surface_count += 1
			}
		}
		if err := backend.reorder(state, relative, surfaces[:surface_count]); err != "" {
			fmt.eprintln("shoji: tab indicator:", err)
		}
	}
}

focus_ring_stop :: proc(state: ^State) {
	backend := feedback_backend(state)
	for bar in state.focus_ring.bars {
		if bar.surface.id != 0 {
			backend.destroy(state, bar.surface)
		}
	}
	state.focus_ring = {}
}

focus_ring_prune_unordered :: proc(
	state: ^State,
	probe: proc(state: ^State, window: u32) -> Maybe(bool) = nil,
) {
	ring := &state.focus_ring
	owner, generation := ring.owner, ring.generation
	if owner == 0 {
		for i in 0 ..< state.tab_indicator.count {
			tab := state.tab_indicator.tabs[i]
			if tab.active { owner, generation = tab.window, tab.generation; break }
		}
	}
	if owner == 0 {
		return
	}
	w := state.manager.windows[owner]
	if w == nil || w.generation != generation {
		focus_ring_stop(state); tab_indicator_stop(state); return
	}
	probe := probe
	if probe == nil {
		if state.connection == 0 {
			return
		}
		probe = window_ordered_in
	}
	// A retained NSWindow can close by ordering out without an AX destruction
	// notification. Trust a known native result; failed reads preserve state.
	if ordered, known := probe(state, w.id).?; known && !ordered {
		w.ordered_in = false
		focus_ring_stop(state); tab_indicator_stop(state)
	}
}

focus_ring_note_action :: proc(state: ^State, action: Action) {
	if action.window != state.manager.focused {
		return
	}
	#partial switch action.kind {
	case .Order, .Layer, .Focus, .Focus_Without_Raise:
		state.focus_ring.order_dirty = true
		state.tab_indicator.order_dirty = true
	}
}

focus_ring_fail :: proc(state: ^State, err: string) {
	backend := feedback_backend(state)
	for &bar in state.focus_ring.bars {
		if bar.surface.id != 0 {
			backend.destroy(state, bar.surface); bar.surface = {}
		}
	}
	state.focus_ring.failed = true
	fmt.eprintln("shoji: focus ring:", err)
}

focus_ring_tick :: proc(state: ^State) {
	w := state.manager.windows[state.manager.focused]
	if state.read_only ||
	   state.focus_ring_held ||
	   w == nil ||
	   (state.connection == 0 && state.feedback_backend.create == nil) {
		focus_ring_stop(state); tab_indicator_stop(state); return
	}
	if !managed(w) &&
	   (state.focus_geometry_dirty || state.mouse.buttons != 0) &&
	   w.id not_in state.animations {
		state.focus_geometry_dirty = false
		probe := state.focus_frame_probe
		if probe == nil && state.connection != 0 {
			probe = mouse_native_resize_frame
		}
		if probe != nil {
			if observed, valid := probe(state, w.id);
			   valid && valid_frame(observed) {
				w.frame = observed
			}
		}
	}
	frame, relative := w.frame, w.id
	if s := space_by_id(&state.manager, w.space);
	   s != nil && s.view.layout == .Scroll && managed(w) && w.id not_in state.animations {
		moving := s.view.scroll.dragging || s.view.scroll.motion.active || s.view.scroll.geometry_active
		if moving {
			state.focus_scroll_pending = w.id
			state.focus_scroll_deadline = CACurrentMediaTime() + 1
		}
		if moving || state.focus_scroll_pending == w.id {
			probe := state.focus_frame_probe
			if probe == nil && state.connection != 0 { probe = mouse_native_resize_frame }
			if probe != nil {
				observed, valid := probe(state, w.id)
				if !valid || !valid_frame(observed) {
					focus_ring_stop(state); tab_indicator_stop(state); return
				}
				frame = observed
				if !moving && (CACurrentMediaTime() >= state.focus_scroll_deadline ||
				   math.abs(observed.x-w.frame.x) < 1.5 &&
				   math.abs(observed.y-w.frame.y) < 1.5 &&
				   math.abs(observed.w-w.frame.w) < 1.5 &&
				   math.abs(observed.h-w.frame.h) < 1.5) {
					state.focus_scroll_pending = 0
				}
			}
		}
	} else {
		state.focus_scroll_pending = 0
	}
	if job, exists := state.animations[w.id];
	   exists && animation_matches(state, w.id, job) {
		switch presentation in job.presentation {
		case Live_Resize:
			frame = presentation.current
		case Animation_Proxy:
			frame = interpolate_frame(
				job.from,
				job.target,
				job.progress,
				.Linear,
			)
			relative = presentation.id
		}
	}
	tab_indicator_tick(state, frame, relative)
	plans, valid := focus_ring_plans(&state.manager, frame)
	if !valid {
		focus_ring_stop(state); return
	}
	if state.focus_ring.window != relative ||
	   state.focus_ring.owner != w.id ||
	   state.focus_ring.generation != w.generation ||
	   state.focus_ring.config != state.manager.focus_ring {
		previous := state.manager.windows[state.focus_ring.owner]
		space := space_by_id(&state.manager, w.space)
		reuse := previous != nil && previous.generation == state.focus_ring.generation &&
			previous.space == w.space && space != nil && space.visible && space.view.layout == .Scroll &&
			state.focus_ring.config == state.manager.focus_ring && !state.focus_ring.failed &&
			state.focus_ring.window == state.focus_ring.owner && relative == w.id
		if !reuse { focus_ring_stop(state) }
		state.focus_ring.window, state.focus_ring.generation =
			relative, w.generation
		state.focus_ring.owner = w.id
		state.focus_ring.config = state.manager.focus_ring
		state.focus_ring.order_dirty = true
	}
	if state.focus_ring.failed {
		return
	}
	backend := feedback_backend(state)
	for plan, i in plans {
		plan := plan; plan.window = relative
		bar := &state.focus_ring.bars[i]
		if plan.frame.w <= 0 || plan.frame.h <= 0 {
			if bar.surface.id != 0 {
				backend.destroy(state, bar.surface)
			}
			bar^ = {}; continue
		}
		if bar.plan == plan {
			continue
		}
		err: string
		corner_changed :=
			plan.corner != .None &&
			(bar.plan.frame.w != plan.frame.w ||
					bar.plan.frame.h != plan.frame.h ||
					bar.plan.stroke_width != plan.stroke_width)
		if bar.surface.id != 0 && backend.update != nil && !corner_changed {
			err = backend.update(state, bar.surface, plan.frame)
		} else {
			if bar.surface.id != 0 {
				backend.destroy(state, bar.surface)
			}
			bar.surface, err = backend.create(state, plan)
		}
		if err != "" {
			focus_ring_fail(state, err); return
		}
		// An unchanged plan performs no native work on idle loop iterations.
		bar.plan = plan
	}
	if state.focus_ring.order_dirty && backend.reorder != nil {
		// Native opening/focus can raise the owner or restore its layer after
		// these surfaces were created, even when geometry has not changed.
		state.focus_ring.order_dirty = false
		surfaces: [8]Owned_Surface; count := 0
		for bar in state.focus_ring.bars {
			if bar.surface.id != 0 {
				surfaces[count] = bar.surface; count += 1
			}
		}
		if err := backend.reorder(state, relative, surfaces[:count]);
		   err != "" {
			focus_ring_fail(state, err)
		}
	}
}

focus_ring_sublevel :: proc(owner: i32) -> i32 {
	return owner < max(i32) ? owner + 1 : owner
}

native_focus_ring_reorder :: proc(
	state: ^State,
	owner: u32,
	surfaces: []Owned_Surface,
) -> string {
	_, observed_level := window_query_appearance(state.connection, owner)
	level, level_known := observed_level.?
	owner_sublevel, sublevel_known := window_sublevel(
		state.connection,
		owner,
	).?
	if !level_known || !sublevel_known {
		return "could not read focus owner layer"
	}
	// Keep the ring on the next sublevel of its owner's window level.
	sublevel := focus_ring_sublevel(owner_sublevel)
	for surface in surfaces {
		if SLSSetWindowLevel(state.connection, surface.id, level) != 0 ||
		   SLSSetWindowSubLevel(state.connection, surface.id, sublevel) != 0 ||
		   SLSOrderWindow(state.connection, surface.id, 1, owner) != 0 {
			return "could not order focus ring above its owner"
		}
	}
	return ""
}

@(default_calling_convention = "c")
foreign feedback_sls {
	SLSOrderWindow :: proc(cid: i32, window: u32, order: i32, relative: u32) -> i32 ---
	SLSSetWindowTags :: proc(cid: i32, window: u32, tags: ^u64, count: uint) -> i32 ---
}
@(default_calling_convention = "c")
foreign feedback_cg {
	CGContextSaveGState :: proc(ctx: Ref) ---
	CGContextRestoreGState :: proc(ctx: Ref) ---
	CGContextGetCTM :: proc(ctx: Ref) -> Animation_Transform ---
	CGContextTranslateCTM :: proc(ctx: Ref, x, y: f64) ---
	CGContextScaleCTM :: proc(ctx: Ref, x, y: f64) ---
	CGContextBeginPath :: proc(ctx: Ref) ---
	CGContextAddEllipseInRect :: proc(ctx: Ref, rect: Rect) ---
	CGContextEOFillPath :: proc(ctx: Ref) ---
	CGContextSetRGBFillColor :: proc(ctx: Ref, r, g, b, a: f64) ---
	CGContextSetRGBStrokeColor :: proc(ctx: Ref, r, g, b, a: f64) ---
	CGContextSetLineWidth :: proc(ctx: Ref, width: f64) ---
	CGContextFillRect :: proc(ctx: Ref, rect: Rect) ---
	CGContextStrokeRect :: proc(ctx: Ref, rect: Rect) ---
}

native_feedback_create :: proc(
	state: ^State,
	plan: Feedback_Plan,
) -> (
	surface: Owned_Surface,
	err: string,
) {
	if plan.frame.w <= 0 || plan.frame.h <= 0 {
		return {}, "feedback area is too small"
	}
	surface, err = surface_create(
		state,
		plan.frame,
		plan.window,
		(1 << 1) | (1 << 9),
		13,
		1,
	)
	if err != "" {
		return {}, err
	}
	success := false
	defer {
		if !success {
			surface_destroy(state, surface)
		}
	}
	shadow: u64 = 1 << 3
	SLSSetWindowTags(state.connection, surface.id, &shadow, 64)
	native_feedback_paint(surface.ctx, plan)
	if error := surface_update(state, surface, surface.frame); error != "" {
		return {}, error
	}
	if SLSOrderWindow(state.connection, surface.id, 1, plan.window) != 0 {
		return {}, "could not order feedback window"
	}
	success = true
	return surface, ""
}

native_feedback_paint :: proc(ctx: Ref, plan: Feedback_Plan) {
	CGContextSaveGState(ctx)
	defer CGContextRestoreGState(ctx)
	// Ring plans use screen coordinates (Y down). Bitmap contexts and window
	// contexts can have different base transforms; normalize before drawing.
	if CGContextGetCTM(ctx).d > 0 {
		CGContextTranslateCTM(ctx, 0, plan.frame.h)
		CGContextScaleCTM(ctx, 1, -1)
	}
	r, g, b, a :=
		f64((plan.color >> 16) & 255) /
		255,
		f64((plan.color >> 8) & 255) /
		255,
		f64(plan.color & 255) /
		255,
		f64(plan.color >> 24) /
		255
	frame := Rect{0, 0, plan.frame.w, plan.frame.h}
	CGContextClearRect(ctx, frame)
	CGContextSetRGBFillColor(ctx, r, g, b, plan.solid ? a : a * 0.25)
	if plan.corner != .None {
		// Clip a quarter annulus to this small corner surface. The center stays
		// transparent; no full-window bitmap or stretched curved border is used.
		radius := frame.w
		x :=
			plan.corner == .Top_Left || plan.corner == .Bottom_Left \
				? radius \
				: f64(0)
		y :=
			plan.corner == .Top_Left || plan.corner == .Top_Right \
				? radius \
				: f64(0)
		CGContextBeginPath(ctx)
		CGContextAddEllipseInRect(
			ctx,
			{x - radius, y - radius, radius * 2, radius * 2},
		)
		inner := max(0, radius - plan.stroke_width)
		if inner > 0 {
			CGContextAddEllipseInRect(
				ctx,
				{x - inner, y - inner, inner * 2, inner * 2},
			)
		}
		CGContextEOFillPath(ctx)
	} else {
		CGContextFillRect(ctx, frame)
	}
	if !plan.solid && frame.w > 2 && frame.h > 2 {
		CGContextSetRGBStrokeColor(ctx, r, g, b, a)
		CGContextSetLineWidth(ctx, 2)
		CGContextStrokeRect(ctx, {1, 1, frame.w - 2, frame.h - 2})
	}
	CGContextFlush(ctx)
}

feedback_backend :: proc(state: ^State) -> Feedback_Backend {
	if state.feedback_backend.create != nil {
		return state.feedback_backend
	}
	return {
		native_feedback_create,
		surface_destroy,
		surface_update,
		native_focus_ring_reorder,
	}
}

feedback_sync :: proc(state: ^State, plans: map[u32]Feedback_Plan) {
	backend := feedback_backend(state)
	removed := make([dynamic]u32, context.temp_allocator)
	for key, window in state.feedback {
		window := window
		plan, exists := plans[key]
		if exists &&
		   plan != window.plan &&
		   plan.solid &&
		   window.plan.solid &&
		   plan.window == window.plan.window &&
		   plan.color == window.plan.color &&
		   plan.corner == window.plan.corner &&
		   plan.stroke_width == window.plan.stroke_width {
			if window.surface.id == 0 || backend.update != nil {
				if window.surface.id != 0 {
					if err := backend.update(
						state,
						window.surface,
						plan.frame,
					); err != "" {
						backend.destroy(state, window.surface)
						window.surface = {}
						fmt.eprintln("shoji: feedback:", err)
					}
				}
				window.plan = plan; state.feedback[key] = window
				continue
			}
		}
		if !exists || plan != window.plan {
			backend.destroy(state, window.surface); append(&removed, key)
		}
	}
	for key in removed { delete_key(&state.feedback, key) }
	for key, plan in plans {
		if _, exists := state.feedback[key]; exists {
			continue
		}
		surface, err := backend.create(state, plan)
		if err != "" {
			fmt.eprintln("shoji: feedback:", err)
		}
		if state.feedback == nil {
			state.feedback = make(map[u32]Feedback_Window)
		}
		// Cache failed plans too, avoiding a log/allocation storm every frame.
		state.feedback[key] = Feedback_Window{plan, surface}
	}
}

feedback_tick :: proc(state: ^State) {
	plans := make(map[u32]Feedback_Plan, context.temp_allocator)
	if !state.read_only {
		for s in state.manager.spaces {
			if plan, valid := insertion_feedback(&state.manager, s); valid {
				plans[plan.window] = plan
			}
		}
		mouse := &state.mouse
		if mouse_drag_moved(mouse) &&
		   !mouse_drag_finished(mouse) &&
		   !mouse.failed {
			if plan, valid := drag_feedback(
				&state.manager,
				mouse.drag,
				mouse.target,
				mouse.point,
			); valid {
				plans[0] = plan
			}
		}
	}
	feedback_sync(state, plans)
}

feedback_stop :: proc(state: ^State) {
	focus_ring_stop(state)
	tab_indicator_stop(state)
	backend := feedback_backend(state)
	for _, window in state.feedback { backend.destroy(state, window.surface) }
	delete(state.feedback); state.feedback = nil
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

// The indicator uses the stable column order, not the focus-history order.
// Place it beside the window when possible, falling inside at the viewport edge.
Tab_Indicator :: struct {
	window: u32,
	generation: u64,
	frame: Rect,
	active: bool,
}

tab_indicators :: proc(m: ^Manager, frame: Rect) -> ([MAX_STACK]Tab_Indicator, int) {
	result: [MAX_STACK]Tab_Indicator
	w := m.windows[m.focused]
	if w == nil || w.floating || w.hidden || w.minimized || !(w.ordered_in.? or_else true) || frame.w < 8 || frame.h < 16 {
		return result, 0
	}
	s := space_by_id(m, w.space)
	if s == nil || !s.visible || s.view.layout != .Scroll {
		return result, 0
	}
	n := find(s.view.root, w.id)
	if n == nil || !n.column_tabbed || n.count < 2 || n.order[0] != w.id {
		return result, 0
	}
	slot := (s.view.tab_indicator_top ? frame.w : frame.h) * 0.5 / f64(n.count)
	gap := min(m.tab_indicator_gap, slot * 0.8)
	width := s.view.tab_indicator_width
	x := frame.x - width - 5
	if !s.view.tab_indicator_top && x < s.view.scroll.viewport.x {
		x = frame.x + max(m.focus_ring.width, 0) + 6
	}
	for i in 0 ..< n.count {
		tab := m.windows[n.windows[i]]
		if tab == nil { return {}, 0 }
		start := f64(i) * slot + (i > 0 ? gap / 2 : 0)
		end := f64(i + 1) * slot - (i + 1 < n.count ? gap / 2 : 0)
		r := Rect{x, frame.y + frame.h * 0.25 + start, width, end - start}
		if s.view.tab_indicator_top {
			r = {frame.x + frame.w * 0.25 + start, frame.y - width - 5, end - start, width}
		}
		result[i] = {tab.id, tab.generation, r, tab.id == w.id}
	}
	return result, n.count
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
