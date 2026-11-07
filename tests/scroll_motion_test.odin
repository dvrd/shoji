package tests

import mac "../src"
import "core:math"
import "core:testing"
import "core:time"
import layout "../src/layout"

foreign import motion_test_cg "system:CoreGraphics.framework"
foreign motion_test_cg {
	CGEventSetTimestamp :: proc "c" (event: mac.Ref, timestamp: u64) ---
}

@(test)
scroll_keyboard_pan_begins_at_rendered_strip_without_independent_window_animations :: proc(
	t: ^testing.T,
) {
	m: mac.Manager; r: Recorder; niri_fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	mac.execute(&m, {"window", "1", "--focus"})
	before := m.windows[2].frame
	testing.expect(
		t,
		!mac.execute(&m, {"config", "scroll_animation", "on"}).failed,
	)
	m.animation_duration = 0.18
	resize(&r.actions, 0)
	mac.execute(&m, {"window", "3", "--focus"})
	testing.expect_value(t, m.focused, u32(3))
	testing.expect_value(t, m.windows[2].frame, before)
	for a in r.actions {
		if a.kind == .Frame {
			testing.expect_value(t, a.duration, f64(0))
		}
	}
}

@(test)
scroll_release_matches_pinned_snap_and_directional_focus_examples :: proc(
	t: ^testing.T,
) {
	m: mac.Manager; r: Recorder; niri_fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	cases := [5]struct {
		position, velocity, target: f64,
		window: u32,
	} {
		{100, 100, -16, 2},
		{400, -100, 616, 2},
		{300, 1000, 616, 3},
		{300, -1000, -16, 1},
		{300, 0, -16, 2},
	}
	for c in cases {
		snap := mac.scroll_snap_target(&m.spaces[0].view, c.position, c.velocity)
		testing.expect_value(t, snap.offset, c.target)
		testing.expect_value(t, snap.window, c.window)
	}
	mac.execute(&m, {"config", "scroll_center_focused_column", "always"})
	snap := mac.scroll_snap_target(&m.spaces[0].view, 300, 0)
	testing.expect_value(t, snap.offset, f64(300))
	testing.expect_value(t, snap.window, u32(2))
}

@(test)
scroll_shared_spring_preserves_visible_spacing_and_ends_exactly :: proc(
	t: ^testing.T,
) {
	m: mac.Manager; r: Recorder; niri_fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	mac.execute(&m, {"window", "1", "--focus"})
	mac.execute(&m, {"config", "scroll_animation", "on"})
	m.animation_duration = 0.5
	mac.execute(&m, {"window", "3", "--focus"})
	for at in ([4]f64{0.04, 0.08, 0.12, 0.2}) {
		testing.expect_value(t, mac.scroll_motion_tick(&m, at), "")
		testing.expect(
			t,
			math.abs(m.windows[3].frame.x - m.windows[2].frame.x - 632) < 1e-9,
		)
		testing.expect_value(t, m.windows[2].frame.w, f64(616))
	}
	testing.expect_value(t, mac.scroll_motion_tick(&m, 0.4), "")
	testing.expect_value(t, m.windows[3].frame.x, f64(648))
	testing.expect(t, !m.spaces[0].view.scroll.motion.active)
}

@(test)
scroll_retarget_and_gesture_takeover_preserve_current_position :: proc(
	t: ^testing.T,
) {
	m: mac.Manager; r: Recorder; niri_fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	mac.execute(&m, {"window", "1", "--focus"})
	mac.execute(&m, {"config", "scroll_animation", "on"})
	m.animation_duration = 0.5
	mac.execute(&m, {"window", "3", "--focus"})
	mac.scroll_motion_tick(&m, 0.08)
	s := m.spaces[0]
	position, velocity :=
		s.view.scroll.motion.position, s.view.scroll.motion.velocity
	mac.execute(&m, {"window", "1", "--focus"})
	testing.expect_value(t, s.view.scroll.motion.position, position)
	testing.expect_value(t, s.view.scroll.motion.initial_velocity, velocity)
	mac.scroll_begin_pan(&m, s)
	testing.expect_value(t, s.view.scroll.offset, position)
	mac.scroll_gesture_pan(&m, s.id, 20)
	testing.expect_value(t, s.view.scroll.motion.position, position + 20)
	testing.expect_value(t, m.focused, u32(1))
}

