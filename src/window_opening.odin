package shoji

import "core:math"
import dock "dock"
import "core:fmt"
import "core:time"

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


// Opening readiness
// ------------------------------------------------------------------------

Opening_Guard :: struct {
	proxy: Animation_Proxy,
	hidden: bool,
	requested, sample: Rect,
	original: Rect,
	samples: int,
	checked: time.Time,
}

// Diagnostic builds arm on discovery so a human-triggered opening cannot miss
// the bounded capture interval. Only geometry and native operation status enter it.
opening_trace_begin :: proc(state: ^State) {
	when #config(SHOJI_OPENING_TRACE, false) {
		if !state.manager.motion_trace.active {
			motion_debug(&state.manager, {"motion", "start"})
		}
	}
}

opening_trace_native :: proc(
	state: ^State,
	kind: string,
	id: u32,
	requested: Rect = {},
) {
	if !state.manager.motion_trace.active {
		return
	}
	actual: Rect
	code := SLSGetWindowBounds(state.connection, id, &actual)
	motion_trace_record(
		&state.manager.motion_trace,
		{
			kind = kind,
			window = id,
			requested = requested,
			observed = actual,
			status = code,
		},
	)
}

// Both native notifications and enumeration use this admission boundary.
opening_observe :: proc(
	state: ^State,
	app: Application,
	element: Ref,
	observation: Window,
) -> ^Window {
	value := observation
	old := state.manager.windows[value.id]
	if state.opening_tracking &&
	   !state.read_only &&
	   (old == nil || old.pid != value.pid) {
		opening_trace_begin(state)
		opening_trace_native(state, "opening-discovered", value.id)
		value.opening = {
			phase        = .Pending,
			focus_origin = state.manager.focused,
		}
	}
	w: ^Window
	if element != nil {
		w, _ = reconcile_window(state, app, element, value)
	} else {
		w, _ = reconcile_window_model(&state.manager, value)
	}
	if w.opening.phase == .Pending {
		if state.opening_windows == nil {
			state.opening_windows = make(map[u32]bool)
		}
		state.opening_windows[w.id] = true
		if state.opening_collecting {
			backend := state.opening_backend
			if backend.prepare == nil {
				backend = {opening_native_prepare, opening_conceal}
			}
			_, err := stage_opening(&state.manager, w, backend)
			if err != "" {
				fmt.eprintln("shoji: stage opening:", w.id, err)
			}
		} else {
			opening_attempt(state, w)
		}
	}
	if element != nil {
		reconcile_window_appearance(
			w,
			collect_window_appearance(state, element, w.id),
		)
	}
	return w
}

opening_created :: proc(state: ^State, observer, element: Ref) {
	if state.read_only || !state.opening_tracking {
		return
	}
	id: u32
	if _AXUIElementGetWindow(element, &id) != 0 ||
	   id == 0 ||
	   attribute_text(element, "AXRole") != "AXWindow" {
		return
	}
	opening_trace_begin(state)
	opening_trace_native(state, "opening-created", id)
	for pid, app in state.applications {
		if app.observer != observer {
			continue
		}
		if state.validation_pid != 0 && state.validation_pid != pid {
			return
		}
		opening_observe(
			state,
			app,
			element,
			collect_window(
				state,
				app,
				element,
				id,
				pid,
				app.policy,
				app.hidden,
			),
		)
		return
	}
}

