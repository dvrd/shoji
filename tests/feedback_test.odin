package tests

import e "../src/engine"
import mac "../src/macos"
import "core:testing"
import "core:time"

feedback_create :: proc(
	state: ^mac.State,
	plan: e.Feedback_Plan,
) -> (
	mac.Owned_Surface,
	string,
) {
	r := (^Animation_Recorder)(state.event_user); r.created += 1
	return {id = 100 + plan.window, frame = plan.frame}, ""
}

feedback_destroy :: proc(state: ^mac.State, surface: mac.Owned_Surface) {
	r := (^Animation_Recorder)(state.event_user); r.destroyed += 1
}

feedback_update :: proc(
	state: ^mac.State,
	surface: mac.Owned_Surface,
	frame: e.Rect,
) -> string {
	r := (^Animation_Recorder)(state.event_user); r.updates += 1
	r.last = frame
	return r.fail_apply ? "injected overlay failure" : ""
}

floating_ring_frame_probe :: proc(
	state: ^mac.State,
	window: u32,
) -> (
	e.Rect,
	bool,
) {
	r := (^Animation_Recorder)(state.event_user)
	r.applied += 1
	return r.last, !r.fail_restore
}

@(test)
floating_ring_tracks_native_moves_without_refreshing_the_desktop :: proc(
	t: ^testing.T,
) {
	state: mac.State; actions: Recorder; r: Animation_Recorder
	fixture(&state.manager, &actions)
	defer e.manager_destroy(&state.manager); defer delete(actions.actions)
	defer mac.callback_scratch_destroy(&state.callback_scratch)
	state.event_user = &r
	state.feedback_backend = {
		create  = feedback_create,
		destroy = feedback_destroy,
		update  = feedback_update,
	}
	state.focus_frame_probe = floating_ring_frame_probe
	defer mac.feedback_stop(&state)
	testing.expect_value(
		t,
		e.flush(&state.manager, state.manager.spaces[0]),
		"",
	)
	w := state.manager.windows[1]; w.floating = true
	mac.focus_ring_tick(&state)
	state.windows = make(map[u32]mac.Ref); defer delete(state.windows)
	element := mac.cf_string("floating owner"); defer mac.CFRelease(element)
	state.windows[1] = mac.CFRetain(element)
	defer mac.CFRelease(state.windows[1])
	notice := mac.cf_string("AXMoved"); defer mac.CFRelease(notice)
	r.last = {100, 200, 400, 300}
	mac.observer_callback(nil, element, notice, &state)
	mac.focus_ring_tick(&state)
	testing.expect_value(t, w.frame, e.Rect{100, 200, 400, 300})
	testing.expect_value(t, state.focus_ring.bars[0].plan.frame.x, f64(110))
	testing.expect_value(t, r.applied, 1)
	mac.focus_ring_tick(&state)
	testing.expect_value(t, r.applied, 1)
	state.mouse.buttons = 1; r.last = {180, 220, 400, 300}
	mac.focus_ring_tick(&state)
	testing.expect_value(t, w.frame, e.Rect{180, 220, 400, 300})
	r.fail_restore = true; mac.focus_ring_tick(&state)
	testing.expect_value(t, w.frame, e.Rect{180, 220, 400, 300})
}

feedback_reorder :: proc(
	state: ^mac.State,
	owner: u32,
	surfaces: []mac.Owned_Surface,
) -> string {
	r := (^Animation_Recorder)(state.event_user); r.applied += 1
	assert(owner == state.focus_ring.window && len(surfaces) == 8)
	return r.fail_restore ? "injected ordering failure" : ""
}

focus_order_action :: proc(user: rawptr, action: e.Action) -> string {
	mac.focus_ring_note_action((^mac.State)(user), action)
	return ""
}

