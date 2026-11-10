package tests

import mac "../src"
import "core:testing"
import "core:time"
import layout "../src/layout"

feedback_create :: proc(
	state: ^mac.State,
	plan: mac.Feedback_Plan,
) -> (
	mac.Owned_Surface,
	string,
) {
	r := (^Animation_Recorder)(state.event_user); r.created += 1
	return {id = 100 + plan.window, frame = plan.frame}, ""
}

@(test)
tab_indicator_surfaces_follow_geometry_and_focus_clicks :: proc(t: ^testing.T) {
	state: mac.State; actions: Recorder; r: Animation_Recorder
	niri_fixture(&state.manager, &actions)
	defer mac.manager_destroy(&state.manager); defer delete(actions.actions)
	state.event_user = &r
	state.feedback_backend = {create = feedback_create, destroy = feedback_destroy, update = feedback_update}
	defer mac.feedback_stop(&state)
	niri_open(&state.manager, 2)
	mac.execute(&state.manager, {"window", "1", "--stack", "2"})
	mac.execute(&state.manager, {"window", "1", "--column-display", "tabbed"})
	mac.execute(&state.manager, {"window", "1", "--focus"})
	frame := mac.Rect{100, 50, 400, 600}
	mac.tab_indicator_tick(&state, frame, 1)
	mac.tab_indicator_tick(&state, frame, 1)
	testing.expect_value(t, r.created, 2)
	testing.expect_value(t, r.updates, 0)
	testing.expect_value(t, state.tab_indicator.bars[0].plan.color, state.manager.focus_ring.color)
	testing.expect(t, mac.config(&state.manager, {"tab_indicator_active_color", "bad"}).failed)
	testing.expect(t, !mac.config(&state.manager, {"tab_indicator_active_color", "0xff112233"}).failed)
	testing.expect(t, !mac.config(&state.manager, {"tab_indicator_inactive_color", "0xffaabbcc"}).failed)
	mac.tab_indicator_tick(&state, frame, 1)
	testing.expect_value(t, state.tab_indicator.bars[0].plan.color, u32(0xff112233))
	testing.expect_value(t, state.tab_indicator.bars[1].plan.color, u32(0xffaabbcc))
	testing.expect(t, !mac.config(&state.manager, {"tab_indicator_active_color", "default"}).failed)
	mac.tab_indicator_tick(&state, frame, 1)
	testing.expect_value(t, state.tab_indicator.bars[0].plan.color, state.manager.focus_ring.color)
	testing.expect_value(t, mac.tab_indicator_hit(&state, {92, 400}).window, u32(2))
	testing.expect_value(t, mac.tab_indicator_hit(&state, {110, 400}).window, u32(0))
	tab := state.tab_indicator.tabs[1]
	state.mouse.tab_pending, state.mouse.tab_pending_generation = tab.window, tab.generation
	mac.mouse_tick(&state, false)
	testing.expect_value(t, state.manager.focused, u32(2))
	mac.tab_indicator_tick(&state, {120, 50, 400, 600}, 2)
	testing.expect_value(t, mac.tab_indicator_hit(&state, {112, 400}).window, u32(2))
	mac.execute(&state.manager, {"window", "2", "--column-display", "normal"})
	mac.tab_indicator_tick(&state, frame, 2)
	testing.expect_value(t, state.tab_indicator.count, 0)
	niri_open(&state.manager, 3); niri_open(&state.manager, 4)
	mac.execute(&state.manager, {"window", "1", "--stack", "2"})
	mac.execute(&state.manager, {"window", "1", "--column-display", "tabbed"})
	mac.execute(&state.manager, {"window", "3", "--stack", "4"})
	mac.execute(&state.manager, {"window", "3", "--column-display", "tabbed"})
	mac.execute(&state.manager, {"window", "1", "--focus"})
	mac.tab_indicator_tick(&state, state.manager.windows[1].frame, 1)
	testing.expect(t, state.tab_indicator.count >= 4)
	far := state.tab_indicator.tabs[2]
	testing.expect(t, far.window != 1 && far.window != 0)
	state.mouse.tab_pending, state.mouse.tab_pending_generation = far.window, far.generation
	mac.mouse_tick(&state, false)
	testing.expect_value(t, state.manager.focused, far.window)
	testing.expect_value(t, mac.tab_indicator_hit(&state, {101, 400}).window, u32(0))
}