// The transparent owned surface is a liveness token, not a screenshot. Dock's
// orphan recovery restores the real window if the token owner crashes.
opening_conceal :: proc(m: ^Manager, w: ^Window) -> string {
	state := (^State)(m.backend_user)
	guard, exists := state.opening_guards[w.id]
	if !exists {
		owner, known := animation_recovery_query_owner(state.connection, w.id)
		pid: i32
		if !known || SLSConnectionGetPID(owner, &pid) != 0 || pid != w.pid {
			return "opening window ownership is unavailable"
		}
		surface, err := surface_create(
			state,
			{0, 0, 1, 1},
			w.id,
			(1 << 1) | (1 << 3) | (1 << 9),
			13,
			1,
		)
		if err != "" {
			return err
		}
		proxy_owner, proxy_known := animation_recovery_query_owner(
			state.connection,
			surface.id,
		)
		if !proxy_known {
			surface_destroy(state, surface)
			return "opening token ownership is unavailable"
		}
		if err := animation_journal_record(
			&state.animation_journal,
			dock.Entry{w.id, surface.id, owner, proxy_owner},
		); err != "" {
			surface_destroy(state, surface); return err
		}
		CGContextClearRect(surface.ctx, {0, 0, 1, 1})
		CGContextFlush(surface.ctx)
		guard.proxy = {
			window  = w.id,
			surface = surface,
		}
		guard.original = w.frame
		if state.opening_guards == nil {
			state.opening_guards = make(map[u32]Opening_Guard)
		}
		state.opening_guards[w.id] = guard
	}
	if guard.hidden {
		return ""
	}
	opening_trace_native(state, "opening-conceal-begin", w.id)
	if err := animation_swap(guard.proxy, true); err != "" {
		return err
	}
	opening_trace_native(state, "opening-conceal-end", w.id)
	guard.hidden = true; state.opening_guards[w.id] = guard
	return ""
}

opening_release :: proc(state: ^State, id: u32) -> string {
	guard, exists := state.opening_guards[id]
	if !exists {
		return ""
	}
	if w := state.manager.windows[id];
	   w != nil &&
	   (w.opening.phase == .Pending || w.opening.phase == .Excluded) &&
	   guard.requested.w > 0 &&
	   guard.original.w > 0 {
		if err := apply_frame_now(state, id, guard.original); err != "" {
			return err
		}
	}
	opening_trace_native(state, "opening-reveal-begin", id)
	if err := native_proxy_restore(state, guard.proxy); err != "" {
		return err
	}
	opening_trace_native(state, "opening-reveal-end", id)
	native_proxy_destroy(state, guard.proxy)
	delete_key(&state.opening_guards, id)
	return ""
}

opening_native_prepare :: proc(
	m: ^Manager,
	w: ^Window,
	seed: Rect,
) -> (
	Rect,
	bool,
	string,
) {
	state := (^State)(m.backend_user)
	element := state.windows[w.id]
	guard, exists := state.opening_guards[w.id]
	if element == nil || !exists || !guard.hidden {
		return {}, false, ""
	}
	if guard.requested != seed {
		if err := perform(
			m,
			{kind = .Frame, window = w.id, frame = seed, direct = true},
		); err != "" {
			return {}, false, err
		}
		guard.requested = seed; guard.samples = 0
		guard.checked = time.now(); state.opening_guards[w.id] = guard
		return {}, false, ""
	}
	now := time.now()
	if time.diff(guard.checked, now) < 8 * time.Millisecond {
		return {}, false, ""
	}
	accepted, valid := window_frame(element).?
	if !valid {
		return {}, false, ""
	}
	if math.abs(accepted.x - guard.sample.x) <= 1 &&
	   math.abs(accepted.y - guard.sample.y) <= 1 &&
	   math.abs(accepted.w - guard.sample.w) <= 1 &&
	   math.abs(accepted.h - guard.sample.h) <= 1 {
		guard.samples += 1
	} else {
		guard.samples = 1
	}
	guard.sample = accepted; guard.checked = now
	state.opening_guards[w.id] = guard
	return accepted, guard.samples >= 2, ""
}