@(test)
scroll_release_focus_is_immediate_while_camera_settles :: proc(t: ^testing.T) {
	m: mac.Manager; r: Recorder; niri_fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	mac.execute(&m, {"config", "scroll_animation", "on"})
	m.animation_duration = 0.5
	s := m.spaces[0]
	mac.scroll_begin_pan(&m, s)
	mac.scroll_gesture_pan(&m, s.id, -516)
	testing.expect_value(t, s.view.scroll.offset, f64(100))
	testing.expect_value(t, mac.scroll_finish_pan(&m, s, 100), "")
	testing.expect_value(t, m.focused, u32(2))
	testing.expect_value(t, s.view.scroll.offset, f64(-16))
	testing.expect_value(t, s.view.scroll.motion.position, f64(100))
	testing.expect_value(t, s.view.scroll.motion.initial_velocity, f64(100))
	testing.expect_value(t, mac.scroll_motion_tick(&m, 0.4), "")
	testing.expect_value(t, s.view.scroll.motion.position, f64(-16))
}

@(test)
scroll_velocity_accounts_for_pause_and_ignores_out_of_order_samples :: proc(
	t: ^testing.T,
) {
	v: mac.Scroll_Velocity
	mac.scroll_velocity_add(&v, 0, 0)
	mac.scroll_velocity_add(&v, 10, 0.01)
	testing.expect(t, math.abs(mac.scroll_velocity_get(&v) - 1000) < 0.001)
	mac.scroll_velocity_add(&v, 999, 0.005)
	testing.expect_value(t, v.position, f64(10))
	mac.scroll_velocity_add(&v, 0, 0.2)
	testing.expect_value(t, mac.scroll_velocity_get(&v), f64(0))
}

@(test)
scroll_pointer_stays_fixed_unless_explicitly_enabled :: proc(t: ^testing.T) {
	m: mac.Manager; r: Recorder; niri_fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	m.mouse.follows_focus = true
	testing.expect(t, !mac.pointer_follows_focus(&m, m.windows[1]))
	mac.execute(&m, {"config", "scroll_warp_pointer", "on"})
	testing.expect(t, mac.pointer_follows_focus(&m, m.windows[1]))
	mac.set_layout(&m, m.spaces[0], .BSP)
	testing.expect(t, mac.pointer_follows_focus(&m, m.windows[1]))
}

@(test)
scroll_animated_camera_rebases_when_an_earlier_column_resizes_or_disappears :: proc(
	t: ^testing.T,
) {
	m: mac.Manager; r: Recorder; niri_fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	mac.execute(&m, {"config", "scroll_animation", "on"})
	m.animation_duration = 0.5
	s := m.spaces[0]
	layout.find(s.view.root, 1).column_width = 700
	mac.flush(&m, s)
	testing.expect_value(t, m.windows[3].frame.x, f64(648))
	testing.expect(t, s.view.scroll.motion.active)
	mac.scroll_motion_tick(&m, 0.4)
	testing.expect_value(t, m.windows[3].frame.x, f64(648))
	mac.remove_window(&m, 1); mac.flush(&m, s)
	testing.expect_value(t, m.windows[3].frame.x, f64(648))
	testing.expect(t, s.view.scroll.motion.active)
	mac.scroll_motion_tick(&m, 0.8)
	testing.expect_value(t, m.windows[3].frame.x, f64(648))
}

@(test)
scroll_failed_release_focus_keeps_logical_focus_and_releases_drag :: proc(
	t: ^testing.T,
) {
	m: mac.Manager; r: Recorder; niri_fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	mac.execute(&m, {"config", "scroll_animation", "on"})
	m.animation_duration = 0.5
	s := m.spaces[0]
	mac.scroll_begin_pan(&m, s); mac.scroll_gesture_pan(&m, s.id, -516)
	r.fail = true
	testing.expect(t, mac.scroll_finish_pan(&m, s, 100) != "")
	testing.expect_value(t, m.focused, u32(3))
	testing.expect(t, !s.view.scroll.dragging)
	testing.expect_value(t, s.view.scroll.offset, f64(100))
}