feedback_destroy :: proc(state: ^mac.State, surface: mac.Owned_Surface) {
	r := (^Animation_Recorder)(state.event_user); r.destroyed += 1
}

feedback_update :: proc(
	state: ^mac.State,
	surface: mac.Owned_Surface,
	frame: mac.Rect,
) -> string {
	r := (^Animation_Recorder)(state.event_user); r.updates += 1
	r.last = frame
	return r.fail_apply ? "injected overlay failure" : ""
}

floating_ring_frame_probe :: proc(
	state: ^mac.State,
	window: u32,
) -> (
	mac.Rect,
	bool,
) {
	r := (^Animation_Recorder)(state.event_user)
	r.applied += 1
	return r.last, !r.fail_restore
}

scroll_ring_frame_probe :: proc(state: ^mac.State, window: u32) -> (mac.Rect, bool) {
	return {120, 40, 400, 300}, true
}

@(test)
refreshed_focus_updates_the_ring_before_later_refresh_work :: proc(t: ^testing.T) {
	state: mac.State; actions: Recorder; r: Animation_Recorder
	fixture(&state.manager, &actions)
	defer mac.manager_destroy(&state.manager); defer delete(actions.actions)
	state.event_user = &r
	state.feedback_backend = {create = feedback_create, destroy = feedback_destroy, update = feedback_update, reorder = feedback_reorder}
	defer mac.feedback_stop(&state)
	testing.expect_value(t, mac.flush(&state.manager, state.manager.spaces[0]), "")
	mac.focus_ring_tick(&state)
	testing.expect_value(t, state.focus_ring.owner, u32(1))
	mac.refresh_set_focus(&state, 2)
	testing.expect_value(t, state.manager.focused, u32(2))
	testing.expect_value(t, state.focus_ring.owner, u32(2))
}

@(test)
scroll_focus_change_reuses_the_ring_surfaces :: proc(t: ^testing.T) {
	state: mac.State; actions: Recorder; r: Animation_Recorder
	fixture(&state.manager, &actions)
	defer mac.manager_destroy(&state.manager); defer delete(actions.actions)
	state.event_user = &r
	state.feedback_backend = {create = feedback_create, destroy = feedback_destroy, update = feedback_update, reorder = feedback_reorder}
	defer mac.feedback_stop(&state)
	mac.execute(&state.manager, {"space", "--layout", "scroll"})
	mac.focus_ring_tick(&state)
	testing.expect_value(t, r.created, 8)
	mac.focus_window(&state.manager, 2)
	mac.focus_ring_tick(&state)
	testing.expect_value(t, state.focus_ring.owner, u32(2))
	testing.expect_value(t, r.created, 8)
	testing.expect_value(t, r.destroyed, 0)
}

@(test)
scroll_focus_travel_hides_the_ring_until_the_window_arrives :: proc(t: ^testing.T) {
	state: mac.State; actions: Recorder; r: Animation_Recorder
	fixture(&state.manager, &actions)
	defer mac.manager_destroy(&state.manager); defer delete(actions.actions)
	state.event_user = &r
	state.feedback_backend = {create = feedback_create, destroy = feedback_destroy, update = feedback_update}
	defer mac.feedback_stop(&state)
	testing.expect(t, !mac.execute(&state.manager, {"space", "--layout", "scroll"}).failed)
	mac.focus_ring_tick(&state)
	testing.expect(t, state.focus_ring.owner != 0)
	w := state.manager.windows[state.manager.focused]
	rest := w.frame
	w.frame = {4000, rest.y, rest.w, rest.h}
	state.manager.spaces[0].view.scroll.motion.active = true
	destroyed := r.destroyed
	mac.focus_ring_tick(&state)
	testing.expect_value(t, state.focus_ring.owner, u32(0))
	testing.expect(t, r.destroyed > destroyed)
	for bar in state.focus_ring.bars {
		testing.expect_value(t, bar.surface.id, u32(0))
	}
	w.frame = rest
	state.manager.spaces[0].view.scroll.motion.active = false
	mac.focus_ring_tick(&state)
	testing.expect_value(t, state.focus_ring.owner, w.id)
	testing.expect_value(t, state.focus_ring.bars[0].plan.frame.x, rest.x + state.manager.focus_ring.radius)
}