@(test)
focus_ring_reorders_after_opening_and_same_window_focus_without_idle_work :: proc(
	t: ^testing.T,
) {
	state: mac.State; actions: Recorder; r: Animation_Recorder
	fixture(&state.manager, &actions)
	defer e.manager_destroy(&state.manager); defer delete(actions.actions)
	defer mac.callback_scratch_destroy(&state.callback_scratch)
	state.event_user = &r
	state.feedback_backend = {
		feedback_create,
		feedback_destroy,
		feedback_update,
		feedback_reorder,
	}
	defer mac.feedback_stop(&state)
	testing.expect_value(
		t,
		e.flush(&state.manager, state.manager.spaces[0]),
		"",
	)
	w := state.manager.windows[state.manager.focused]
	w.opening = {
		phase         = .Opening,
		restore_layer = 0,
	}
	mac.focus_ring_tick(&state)
	for _ in 0 ..< 20 { mac.focus_ring_tick(&state) }
	testing.expect_value(t, r.applied, 1)
	state.manager.backend, state.manager.backend_user =
		focus_order_action, &state
	testing.expect_value(t, e.finish_opening(&state.manager, w), "")
	testing.expect(t, state.focus_ring.order_dirty)
	mac.focus_ring_tick(&state)
	testing.expect_value(t, r.applied, 2)
	testing.expect_value(t, r.created, 8)
	testing.expect_value(t, r.updates, 0)
	notification := mac.cf_string("AXFocusedWindowChanged")
	mac.observer_callback(nil, nil, notification, &state)
	mac.CFRelease(notification)
	mac.focus_ring_tick(&state)
	testing.expect_value(t, r.applied, 3)
	for _ in 0 ..< 20 { mac.focus_ring_tick(&state) }
	testing.expect_value(t, r.applied, 3)
	testing.expect_value(t, r.created, 8)
	testing.expect_value(t, r.updates, 0)
}

@(test)
focus_ring_order_failure_releases_surfaces_and_bounds_retries :: proc(
	t: ^testing.T,
) {
	state: mac.State; actions: Recorder; r: Animation_Recorder
	fixture(&state.manager, &actions)
	defer e.manager_destroy(&state.manager); defer delete(actions.actions)
	state.event_user = &r
	state.feedback_backend = {
		feedback_create,
		feedback_destroy,
		feedback_update,
		feedback_reorder,
	}
	defer mac.feedback_stop(&state)
	testing.expect_value(
		t,
		e.flush(&state.manager, state.manager.spaces[0]),
		"",
	)
	mac.focus_ring_tick(&state)
	r.fail_restore = true
	mac.focus_ring_note_action(
		&state,
		{kind = .Order, window = state.manager.focused},
	)
	mac.focus_ring_tick(&state)
	testing.expect(t, state.focus_ring.failed)
	testing.expect_value(t, r.destroyed, 8)
	for _ in 0 ..< 20 { mac.focus_ring_tick(&state) }
	testing.expect_value(t, r.applied, 2)
	testing.expect_value(t, r.created, 8)
}

@(test)
focus_ring_hides_for_a_single_window_and_reappears_for_a_visible_peer :: proc(
	t: ^testing.T,
) {
	state: mac.State; actions: Recorder; r: Animation_Recorder
	fixture(&state.manager, &actions)
	defer e.manager_destroy(&state.manager); defer delete(actions.actions)
	state.event_user = &r
	state.feedback_backend = {
		create  = feedback_create,
		destroy = feedback_destroy,
		update  = feedback_update,
	}
	defer mac.feedback_stop(&state)
	testing.expect_value(
		t,
		e.flush(&state.manager, state.manager.spaces[0]),
		"",
	)
	mac.focus_ring_tick(&state)
	testing.expect_value(t, r.created, 8)
	state.manager.windows[2].minimized = true
	mac.focus_ring_tick(&state)
	testing.expect_value(t, r.destroyed, 8)
	mac.focus_ring_tick(&state)
	testing.expect_value(t, r.created, 8)
	peer := state.manager.windows[2]
	peer.minimized = false; peer.hidden = true
	mac.focus_ring_tick(&state)
	testing.expect_value(t, r.created, 8)
	peer.hidden = false; peer.space = 200
	mac.focus_ring_tick(&state)
	testing.expect_value(t, r.created, 8)
	peer.space = 100; peer.ordered_in = false
	mac.focus_ring_tick(&state)
	testing.expect_value(t, r.created, 8)
	peer.ordered_in = true
	mac.focus_ring_tick(&state)
	testing.expect_value(t, r.created, 16)
	e.remove_window(&state.manager, 2)
	mac.focus_ring_tick(&state)
	testing.expect_value(t, r.destroyed, 16)
}