opening_attempt :: proc(state: ^State, w: ^Window) {
	backend := state.opening_backend
	if backend.prepare == nil {
		backend = {opening_native_prepare, opening_conceal}
	}
	wait := w.opening.wait
	admitted, err := admit_window(&state.manager, w, backend)
	if admitted {
		opening_trace_native(state, "opening-admitted", w.id, w.opening.seed)
	}
	if err != "" && wait != .Backend {
		fmt.eprintln("shoji: opening:", w.id, err)
	}
	if admitted || w.opening.phase == .Excluded {
		if err := opening_release(state, w.id); err != "" {
			fmt.eprintln("shoji: reveal opening:", err)
		}
	}
}

opening_destroyed :: proc(state: ^State, element: Ref) {
	id: u32
	for window, ref in state.windows {
		if CFEqual(element, ref) {
			id = window; break
		}
	}
	if id == 0 {
		return
	}
	w := state.manager.windows[id]
	// Remove the decoration before AX unsubscription, recovery or reflow can
	// block. Its generation still names the real owner when ordered above a
	// proxy, and focus may already have moved to another window.
	if state.focus_ring.window == id ||
	   (w != nil && state.focus_ring.generation == w.generation) {
		focus_ring_stop(state)
	}
	for i in 0 ..< state.tab_indicator.count {
		if state.tab_indicator.tabs[i].window == id {
			tab_indicator_stop(state); break
		}
	}
	if w == nil {
		return
	}
	s := space_by_id(&state.manager, w.space)
	app := state.applications[w.pid]
	window_reference_remove(state, id, app.observer)
	remove_observed_window(state, id)
	if err := opening_release(state, id); err != "" {
		fmt.eprintln("shoji: closed opening:", err)
	}
	delete_key(&state.opening_windows, id)
	if s != nil {
		if err := flush(&state.manager, s); err != "" {
			fmt.eprintln("shoji: close layout:", err)
		}
	}
}

opening_tick :: proc(state: ^State) {
	if state.read_only ||
	   state.manager.suspended ||
	   state.manager.gesture_active {
		return
	}
	ids := make(
		[dynamic]u32,
		0,
		len(state.opening_windows),
		context.temp_allocator,
	)
	for id in state.opening_windows { append(&ids, id) }
	sort_ids(ids[:])
	for id in ids {
		w := state.manager.windows[id]
		if w == nil ||
		   w.opening.phase == .Excluded ||
		   w.opening.phase == .Admitted {
			if err := opening_release(state, id); err == "" {
				delete_key(&state.opening_windows, id)
			}
			continue
		}
		if w.opening.phase == .Pending {
			if element := state.windows[id]; element != nil {
				w.ordered_in = window_ordered_in(state, id)
				if sid := window_space(state, id); sid != 0 {
					w.space = sid
				}
				if observed, valid := window_frame(element).?; valid {
					w.frame = observed
				}
			}
			opening_attempt(state, w)
			continue
		}
		if err := opening_release(state, id); err != "" {
			continue
		}
		busy := false
		for window in state.animations {
			if other := state.manager.windows[window];
			   other != nil && other.space == w.space {
				busy = true; break
			}
		}
		if s := space_by_id(&state.manager, w.space);
		   s != nil &&
		   s.view.layout == .Scroll &&
		   (s.view.scroll.motion.active || s.view.scroll.geometry_active) {
			busy = true
		}
		if !busy {
			if err := finish_opening(&state.manager, w); err != "" {
				fmt.eprintln("shoji: finish opening:", err)
			}
		}
	}
	opening_notice_tick(state)
}

opening_stop :: proc(state: ^State) {
	for id, guard in state.opening_guards {
		if w := state.manager.windows[id];
		   w != nil && w.opening.phase == .Pending {
			perform(
				&state.manager,
				{kind = .Layer, window = id, value = w.opening.original_layer},
			)
		}
		if err := opening_release(state, id); err != "" {
			fmt.eprintln("shoji: opening recovery:", err)
			native_proxy_destroy(state, guard.proxy)
		}
	}
	delete(state.opening_guards); delete(state.opening_windows)
	surface_destroy(state, state.opening_notice)
}
