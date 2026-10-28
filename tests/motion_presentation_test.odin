package tests

import e "../src/engine"
import mac "../src/macos"
import "core:testing"
import "core:time"

Motion_Recorder :: struct {
	frame: e.Rect,
	applied, presented, destroyed: int,
	geometry_batched, cover_batched: bool,
	alpha: f64,
}
motion_apply :: proc(state: ^mac.State, window: u32, frame: e.Rect) -> string {
	r := (^Motion_Recorder)(state.event_user)
	mac.resize_cover_frame(state, window, frame, r.frame, 10)
	r.frame, r.geometry_batched = frame, state.frame_updates.depth > 0
	r.applied += 1
	return ""
}
motion_cover_create :: proc(
	_: ^mac.State,
	_: u32,
	frame: e.Rect,
) -> (
	mac.Owned_Surface,
	string,
) { return {id = 900, frame = frame}, "" }
motion_cover_update :: proc(
	state: ^mac.State,
	_: mac.Owned_Surface,
	_: u32,
	_: e.Rect,
	alpha: f64,
	_: bool,
) -> string {
	r := (^Motion_Recorder)(state.event_user)
	r.presented += 1
	r.alpha, r.cover_batched = alpha, state.frame_updates.depth > 0
	return ""
}
motion_cover_destroy :: proc(state: ^mac.State, _: mac.Owned_Surface) {
	(^Motion_Recorder)(state.event_user).destroyed += 1
}
motion_cover_bounds :: proc(state: ^mac.State, _: u32) -> (e.Rect, bool) {
	return (^Motion_Recorder)(state.event_user).frame, true
}

@(test)
three_finger_drag_uses_the_display_presentation_batch :: proc(t: ^testing.T) {
	state: mac.State; actions: Recorder; updates: Frame_Update_Recorder
	fixture(&state.manager, &actions)
	defer e.manager_destroy(&state.manager); defer delete(actions.actions)
	defer delete(updates.enabled)
	e.execute(&state.manager, {"space", "--layout", "scroll"})
	state.manager.spaces[0].view.scroll.dragging = true
	state.frame_updates.user, state.frame_updates.set_enabled = &updates, frame_update_set
	testing.expect(t, mac.motion_active(&state))
	mac.motion_frame_tick(&state, true, time.now(), 0)
	testing.expect_value(t, len(updates.enabled), 2)
	testing.expect_value(t, state.frame_updates.depth, 0)
}

@(test)
display_pulse_coordinates_bsp_geometry_and_contents_in_one_batch :: proc(
	t: ^testing.T,
) {
	state: mac.State; actions: Recorder; r := Motion_Recorder {
		frame = {0, 0, 500, 800},
	}; updates: Frame_Update_Recorder
	fixture(&state.manager, &actions)
	defer e.manager_destroy(&state.manager); defer delete(actions.actions)
	defer delete(updates.enabled)
	defer mac.animation_stop(&state); defer mac.resize_cover_stop(&state)
	state.event_user = &r; state.manager.resize_fade = true
	state.manager.animation_easing = .Linear
	state.manager.windows[1].frame = r.frame
	state.animation_backend = {
		create = proxy_create,
		apply  = motion_apply,
	}
	state.resize_cover_backend = {
		motion_cover_create,
		motion_cover_update,
		motion_cover_destroy,
		motion_cover_bounds,
	}
	state.frame_updates.user, state.frame_updates.set_enabled =
		&updates, frame_update_set
	began := time.now()
	mac.animation_start_at(
		&state,
		{
			window = 1,
			frame = {0, 0, 900, 800},
			duration = 1,
			live_resize = true,
		},
		began,
	)
	testing.expect(t, mac.motion_active(&state))
	mac.motion_frame_tick(
		&state,
		false,
		time.time_add(began, 400 * time.Millisecond),
		10,
	)
	testing.expect_value(t, r.applied, 0)
	mac.motion_frame_tick(
		&state,
		true,
		time.time_add(began, 500 * time.Millisecond),
		10.01,
	)
	testing.expect_value(t, r.frame.w, f64(700))
	testing.expect_value(t, r.alpha, f64(.5))
	testing.expect_value(t, r.presented, 1)
	testing.expect(t, r.geometry_batched && r.cover_batched)
	testing.expect_value(t, len(updates.enabled), 2)
	testing.expect_value(t, state.frame_updates.depth, 0)
	middle := time.time_add(began, 500 * time.Millisecond)
	mac.animation_start_at(
		&state,
		{
			window = 1,
			frame = {0, 0, 400, 800},
			duration = 1,
			live_resize = true,
		},
		middle,
	)
	mac.motion_frame_tick(
		&state,
		true,
		time.time_add(middle, 50 * time.Millisecond),
		10.06,
	)
	testing.expect(t, r.alpha > .524 && r.alpha < .526)
	mac.motion_frame_tick(
		&state,
		true,
		time.time_add(middle, time.Second),
		11.01,
	)
	testing.expect_value(t, len(state.resize_covers), 0)
	testing.expect_value(t, r.destroyed, 1)
	testing.expect_value(t, state.frame_updates.depth, 0)
	testing.expect(t, !mac.motion_active(&state))
}