@(test)
rounded_focus_corners_leave_outside_and_inside_pixels_transparent :: proc(
	t: ^testing.T,
) {
	color := mac.CGColorSpaceCreateDeviceRGB()
	if !testing.expect(t, color != nil) {
		return
	}
	defer mac.CGColorSpaceRelease(color)
	for corner in ([]e.Feedback_Corner {
			.Top_Left,
			.Top_Right,
			.Bottom_Left,
			.Bottom_Right,
		}) {
		pixels: [10 * 10 * 4]u8
		ctx := mac.CGBitmapContextCreate(&pixels[0], 10, 10, 8, 40, color, 1)
		if !testing.expect(t, ctx != nil) {
			return
		}
		mac.native_feedback_paint(
			ctx,
			{
				frame = {0, 0, 10, 10},
				color = 0xff7fc8ff,
				solid = true,
				corner = corner,
				stroke_width = 3,
			},
		)
		mac.CGContextRelease(ctx)
		for sample, i in ([5][2]int{{0, 0}, {9, 9}, {3, 3}, {9, 0}, {0, 9}}) {
			x, y := sample[0], sample[1]
			if corner == .Top_Right || corner == .Bottom_Right {
				x = 9 - x
			}
			if corner == .Bottom_Left || corner == .Bottom_Right {
				y = 9 - y
			}
			alpha := pixels[(y * 10 + x) * 4 + 3]
			if i < 2 {
				testing.expect_value(t, alpha, u8(0))
			} else {
				testing.expect(t, alpha > 200)
			}
		}
		antialiased := false
		for i in 0 ..< 100 {
			if pixels[i * 4 + 3] > 0 && pixels[i * 4 + 3] < 255 {
				antialiased = true
			}
		}
		testing.expect(t, antialiased)
	}
}

@(test)
focus_ring_ignores_hover_helpers_but_counts_real_floating_windows :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	e.remove_window(&m, 2)
	testing.expect_value(t, e.flush(&m, m.spaces[0]), "")
	frame := m.windows[1].frame
	// Captured from Chrome's link-status bubble during the user's reproduction.
	helper := e.add_window(
		&m,
		{
			id = 2,
			pid = 42,
			app = "Google Chrome",
			role = "AXHelpTag",
			subrole = "AXUnknown",
			root_window = true,
			space = 100,
			display = 10,
			frame = {3, 1092, 512, 22},
			can_resize = false,
			ordered_in = true,
		},
	)
	for _ in 0 ..< 10 {
		_, valid := e.focus_ring_plans(&m, frame)
		testing.expect(t, !valid)
	}
	e.remove_window(&m, helper.id)
	peer := e.add_window(
		&m,
		{
			id = 3,
			pid = 43,
			role = "AXWindow",
			subrole = "AXStandardWindow",
			root_window = true,
			floating = true,
			space = 100,
			display = 10,
			frame = {100, 100, 400, 300},
		},
	)
	_, valid := e.focus_ring_plans(&m, frame)
	testing.expect(t, valid)
	peer.root_window = false
	_, valid = e.focus_ring_plans(&m, frame)
	testing.expect(t, !valid)
	e.remove_window(&m, peer.id)
	e.add_window(
		&m,
		{
			id = 4,
			pid = 43,
			role = "AXWindow",
			subrole = "AXDialog",
			root_window = true,
			floating = true,
			space = 100,
			display = 10,
			frame = {100, 100, 400, 300},
		},
	)
	_, valid = e.focus_ring_plans(&m, frame)
	testing.expect(t, valid)
}

Close_Ring_Check :: struct {
	t: ^testing.T,
	renderer: ^Animation_Recorder,
	flushed: bool,
}

closed_ring_layout_check :: proc(user: rawptr, action: e.Action) -> string {
	check := (^Close_Ring_Check)(user)
	if action.kind == .Frame {
		check.flushed = true
		testing.expect_value(check.t, check.renderer.destroyed, 8)
	}
	return ""
}