@(test)
scroll_ring_tracks_observed_window_during_motion :: proc(t: ^testing.T) {
	state: mac.State; actions: Recorder; r: Animation_Recorder
	fixture(&state.manager, &actions)
	defer mac.manager_destroy(&state.manager); defer delete(actions.actions)
	state.event_user = &r
	state.feedback_backend = {create = feedback_create, destroy = feedback_destroy, update = feedback_update}
	state.focus_frame_probe = scroll_ring_frame_probe
	defer mac.feedback_stop(&state)
	testing.expect(t, !mac.execute(&state.manager, {"space", "--layout", "scroll"}).failed)
	w := state.manager.windows[state.manager.focused]
	requested := w.frame
	state.manager.spaces[0].view.scroll.dragging = true
	mac.focus_ring_tick(&state)
	testing.expect_value(t, state.focus_ring.bars[0].plan.frame.x, f64(130))
	testing.expect_value(t, w.frame, requested)
}

@(test)
floating_ring_tracks_native_moves_without_refreshing_the_desktop :: proc(
	t: ^testing.T,
) {
	state: mac.State; actions: Recorder; r: Animation_Recorder
	fixture(&state.manager, &actions)
	defer mac.manager_destroy(&state.manager); defer delete(actions.actions)
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
		mac.flush(&state.manager, state.manager.spaces[0]),
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
	testing.expect_value(t, w.frame, mac.Rect{100, 200, 400, 300})
	testing.expect_value(t, state.focus_ring.bars[0].plan.frame.x, f64(110))
	testing.expect_value(t, r.applied, 1)
	mac.focus_ring_tick(&state)
	testing.expect_value(t, r.applied, 1)
	state.mouse.buttons = 1; r.last = {180, 220, 400, 300}
	mac.focus_ring_tick(&state)
	testing.expect_value(t, w.frame, mac.Rect{180, 220, 400, 300})
	r.fail_restore = true; mac.focus_ring_tick(&state)
	testing.expect_value(t, w.frame, mac.Rect{180, 220, 400, 300})
}