@(test)
native_scroll_input_releases_to_shared_spring_and_discards_native_momentum :: proc(
	t: ^testing.T,
) {
	state: mac.State; r: Recorder; niri_fixture(&state.manager, &r)
	m := &state.manager
	defer mac.manager_destroy(m); defer delete(r.actions)
	niri_open(m, 2); niri_open(m, 3)
	mac.execute(m, {"window", "1", "--focus"})
	mac.execute(m, {"config", "scroll_animation", "on"})
	m.animation_duration, m.scroll_time, m.mouse.scroll = 0.5, 1.05, true
	event := CGEventCreateScrollWheelEvent(nil, 0, 2, 0, i32(-120))
	testing.expect(t, event != nil)
	if event == nil {
		return
	}
	defer mac.CFRelease(event)
	CGEventSetLocation(event, {10, 10})
	CGEventSetFlags(event, m.mouse.modifier)
	CGEventSetIntegerValueField(event, 88, 1)
	CGEventSetIntegerValueField(event, 96, 0)
	CGEventSetIntegerValueField(event, 97, -120)
	CGEventSetIntegerValueField(event, 99, 1)
	CGEventSetTimestamp(event, 1_000_000_000)
	testing.expect_value(
		t,
		mac.mouse_callback(nil, 22, event, &state),
		mac.Ref(nil),
	)
	CGEventSetIntegerValueField(event, 99, 2)
	CGEventSetTimestamp(event, 1_050_000_000)
	mac.mouse_callback(nil, 22, event, &state)
	mac.scroll_input_tick(&state, time.now())
	testing.expect_value(t, m.spaces[0].view.scroll.offset, f64(240))
	testing.expect(t, m.spaces[0].view.scroll.dragging)
	CGEventSetIntegerValueField(event, 99, 4)
	CGEventSetIntegerValueField(event, 97, 0)
	CGEventSetTimestamp(event, 1_100_000_000)
	mac.mouse_callback(nil, 22, event, &state)
	mac.scroll_input_tick(&state, time.now())
	testing.expect_value(t, m.focused, u32(3))
	testing.expect_value(t, m.spaces[0].view.scroll.offset, f64(616))
	testing.expect(t, m.spaces[0].view.scroll.motion.active)
	testing.expect(t, !m.spaces[0].view.scroll.dragging)
	CGEventSetFlags(event, 0)
	CGEventSetIntegerValueField(event, 99, 0)
	CGEventSetIntegerValueField(event, 123, 1)
	CGEventSetIntegerValueField(event, 97, -300)
	CGEventSetTimestamp(event, 1_110_000_000)
	testing.expect_value(
		t,
		mac.mouse_callback(nil, 22, event, &state),
		mac.Ref(nil),
	)
	testing.expect_value(t, state.mouse.scroll_delta, f64(0))
	testing.expect(t, !state.mouse.scroll_tracking)
	mac.scroll_motion_tick(m, 1.5)
	testing.expect_value(t, m.windows[3].frame.x, f64(648))
}

@(test)
scroll_rediscovery_waits_for_camera_and_resumes_after_settling :: proc(
	t: ^testing.T,
) {
	state: mac.State; r: Recorder; fixture(&state.manager, &r)
	defer mac.manager_destroy(&state.manager); defer delete(r.actions)
	state.event_user = &r
	mac.set_layout(&state.manager, state.manager.spaces[0], .Scroll)
	mac.flush(&state.manager, state.manager.spaces[0])
	r.calls = 0
	state.manager.spaces[0].view.scroll.motion.active = true
	state.dirty = true
	last := time.now()
	mac.desktop_refresh_tick(
		&state,
		&last,
		time.time_add(last, time.Second),
		resize_collect,
	)
	testing.expect_value(t, r.calls, 0)
	state.manager.spaces[0].view.scroll.motion.active = false
	mac.desktop_refresh_tick(
		&state,
		&last,
		time.time_add(last, time.Second),
		resize_collect,
	)
	testing.expect_value(t, r.calls, 1)
}