@(test)
destroyed_floating_window_drops_its_ring_before_reflow_even_after_focus_changes :: proc(
	t: ^testing.T,
) {
	for proxy in ([2]bool{false, true}) {
		state: mac.State; actions: Recorder; r: Animation_Recorder
		fixture(&state.manager, &actions)
		defer e.manager_destroy(&state.manager); defer delete(actions.actions)
		state.event_user = &r
		state.feedback_backend = {
			create  = feedback_create,
			destroy = feedback_destroy,
			update  = feedback_update,
		}
		defer mac.feedback_stop(&state)
		testing.expect_value(
			t,
			e.flush(&state.manager, state.manager.spaces[0]),
			"",
		)
		w := state.manager.windows[1]
		w.floating = true
		e.remove(&state.manager.spaces[0].view, 1)
		// The remaining tile has a pending reflow; its native writes must not
		// keep the destroyed floating owner's border on screen.
		state.animations = make(map[u32]mac.Animation_Job)
		defer delete(state.animations)
		if proxy {
			state.animations[1] = {
				generation = w.generation,
				pid = w.pid,
				presentation = mac.Animation_Proxy{surface = {id = 999}},
				from = w.frame,
				target = w.frame,
			}
		}
		mac.focus_ring_tick(&state)
		testing.expect_value(t, r.created, 8)
		if proxy {
			e.focus_window(&state.manager, 2)
		}
		check := Close_Ring_Check {
			t        = t,
			renderer = &r,
		}
		state.manager.backend, state.manager.backend_user =
			closed_ring_layout_check, &check
		state.windows = make(map[u32]mac.Ref)
		defer delete(state.windows)
		// A retained identity stands in for the destroyed AX object; matching
		// must use the known reference rather than query the dead element.
		element := mac.cf_string("closed floating window identity")
		defer mac.CFRelease(element)
		state.windows[1] = mac.CFRetain(element)
		mac.opening_destroyed(&state, element)
		testing.expect(t, check.flushed)
		testing.expect_value(t, r.destroyed, 8)
		testing.expect_value(t, state.focus_ring.window, u32(0))
		testing.expect(t, state.manager.windows[1] == nil)
	}
}

closed_owner_probe :: proc(state: ^mac.State, window: u32) -> Maybe(bool) {
	assert(window == 1) // Query the real owner, never its animation proxy.
	return false
}
unknown_owner_probe :: proc(state: ^mac.State, window: u32) -> Maybe(bool) {
	return nil
}
ordered_owner_probe :: proc(state: ^mac.State, window: u32) -> Maybe(bool) {
	return true
}

@(test)
ordered_out_retained_window_loses_its_ring_without_waiting_for_destruction :: proc(
	t: ^testing.T,
) {
	for proxy in ([2]bool{false, true}) {
		state: mac.State; actions: Recorder; r: Animation_Recorder
		fixture(&state.manager, &actions)
		defer e.manager_destroy(&state.manager); defer delete(actions.actions)
		state.event_user = &r
		state.feedback_backend = {
			create  = feedback_create,
			destroy = feedback_destroy,
			update  = feedback_update,
		}
		defer mac.feedback_stop(&state)
		testing.expect_value(
			t,
			e.flush(&state.manager, state.manager.spaces[0]),
			"",
		)
		w := state.manager.windows[1]; w.floating = true
		state.animations = make(map[u32]mac.Animation_Job)
		defer delete(state.animations)
		if proxy {
			state.animations[1] = {
				generation = w.generation,
				pid = w.pid,
				presentation = mac.Animation_Proxy{surface = {id = 999}},
				from = w.frame,
				target = w.frame,
			}
		}
		mac.focus_ring_tick(&state)
		mac.focus_ring_prune_unordered(&state, unknown_owner_probe)
		mac.focus_ring_prune_unordered(&state, ordered_owner_probe)
		testing.expect_value(t, r.destroyed, 0)
		mac.focus_ring_prune_unordered(&state, closed_owner_probe)
		testing.expect_value(t, r.destroyed, 8)
		testing.expect(t, state.manager.windows[1] != nil)
		testing.expect(t, !(w.ordered_in.? or_else true))
		mac.focus_ring_tick(&state)
		testing.expect_value(t, r.created, 8)
	}
}