@(test)
sticky_window_ring_tracks_native_moves_without_refreshing_the_desktop :: proc(t: ^testing.T) {
	state: mac.State; actions: Recorder; r: Animation_Recorder
	fixture(&state.manager, &actions)
	defer mac.manager_destroy(&state.manager); defer delete(actions.actions)
	state.event_user = &r
	state.feedback_backend = {create = feedback_create, destroy = feedback_destroy, update = feedback_update}
	state.focus_frame_probe = floating_ring_frame_probe
	defer mac.feedback_stop(&state)
	w := state.manager.windows[1]; w.sticky = true
	mac.focus_ring_tick(&state)
	state.focus_geometry_dirty = true
	r.last = {100, 200, 400, 300}
	mac.focus_ring_tick(&state)
	testing.expect_value(t, w.frame, mac.Rect{100, 200, 400, 300})
	testing.expect_value(t, state.focus_ring.bars[0].plan.frame.x, f64(110))
	state.mouse.buttons = 1; r.last = {180, 220, 400, 300}
	mac.focus_ring_tick(&state)
	testing.expect_value(t, w.frame, mac.Rect{180, 220, 400, 300})
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

focus_order_action :: proc(user: rawptr, action: mac.Action) -> string {
	mac.focus_ring_note_action((^mac.State)(user), action)
	return ""
}

@(test)
focus_ring_reorders_after_opening_and_same_window_focus_without_idle_work :: proc(
	t: ^testing.T,
) {
	state: mac.State; actions: Recorder; r: Animation_Recorder
	fixture(&state.manager, &actions)
	defer mac.manager_destroy(&state.manager); defer delete(actions.actions)
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
		mac.flush(&state.manager, state.manager.spaces[0]),
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
	testing.expect_value(t, mac.finish_opening(&state.manager, w), "")
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
	defer mac.manager_destroy(&state.manager); defer delete(actions.actions)
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
		mac.flush(&state.manager, state.manager.spaces[0]),
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
	defer mac.manager_destroy(&state.manager); defer delete(actions.actions)
	state.event_user = &r
	state.feedback_backend = {
		create  = feedback_create,
		destroy = feedback_destroy,
		update  = feedback_update,
	}
	defer mac.feedback_stop(&state)
	testing.expect_value(
		t,
		mac.flush(&state.manager, state.manager.spaces[0]),
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
	mac.remove_window(&state.manager, 2)
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
	for corner in ([]mac.Feedback_Corner {
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
	m: mac.Manager; r: Recorder; fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	mac.remove_window(&m, 2)
	testing.expect_value(t, mac.flush(&m, m.spaces[0]), "")
	frame := m.windows[1].frame
	// Captured from Chrome's link-status bubble during the user's reproduction.
	helper := mac.add_window(
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
		_, valid := mac.focus_ring_plans(&m, frame)
		testing.expect(t, !valid)
	}
	mac.remove_window(&m, helper.id)
	peer := mac.add_window(
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
	_, valid := mac.focus_ring_plans(&m, frame)
	testing.expect(t, valid)
	peer.root_window = false
	_, valid = mac.focus_ring_plans(&m, frame)
	testing.expect(t, !valid)
	mac.remove_window(&m, peer.id)
	mac.add_window(
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
	_, valid = mac.focus_ring_plans(&m, frame)
	testing.expect(t, valid)
}

Close_Ring_Check :: struct {
	t: ^testing.T,
	renderer: ^Animation_Recorder,
	flushed: bool,
}

closed_ring_layout_check :: proc(user: rawptr, action: mac.Action) -> string {
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
		defer mac.manager_destroy(&state.manager); defer delete(actions.actions)
		state.event_user = &r
		state.feedback_backend = {
			create  = feedback_create,
			destroy = feedback_destroy,
			update  = feedback_update,
		}
		defer mac.feedback_stop(&state)
		testing.expect_value(
			t,
			mac.flush(&state.manager, state.manager.spaces[0]),
			"",
		)
		w := state.manager.windows[1]
		w.floating = true
		layout.remove(&state.manager.spaces[0].view, 1)
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
			mac.focus_window(&state.manager, 2)
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
		defer mac.manager_destroy(&state.manager); defer delete(actions.actions)
		state.event_user = &r
		state.feedback_backend = {
			create  = feedback_create,
			destroy = feedback_destroy,
			update  = feedback_update,
		}
		defer mac.feedback_stop(&state)
		testing.expect_value(
			t,
			mac.flush(&state.manager, state.manager.spaces[0]),
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
	defer mac.manager_destroy(&state.manager); defer delete(actions.actions)
	state.event_user = &r
	state.feedback_backend = {
		create  = feedback_create,
		destroy = feedback_destroy,
		update  = feedback_update,
	}
	defer mac.feedback_stop(&state)
	mac.add_window(
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
		mac.flush(&state.manager, state.manager.spaces[0]),
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
	m: mac.Manager; r: Recorder; fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	testing.expect(t, m.focus_ring.enabled)
	testing.expect_value(t, m.focus_ring.radius, f64(10))
	testing.expect(t, !mac.config(&m, {"focus_ring_radius", "12"}).failed)
	testing.expect(t, mac.config(&m, {"focus_ring_radius", "65"}).failed)
	testing.expect(t, mac.config(&m, {"focus_ring_radius", "NaN"}).failed)
	testing.expect_value(t, m.focus_ring.radius, f64(12))
	testing.expect(t, !mac.config(&m, {"focus_ring_radius", "10"}).failed)
	testing.expect(t, !mac.config(&m, {"focus_ring_width", "4"}).failed)
	testing.expect(t, !mac.config(&m, {"focus_ring_color", "0x80334455"}).failed)
	for value in ([]string{"0", "17", "NaN", "+Inf", "junk"}) {
		testing.expect(t, mac.config(&m, {"focus_ring_width", value}).failed)
	}
	testing.expect_value(t, m.focus_ring.width, f64(4))
	plans, valid := mac.focus_ring_plans(&m, {10, 20, 200, 100})
	testing.expect(t, valid)
	testing.expect_value(t, plans[0].frame, mac.Rect{20, 20, 180, 4})
	testing.expect_value(t, plans[2].frame, mac.Rect{10, 30, 4, 80})
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
	_, valid = mac.focus_ring_plans(&m, {10, 20, 200, 100})
	testing.expect(t, !valid)
	m.windows[m.focused].fullscreen = false
	m.spaces[0].visible = false
	_, valid = mac.focus_ring_plans(&m, {10, 20, 200, 100})
	testing.expect(t, !valid)
}

@(test)
focus_ring_reuses_surfaces_tracks_presented_geometry_and_recovers_from_failure :: proc(
	t: ^testing.T,
) {
	state: mac.State; actions: Recorder; r: Animation_Recorder
	fixture(&state.manager, &actions)
	defer mac.manager_destroy(&state.manager); defer delete(actions.actions)
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
		mac.Rect{60, 60, 380, 3},
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
		mac.Rect{110, 50, 280, 3},
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
	m: mac.Manager; r: Recorder; niri_fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2, 200); niri_open(&m, 3, 200)
	s := m.spaces[0]
	source_width := layout.find(s.view.root, 1).column_width
	drag := mac.mouse_begin(&m, 1, .Move, {30, 40})
	w := m.windows[3]
	point := mac.Mouse_Point{w.frame.x + 1, w.frame.y + w.frame.h / 2}
	plan, valid := mac.drag_feedback(&m, drag, 3, point)
	testing.expect(t, valid && plan.solid)
	testing.expect_value(t, plan.frame.w, f64(4))
	testing.expect_value(t, mac.mouse_drop(&m, drag, 3, point), "")
	n := layout.first(s.view.root)
	testing.expect_value(t, n.windows[0], u32(2))
	n = layout.next(n); testing.expect_value(t, n.windows[0], u32(1))
	testing.expect_value(t, n.column_width, source_width)
	n = layout.next(n); testing.expect_value(t, n.windows[0], u32(3))
}

@(test)
scroll_top_drop_inserts_a_row_without_moving_focus :: proc(t: ^testing.T) {
	m: mac.Manager; r: Recorder; niri_fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	mac.focus_window(&m, 2)
	focused := m.focused
	column := layout.find(m.spaces[0].view.root, 3)
	column.column_tabbed = true
	drag := mac.mouse_begin(&m, 1, .Move, {30, 40})
	w := m.windows[3]
	point := mac.Mouse_Point{w.frame.x + w.frame.w / 2, w.frame.y + 1}
	plan, valid := mac.drag_feedback(&m, drag, 3, point)
	testing.expect(t, valid && plan.solid)
	testing.expect_value(t, plan.frame.h, f64(4))
	testing.expect(t, plan.frame.w > 4)
	testing.expect_value(t, mac.mouse_drop(&m, drag, 3, point), "")
	testing.expect_value(t, m.focused, focused)
	n := layout.find(m.spaces[0].view.root, 3)
	testing.expect(t, n == layout.find(m.spaces[0].view.root, 1))
	testing.expect_value(t, n.windows[0], u32(1))
	testing.expect_value(t, n.windows[1], u32(3))
	testing.expect(t, !n.column_tabbed)
	w = m.windows[3]
	drag = mac.mouse_begin(&m, 1, .Move, {30, 40})
	point = {w.frame.x + w.frame.w / 2, w.frame.y + w.frame.h - 1}
	testing.expect_value(t, mac.mouse_drop(&m, drag, 3, point), "")
	n = layout.find(m.spaces[0].view.root, 3)
	testing.expect_value(t, n.windows[0], u32(3))
	testing.expect_value(t, n.windows[1], u32(1))
	testing.expect_value(t, m.focused, focused)
}

@(test)
edge_scroll_waits_accelerates_reverses_and_stops_at_bounds :: proc(
	t: ^testing.T,
) {
	m: mac.Manager; r: Recorder; niri_fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	s := m.spaces[0]
	layout.scroll_pan(&s.view, -16); mac.flush(&m, s)
	drag := mac.mouse_begin(&m, 1, .Move, {30, 40})
	edge: mac.Drag_Edge
	point := mac.Mouse_Point{1280, 400}
	before := s.view.scroll.offset
	moved, err := mac.drag_edge_scroll(&m, &edge, drag, point, 10)
	testing.expect(t, !moved && err == "")
	moved, _ = mac.drag_edge_scroll(&m, &edge, drag, point, 10.05)
	testing.expect(t, !moved)
	moved, _ = mac.drag_edge_scroll(&m, &edge, drag, point, 10.12)
	testing.expect(t, moved)
	testing.expect(
		t,
		s.view.scroll.offset > before + 29 &&
		s.view.scroll.offset < before + 31,
	)
	testing.expect(t, !s.view.scroll.dragging)
	for i in 1 ..= 100 { mac.drag_edge_scroll(&m, &edge, drag, point, 10.12 + f64(i) * .02) }
	testing.expect_value(
		t,
		s.view.scroll.offset,
		s.view.scroll.content_width - s.view.scroll.viewport.w + 16,
	)
	before = s.view.scroll.offset
	moved, _ = mac.drag_edge_scroll(&m, &edge, drag, {0, 400}, 13)
	testing.expect(t, !moved)
	mac.drag_edge_scroll(&m, &edge, drag, {0, 400}, 13.12)
	testing.expect(t, s.view.scroll.offset < before)
	mac.drag_edge_scroll(&m, &edge, drag, {640, 400}, 13.13)
	testing.expect_value(t, edge.space, u64(0))
	m.mouse.edge.enabled = false
	mac.drag_edge_scroll(&m, &edge, drag, point, 14)
	testing.expect_value(t, edge.space, u64(0))
	testing.expect(t, mac.config(&m, {"scroll_drag_edge_speed", "NaN"}).failed)
	testing.expect(t, !mac.config(&m, {"scroll_drag_edge_delay", "0"}).failed)
}

@(test)
edge_scroll_runs_without_new_pointer_events_and_releases_ownership :: proc(
	t: ^testing.T,
) {
	state: mac.State; r: Recorder; niri_fixture(&state.manager, &r)
	defer mac.manager_destroy(&state.manager); defer delete(r.actions)
	niri_open(&state.manager, 2); niri_open(&state.manager, 3)
	s := state.manager.spaces[0]
	layout.scroll_pan(&s.view, -16); mac.flush(&state.manager, s)
	state.mouse.drag = mac.mouse_begin(&state.manager, 1, .Move, {30, 40})
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
	m: mac.Manager; r: Recorder; fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	s := mac.space_by_id(&m, 100)
	testing.expect_value(t, mac.flush(&m, s), "")
	testing.expect(
		t,
		!mac.window_command(&m, []string{"1", "--insert", "east"}).failed,
	)
	plan, valid := mac.insertion_feedback(&m, s)
	testing.expect(t, valid)
	n := layout.find(s.view.root, 1)
	_, right := layout.partition(layout.frame_for(n), .Vertical, s.view.ratio, 0)
	testing.expect_value(t, plan.frame, right)
	testing.expect(
		t,
		!mac.config(&m, []string{"insert_feedback_color", "0x80334455"}).failed,
	)
	plan, valid = mac.insertion_feedback(&m, s)
	testing.expect_value(t, plan.color, u32(0x80334455))
	drag := mac.mouse_begin(&m, 1, .Move, {0, 0})
	w := m.windows[2]
	plan, valid = mac.drag_feedback(
		&m,
		drag,
		2,
		{w.frame.x + w.frame.w / 2, w.frame.y + w.frame.h / 2},
	)
	testing.expect(t, valid)
	testing.expect_value(t, plan.frame, w.frame)
	m.suspended = true
	_, valid = mac.drag_feedback(&m, drag, 2, {w.frame.x, w.frame.y})
	testing.expect(t, !valid)
	_, valid = mac.insertion_feedback(&m, s)
	testing.expect(t, !valid)
	testing.expect(
		t,
		mac.config(&m, []string{"insert_feedback_color", "0xGG000000"}).failed,
	)
}

@(test)
invalid_color_names_the_setting_that_failed :: proc(t: ^testing.T) {
	m: mac.Manager
	mac.manager_init(&m)
	defer mac.manager_destroy(&m)
	ring := mac.config(&m, []string{"focus_ring_color", "0xGG000000"})
	testing.expect_value(t, ring.text, "invalid focus_ring_color")
	feedback := mac.config(&m, []string{"insert_feedback_color", "0xGG000000"})
	testing.expect_value(t, feedback.text, "invalid insert_feedback_color")
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
	plans := make(map[u32]mac.Feedback_Plan)
	defer delete(plans)
	plans[1] = mac.Feedback_Plan {
		window = 1,
		frame  = {0, 0, 200, 200},
		color  = 0xff112233,
	}
	mac.feedback_sync(&state, plans)
	mac.feedback_sync(&state, plans)
	testing.expect_value(t, r.created, 1)
	testing.expect_value(t, r.destroyed, 0)
	plans[1] = mac.Feedback_Plan {
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
	plans := make(map[u32]mac.Feedback_Plan); defer delete(plans)
	plan := mac.Feedback_Plan {
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
	defer mac.manager_destroy(&state.manager); defer delete(r.actions)
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

@(test)
destroyed_floating_window_drops_its_ring_before_the_structural_refresh :: proc(
	t: ^testing.T,
) {
	state: mac.State; actions: Recorder; r: Animation_Recorder
	fixture(&state.manager, &actions)
	defer mac.manager_destroy(&state.manager); defer delete(actions.actions)
	state.event_user = &r
	state.feedback_backend = {create = feedback_create, destroy = feedback_destroy, update = feedback_update}
	defer mac.feedback_stop(&state)
	testing.expect_value(t, mac.flush(&state.manager, state.manager.spaces[0]), "")
	w := state.manager.windows[1]; w.floating = true
	mac.focus_ring_tick(&state)
	testing.expect_value(t, r.created, 8)
	state.windows = make(map[u32]mac.Ref); defer delete(state.windows)
	other := mac.cf_string("other window"); defer mac.CFRelease(other)
	element := mac.cf_string("floating owner"); defer mac.CFRelease(element)
	state.windows[1] = element; state.windows[2] = other
	// Another window closing leaves the ring alone.
	mac.window_destroyed(&state, other)
	testing.expect_value(t, r.destroyed, 0)
	mac.window_destroyed(&state, element)
	testing.expect_value(t, r.destroyed, 8)
	// The window is still known until the refresh, but the ring stays down.
	testing.expect(t, state.manager.windows[1] != nil)
	mac.focus_ring_tick(&state)
	testing.expect_value(t, r.created, 8)
}

@(test)
new_tab_keeps_the_tab_bar_while_the_window_is_prepared :: proc(t: ^testing.T) {
	state: mac.State; actions: Recorder; r: Animation_Recorder
	niri_fixture(&state.manager, &actions)
	defer mac.manager_destroy(&state.manager); defer delete(actions.actions)
	state.event_user = &r
	state.feedback_backend = {create = feedback_create, destroy = feedback_destroy, update = feedback_update}
	defer mac.feedback_stop(&state)
	niri_open(&state.manager, 2)
	mac.execute(&state.manager, {"window", "1", "--stack", "2"})
	mac.execute(&state.manager, {"window", "1", "--column-display", "tabbed"})
	mac.execute(&state.manager, {"window", "1", "--focus"})
	mac.focus_ring_tick(&state)
	created, destroyed := r.created, r.destroyed
	testing.expect_value(t, state.tab_indicator.count, 2)
	// The new window has focus but is still being prepared concealed.
	w := mac.discover_window(&state.manager, {id = 30, pid = 70, role = "AXWindow", subrole = "AXStandardWindow", space = 100, display = 10, frame = {100, 100, 440, 288}})
	mac.focus_window(&state.manager, 30)
	mac.focus_ring_tick(&state)
	testing.expect_value(t, r.destroyed, destroyed)
	testing.expect_value(t, r.created, created)
	testing.expect_value(t, state.tab_indicator.count, 2)
	// The hold is bounded: a window that never joins releases the decorations.
	state.focus_ring.pending_since = time.tick_add(state.focus_ring.pending_since, -time.Second)
	mac.focus_ring_tick(&state)
	testing.expect_value(t, state.tab_indicator.count, 0)
	testing.expect(t, w.opening.phase == .Pending)
}