@(test)
closing_a_different_window_does_not_remove_a_live_owners_ring :: proc(
	t: ^testing.T,
) {
	state: mac.State; actions: Recorder; r: Animation_Recorder
	fixture(&state.manager, &actions)
	defer e.manager_destroy(&state.manager); defer delete(actions.actions)
	state.event_user = &r
	state.feedback_backend = {
		create  = feedback_create,
		destroy = feedback_destroy,
		update  = feedback_update,
	}
	defer mac.feedback_stop(&state)
	e.add_window(
		&state.manager,
		{
			id = 3,
			pid = 44,
			role = "AXWindow",
			subrole = "AXStandardWindow",
			space = 100,
			display = 10,
			frame = {100, 100, 400, 300},
		},
	)
	testing.expect_value(
		t,
		e.flush(&state.manager, state.manager.spaces[0]),
		"",
	)
	mac.focus_ring_tick(&state)
	state.windows = make(map[u32]mac.Ref); defer delete(state.windows)
	element := mac.cf_string("unrelated destroyed window identity")
	defer mac.CFRelease(element)
	state.windows[2] = mac.CFRetain(element)
	mac.opening_destroyed(&state, element)
	testing.expect_value(t, r.destroyed, 0)
	testing.expect_value(t, state.focus_ring.owner, u32(1))
	mac.focus_ring_tick(&state)
	testing.expect_value(t, r.created, 8)
}

@(test)
focus_ring_uses_the_next_sublevel_without_integer_overflow :: proc(
	t: ^testing.T,
) {
	testing.expect_value(t, mac.focus_ring_sublevel(-20), i32(-19))
	testing.expect_value(t, mac.focus_ring_sublevel(0), i32(1))
	testing.expect_value(t, mac.focus_ring_sublevel(3), i32(4))
	testing.expect_value(t, mac.focus_ring_sublevel(max(i32)), max(i32))
	testing.expect_value(t, mac.focus_ring_sublevel(min(i32)), min(i32) + 1)
}

@(test)
focus_ring_configuration_and_transparent_center :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect(t, m.focus_ring.enabled)
	testing.expect_value(t, m.focus_ring.radius, f64(10))
	testing.expect(t, !e.config(&m, {"focus_ring_radius", "12"}).failed)
	testing.expect(t, e.config(&m, {"focus_ring_radius", "65"}).failed)
	testing.expect(t, e.config(&m, {"focus_ring_radius", "NaN"}).failed)
	testing.expect_value(t, m.focus_ring.radius, f64(12))
	testing.expect(t, !e.config(&m, {"focus_ring_radius", "10"}).failed)
	testing.expect(t, !e.config(&m, {"focus_ring_width", "4"}).failed)
	testing.expect(t, !e.config(&m, {"focus_ring_color", "0x80334455"}).failed)
	for value in ([]string{"0", "17", "NaN", "+Inf", "junk"}) {
		testing.expect(t, e.config(&m, {"focus_ring_width", value}).failed)
	}
	testing.expect_value(t, m.focus_ring.width, f64(4))
	plans, valid := e.focus_ring_plans(&m, {10, 20, 200, 100})
	testing.expect(t, valid)
	testing.expect_value(t, plans[0].frame, e.Rect{20, 20, 180, 4})
	testing.expect_value(t, plans[2].frame, e.Rect{10, 30, 4, 80})
	for p in plans {
		testing.expect(t, p.solid)
		testing.expect_value(t, p.color, u32(0x80334455))
		testing.expect(
			t,
			!(110 > p.frame.x &&
				110 < p.frame.x + p.frame.w &&
				70 > p.frame.y &&
				70 < p.frame.y + p.frame.h),
		)
	}
	m.windows[m.focused].fullscreen = true
	_, valid = e.focus_ring_plans(&m, {10, 20, 200, 100})
	testing.expect(t, !valid)
	m.windows[m.focused].fullscreen = false
	m.spaces[0].visible = false
	_, valid = e.focus_ring_plans(&m, {10, 20, 200, 100})
	testing.expect(t, !valid)
}

@(test)
focus_ring_reuses_surfaces_tracks_presented_geometry_and_recovers_from_failure :: proc(
	t: ^testing.T,
) {
	state: mac.State; actions: Recorder; r: Animation_Recorder
	fixture(&state.manager, &actions)
	defer e.manager_destroy(&state.manager); defer delete(actions.actions)
	state.event_user = &r
	state.feedback_backend = {
		create  = feedback_create,
		destroy = feedback_destroy,
		update  = feedback_update,
	}
	defer mac.feedback_stop(&state)
	w := state.manager.windows[state.manager.focused]
	w.frame = {0, 0, 500, 400}
	mac.focus_ring_tick(&state); mac.focus_ring_tick(&state)
	testing.expect_value(t, r.created, 8)
	testing.expect_value(t, r.updates, 0)
	state.animations = make(map[u32]mac.Animation_Job)
	defer delete(state.animations)
	state.animations[w.id] = {
		generation   = w.generation,
		pid          = w.pid,
		presentation = mac.Live_Resize{{50, 60, 400, 300}},
	}
	mac.focus_ring_tick(&state)
	testing.expect_value(t, r.created, 8)
	testing.expect_value(t, r.updates, 8)
	testing.expect_value(
		t,
		state.focus_ring.bars[0].plan.frame,
		e.Rect{60, 60, 380, 3},
	)
	state.animations[w.id] = {
		generation = w.generation,
		pid = w.pid,
		presentation = mac.Animation_Proxy{surface = {id = 999}},
		from = {0, 0, 200, 200},
		target = {200, 100, 400, 300},
		progress = .5,
	}
	mac.focus_ring_tick(&state)
	testing.expect_value(t, state.focus_ring.window, u32(999))
	testing.expect_value(
		t,
		state.focus_ring.bars[0].plan.frame,
		e.Rect{110, 50, 280, 3},
	)
	delete_key(&state.animations, w.id)
	mac.focus_ring_tick(&state)
	created := r.created
	w.generation += 1; mac.focus_ring_tick(&state)
	testing.expect_value(t, r.created, created + 8)
	r.fail_apply = true; w.frame.x += 10
	mac.focus_ring_tick(&state)
	testing.expect(t, state.focus_ring.failed)
	created = r.created; updates := r.updates
	w.frame.x += 10; mac.focus_ring_tick(&state)
	testing.expect_value(t, r.created, created)
	testing.expect_value(t, r.updates, updates)
	state.manager.focus_ring.enabled = false; mac.focus_ring_tick(&state)
	r.fail_apply = false
	state.manager.focus_ring.enabled = true; mac.focus_ring_tick(&state)
	testing.expect_value(t, r.created, created + 8)
	mac.focus_ring_stop(&state)
	testing.expect_value(t, r.created, r.destroyed)
}

@(test)
scroll_drop_indicator_matches_column_insertion_and_preserves_width :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2, 200); niri_open(&m, 3, 200)
	s := m.spaces[0]
	source_width := e.find(s.view.root, 1).column_width
	drag := e.mouse_begin(&m, 1, .Move, {30, 40})
	w := m.windows[3]
	point := e.Mouse_Point{w.frame.x + 1, w.frame.y + w.frame.h / 2}
	plan, valid := e.drag_feedback(&m, drag, 3, point)
	testing.expect(t, valid && plan.solid)
	testing.expect_value(t, plan.frame.w, f64(4))
	testing.expect_value(t, e.mouse_drop(&m, drag, 3, point), "")
	n := e.first(s.view.root)
	testing.expect_value(t, n.windows[0], u32(2))
	n = e.next(n); testing.expect_value(t, n.windows[0], u32(1))
	testing.expect_value(t, n.column_width, source_width)
	n = e.next(n); testing.expect_value(t, n.windows[0], u32(3))
}

@(test)
edge_scroll_waits_accelerates_reverses_and_stops_at_bounds :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	s := m.spaces[0]
	e.scroll_pan(&s.view, -16); e.flush(&m, s)
	drag := e.mouse_begin(&m, 1, .Move, {30, 40})
	edge: e.Drag_Edge
	point := e.Mouse_Point{1280, 400}
	before := s.view.scroll.offset
	moved, err := e.drag_edge_scroll(&m, &edge, drag, point, 10)
	testing.expect(t, !moved && err == "")
	moved, _ = e.drag_edge_scroll(&m, &edge, drag, point, 10.05)
	testing.expect(t, !moved)
	moved, _ = e.drag_edge_scroll(&m, &edge, drag, point, 10.12)
	testing.expect(t, moved)
	testing.expect(
		t,
		s.view.scroll.offset > before + 29 &&
		s.view.scroll.offset < before + 31,
	)
	testing.expect(t, !s.view.scroll.dragging)
	for i in 1 ..= 100 { e.drag_edge_scroll(&m, &edge, drag, point, 10.12 + f64(i) * .02) }
	testing.expect_value(
		t,
		s.view.scroll.offset,
		s.view.scroll.content_width - s.view.scroll.viewport.w + 16,
	)
	before = s.view.scroll.offset
	moved, _ = e.drag_edge_scroll(&m, &edge, drag, {0, 400}, 13)
	testing.expect(t, !moved)
	e.drag_edge_scroll(&m, &edge, drag, {0, 400}, 13.12)
	testing.expect(t, s.view.scroll.offset < before)
	e.drag_edge_scroll(&m, &edge, drag, {640, 400}, 13.13)
	testing.expect_value(t, edge.space, u64(0))
	m.mouse.edge.enabled = false
	e.drag_edge_scroll(&m, &edge, drag, point, 14)
	testing.expect_value(t, edge.space, u64(0))
	testing.expect(t, e.config(&m, {"scroll_drag_edge_speed", "NaN"}).failed)
	testing.expect(t, !e.config(&m, {"scroll_drag_edge_delay", "0"}).failed)
}

@(test)
edge_scroll_runs_without_new_pointer_events_and_releases_ownership :: proc(
	t: ^testing.T,
) {
	state: mac.State; r: Recorder; niri_fixture(&state.manager, &r)
	defer e.manager_destroy(&state.manager); defer delete(r.actions)
	niri_open(&state.manager, 2); niri_open(&state.manager, 3)
	s := state.manager.spaces[0]
	e.scroll_pan(&s.view, -16); e.flush(&state.manager, s)
	state.mouse.drag = e.mouse_begin(&state.manager, 1, .Move, {30, 40})
	state.mouse.phase = .Dragging
	state.mouse.point = {1280, 400}
	start := time.time_add(time.Time{}, 100 * time.Second)
	mac.mouse_tick(&state, true, start)
	before := s.view.scroll.offset
	mac.mouse_tick(&state, true, time.time_add(start, 120 * time.Millisecond))
	testing.expect(t, s.view.scroll.offset > before)
	testing.expect(t, !state.mouse.pending)
	state.mouse.phase = .Released_Drag
	mac.mouse_tick(&state, true, time.time_add(start, 140 * time.Millisecond))
	testing.expect_value(t, state.mouse.edge.space, u64(0))
	testing.expect_value(t, state.mouse.drag.window, u32(0))
}

@(test)
insertion_and_drag_previews_match_split_geometry :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	s := e.space_by_id(&m, 100)
	testing.expect_value(t, e.flush(&m, s), "")
	testing.expect(
		t,
		!e.window_command(&m, []string{"1", "--insert", "east"}).failed,
	)
	plan, valid := e.insertion_feedback(&m, s)
	testing.expect(t, valid)
	n := e.find(s.view.root, 1)
	_, right := e.partition(e.frame_for(n), .Vertical, s.view.ratio, 0)
	testing.expect_value(t, plan.frame, right)
	testing.expect(
		t,
		!e.config(&m, []string{"insert_feedback_color", "0x80334455"}).failed,
	)
	plan, valid = e.insertion_feedback(&m, s)
	testing.expect_value(t, plan.color, u32(0x80334455))
	drag := e.mouse_begin(&m, 1, .Move, {0, 0})
	w := m.windows[2]
	plan, valid = e.drag_feedback(
		&m,
		drag,
		2,
		{w.frame.x + w.frame.w / 2, w.frame.y + w.frame.h / 2},
	)
	testing.expect(t, valid)
	testing.expect_value(t, plan.frame, w.frame)
	m.suspended = true
	_, valid = e.drag_feedback(&m, drag, 2, {w.frame.x, w.frame.y})
	testing.expect(t, !valid)
	_, valid = e.insertion_feedback(&m, s)
	testing.expect(t, !valid)
	testing.expect(
		t,
		e.config(&m, []string{"insert_feedback_color", "0xGG000000"}).failed,
	)
}

@(test)
feedback_reuses_unchanged_overlays_and_releases_changed_and_removed_plans :: proc(
	t: ^testing.T,
) {
	state: mac.State; r: Animation_Recorder
	state.event_user = &r
	state.feedback_backend = {
		create  = feedback_create,
		destroy = feedback_destroy,
	}
	defer mac.feedback_stop(&state)
	plans := make(map[u32]e.Feedback_Plan)
	defer delete(plans)
	plans[1] = e.Feedback_Plan {
		window = 1,
		frame  = {0, 0, 200, 200},
		color  = 0xff112233,
	}
	mac.feedback_sync(&state, plans)
	mac.feedback_sync(&state, plans)
	testing.expect_value(t, r.created, 1)
	testing.expect_value(t, r.destroyed, 0)
	plans[1] = e.Feedback_Plan {
		window = 1,
		frame  = {0, 0, 100, 200},
		color  = 0xff112233,
	}
	mac.feedback_sync(&state, plans)
	testing.expect_value(t, r.created, 2)
	testing.expect_value(t, r.destroyed, 1)
	clear(&plans)
	mac.feedback_sync(&state, plans)
	testing.expect_value(t, r.destroyed, 2)
	testing.expect_value(t, len(state.feedback), 0)
}

@(test)
moving_solid_insertion_hint_reuses_backing_and_bounds_failure_retries :: proc(
	t: ^testing.T,
) {
	state: mac.State; r: Animation_Recorder; state.event_user = &r
	state.feedback_backend = {
		create  = feedback_create,
		destroy = feedback_destroy,
		update  = feedback_update,
	}
	defer mac.feedback_stop(&state)
	plans := make(map[u32]e.Feedback_Plan); defer delete(plans)
	plan := e.Feedback_Plan {
		window = 1,
		frame  = {20, 20, 4, 500},
		color  = 0xff123456,
		solid  = true,
	}
	plans[0] = plan; mac.feedback_sync(&state, plans)
	for _ in 1 ..= 100 {
		plan.frame.x += 1; plans[0] = plan; mac.feedback_sync(&state, plans)
	}
	testing.expect_value(t, r.created, 1)
	testing.expect_value(t, r.updates, 100)
	r.fail_apply = true
	plan.frame.x += 1; plans[0] = plan; mac.feedback_sync(&state, plans)
	testing.expect_value(t, r.destroyed, 1)
	plan.frame.x += 1; plans[0] = plan; mac.feedback_sync(&state, plans)
	testing.expect_value(t, r.created, 1)
	testing.expect_value(t, r.updates, 101)
}

@(test)
floating_pointer_drag_defers_desktop_discovery_until_release :: proc(
	t: ^testing.T,
) {
	state: mac.State; r: Recorder; fixture(&state.manager, &r)
	defer e.manager_destroy(&state.manager); defer delete(r.actions)
	state.manager.windows[1].floating = true
	state.mouse.buttons = 1; state.dirty = true
	now := time.now(); last := now
	mac.desktop_refresh_tick(&state, &last, now, refresh_command_space)
	testing.expect_value(t, state.manager.active_space, u64(100))
	testing.expect(t, state.dirty)
	state.mouse.buttons = 0
	mac.desktop_refresh_tick(&state, &last, now, refresh_command_space)
	testing.expect_value(t, state.manager.active_space, u64(200))
}
