package tests

import mac "../src"
import "core:testing"
import "core:time"

@(test)
three_finger_stack_swipe_tracks_direction_and_latches_until_release :: proc(t: ^testing.T) {
	tracker: mac.Stack_Swipe_Tracker
	contacts: [3]mac.Touch_Contact
	for &c, i in contacts { c.id = i32(i + 1); c.stage = 4; c.normalized.position = {.5, .4} }
	mac.stack_swipe_sample(&tracker, contacts[:], 1)
	testing.expect(t, tracker.active && tracker.pending == 0)
	for &c in contacts { c.normalized.position.y = .48 }
	mac.stack_swipe_sample(&tracker, contacts[:], 1.1)
	testing.expect_value(t, tracker.pending, i32(-1))
	tracker.pending = 0
	for &c in contacts { c.normalized.position.y = .3 }
	mac.stack_swipe_sample(&tracker, contacts[:], 1.2)
	testing.expect_value(t, tracker.pending, i32(0))
	mac.stack_swipe_sample(&tracker, nil, 1.3)
	mac.stack_swipe_sample(&tracker, contacts[:], 2)
	for &c in contacts { c.normalized.position.y = .2 }
	mac.stack_swipe_sample(&tracker, contacts[:], 2.1)
	testing.expect_value(t, tracker.pending, i32(1))
	mac.stack_swipe_sample(&tracker, nil, 2.2)
	tracker.pending = 0
	mac.stack_swipe_sample(&tracker, contacts[:], 3)
	contacts[0].id = 9
	mac.stack_swipe_sample(&tracker, contacts[:], 3.1)
	for &c in contacts { c.normalized.position.y = .4 }
	mac.stack_swipe_sample(&tracker, contacts[:], 3.2)
	testing.expect(t, tracker.blocked && tracker.pending == 0)
}

@(test)
three_finger_horizontal_swipe_tracks_motion_and_release :: proc(t: ^testing.T) {
	tracker: mac.Stack_Swipe_Tracker
	contacts: [3]mac.Touch_Contact
	for &c, i in contacts { c.id = i32(i + 1); c.stage = 4; c.normalized.position = {.5, .5} }
	mac.stack_swipe_sample(&tracker, contacts[:], 1)
	for &c in contacts { c.normalized.position.x = .45 }
	mac.stack_swipe_sample(&tracker, contacts[:], 1.1)
	testing.expect_value(t, tracker.axis, i32(1))
	testing.expect(t, tracker.horizontal_delta < -.049 && tracker.pending == 0)
	tracker.horizontal_delta = 0
	for &c in contacts { c.normalized.position.x = .40 }
	mac.stack_swipe_sample(&tracker, contacts[:], 1.2)
	testing.expect(t, tracker.horizontal_delta < -.049 && tracker.horizontal_velocity < 0)
	mac.stack_swipe_sample(&tracker, contacts[:2], 1.3)
	testing.expect(t, tracker.horizontal_end && tracker.blocked)
	mac.stack_swipe_sample(&tracker, nil, 1.4)
	testing.expect(t, !tracker.active && !tracker.blocked)
}

@(test)
three_finger_horizontal_scroll_starts_and_finishes_pan :: proc(t: ^testing.T) {
	state: mac.State; r: Recorder; niri_fixture(&state.manager, &r)
	defer mac.manager_destroy(&state.manager); defer delete(r.actions)
	niri_open(&state.manager, 2); niri_open(&state.manager, 3)
	mac.execute(&state.manager, {"window", "1", "--focus"})
	s := state.manager.spaces[0]
	state.stack_touch.horizontal_space = s.id
	state.stack_touch.horizontal_layout = .Scroll
	before := s.view.scroll.offset
	mac.stack_touch_horizontal(&state, -.1, -.5, false)
	testing.expect(t, state.stack_touch.horizontal_active && s.view.scroll.dragging)
	testing.expect(t, s.view.scroll.offset > before)
	mac.stack_touch_horizontal(&state, 0, 0, true)
	testing.expect(t, !state.stack_touch.horizontal_active && !s.view.scroll.dragging)
}

@(test)
three_finger_slow_release_focuses_first_visible_column_at_left_edge :: proc(t: ^testing.T) {
	state: mac.State; r: Recorder; niri_fixture(&state.manager, &r)
	defer mac.manager_destroy(&state.manager); defer delete(r.actions)
	niri_open(&state.manager, 2); niri_open(&state.manager, 3)
	mac.execute(&state.manager, {"window", "1", "--focus"})
	mac.execute(&state.manager, {"window", "2", "--focus"})
	s := state.manager.spaces[0]
	state.stack_touch.horizontal_space = s.id
	state.stack_touch.horizontal_layout = .Scroll
	mac.stack_touch_horizontal(&state, .1, 0, false)
	mac.stack_touch_horizontal(&state, 0, 0, true)
	testing.expect_value(t, state.manager.focused, u32(1))
}

@(test)
three_finger_release_settles_without_spring_overshoot :: proc(t: ^testing.T) {
	state: mac.State; r: Recorder; niri_fixture(&state.manager, &r)
	defer mac.manager_destroy(&state.manager); defer delete(r.actions)
	niri_open(&state.manager, 2); niri_open(&state.manager, 3)
	mac.execute(&state.manager, {"config", "scroll_animation", "on"})
	mac.execute(&state.manager, {"window", "1", "--focus"})
	state.manager.animation_duration = .2
	s := state.manager.spaces[0]
	state.stack_touch.horizontal_space = s.id
	state.stack_touch.horizontal_layout = .Scroll
	mac.stack_touch_horizontal(&state, -.1, -8, false)
	position := s.view.scroll.motion.position
	mac.stack_touch_horizontal(&state, 0, -8, true)
	target := s.view.scroll.motion.target
	for i in 1 ..= 32 {
		mac.scroll_motion_sample(&s.view.scroll.motion, s.view.scroll.motion.began + f64(i) / 120)
		x := s.view.scroll.motion.position
		testing.expect(t, x >= min(position, target) - .001 && x <= max(position, target) + .001)
	}
}

@(test)
three_finger_swipes_select_each_adjacent_column :: proc(t: ^testing.T) {
	state: mac.State; r: Recorder; niri_fixture(&state.manager, &r)
	defer mac.manager_destroy(&state.manager); defer delete(r.actions)
	niri_open(&state.manager, 2); niri_open(&state.manager, 3)
	mac.execute(&state.manager, {"window", "1", "--column-width", "abs:900"})
	mac.execute(&state.manager, {"window", "1", "--focus"})
	s := state.manager.spaces[0]
	state.stack_touch.horizontal_space = s.id
	state.stack_touch.horizontal_layout = .Scroll
	mac.stack_touch_horizontal(&state, -.04, -3, false)
	mac.stack_touch_horizontal(&state, 0, -3, true)
	testing.expect_value(t, state.manager.focused, u32(2))
	state.stack_touch.horizontal_travel = 0
	mac.stack_touch_horizontal(&state, -.04, -3, false)
	mac.stack_touch_horizontal(&state, 0, -3, true)
	testing.expect_value(t, state.manager.focused, u32(3))
	state.stack_touch.horizontal_travel = 0
	mac.stack_touch_horizontal(&state, .04, 3, false)
	mac.stack_touch_horizontal(&state, 0, 3, true)
	testing.expect_value(t, state.manager.focused, u32(2))
}

@(test)
three_finger_horizontal_bsp_switches_once_and_wraps :: proc(t: ^testing.T) {
	state: mac.State; r: Recorder; fixture(&state.manager, &r)
	defer mac.manager_destroy(&state.manager); defer delete(r.actions)
	mac.add_space(&state.manager, 200, 10, 2, {0, 0, 1000, 800})
	state.stack_touch.horizontal_space = 100
	state.stack_touch.horizontal_layout = .BSP
	resize(&r.actions, 0)
	mac.stack_touch_horizontal(&state, -.04, 0, false)
	testing.expect_value(t, len(r.actions), 0)
	mac.stack_touch_horizontal(&state, -.05, 0, false)
	testing.expect_value(t, len(r.actions), 1)
	if len(r.actions) > 0 {
		testing.expect_value(t, r.actions[0].kind, mac.Action_Kind.Space_Focus)
		testing.expect_value(t, r.actions[0].space, u64(200))
	}
	mac.stack_touch_horizontal(&state, -.1, 0, false)
	testing.expect_value(t, len(r.actions), 1)
	state.stack_touch.horizontal_switched = false
	state.stack_touch.horizontal_travel = 0
	resize(&r.actions, 0)
	mac.stack_touch_horizontal(&state, .1, 0, false)
	testing.expect_value(t, len(r.actions), 1)
	if len(r.actions) > 0 { testing.expect_value(t, r.actions[0].space, u64(200)) }
}

@(test)
stack_swipe_focuses_only_valid_bsp_stack_members :: proc(t: ^testing.T) {
	state: mac.State; r: Recorder; fixture(&state.manager, &r)
	defer mac.manager_destroy(&state.manager); defer delete(r.actions)
	mac.execute(&state.manager, {"window", "1", "--stack", "2"})
	mac.focus_window(&state.manager, 1)
	w := state.manager.windows[1]
	mac.stack_swipe_apply(&state, w.id, w.generation + 1, 1)
	testing.expect_value(t, state.manager.focused, u32(1))
	mac.stack_swipe_apply(&state, w.id, w.generation, 1)
	testing.expect_value(t, state.manager.focused, u32(2))
	mac.stack_swipe_apply(&state, w.id, w.generation, -1)
	testing.expect_value(t, state.manager.focused, u32(2))
	w = state.manager.windows[2]
	mac.stack_swipe_apply(&state, w.id, w.generation, -1)
	testing.expect_value(t, state.manager.focused, u32(1))
	state.manager.gesture_active = true
	w = state.manager.windows[1]
	mac.stack_swipe_apply(&state, w.id, w.generation, 1)
	testing.expect_value(t, state.manager.focused, u32(1))
}

@(test)
desktop_swipe_suppresses_tiling_until_settled :: proc(t: ^testing.T) {
	state: mac.State;r: Recorder;fixture(&state.manager, &r)
	defer mac.manager_destroy(&state.manager);defer delete(r.actions)
	// Public CGEvent setters cannot fabricate the private Dock-swipe fields.
	// Exercise the extracted record path without posting a real gesture.
	now := time.now()
	mac.mouse_gesture_record(&state, 23, 1, 1, now)
	testing.expect(t, state.manager.gesture_active)
	testing.expect_value(t, mac.flush(&state.manager, state.manager.spaces[0]), "")
	testing.expect_value(t, len(r.actions), 0)
	mac.mouse_gesture_record(&state, 23, 1, 4, now)
	mac.mouse_gesture_tick(
		&state,
		time.time_add(state.mouse.gesture_ended, 100 * time.Millisecond),
	)
	testing.expect(t, state.manager.gesture_active)
	mac.mouse_gesture_tick(
		&state,
		time.time_add(state.mouse.gesture_ended, 300 * time.Millisecond),
	)
	testing.expect(t, !state.manager.gesture_active && state.dirty)
	testing.expect_value(t, mac.flush(&state.manager, state.manager.spaces[0]), "")
	testing.expect(t, len(r.actions) > 0)
}

@(test)
cross_space_mouse_stack_commits_only_after_transport_success :: proc(t: ^testing.T) {
	m: mac.Manager;r: Recorder;fixture(&m, &r)
	defer mac.manager_destroy(&m);defer delete(r.actions)
	s := mac.add_space(&m, 200, 10, 2, {0, 0, 1000, 800})
	w := mac.add_window(
		&m,
		mac.Window {
			id = 3,
			role = "AXWindow",
			subrole = "AXStandardWindow",
			space = 200,
			display = 10,
			frame = {0, 0, 1000, 800},
		},
	)
	m.mouse.drop_stack = true
	d := mac.mouse_begin(&m, 1, .Move, {0, 0})
	r.fail = true
	testing.expect(t, mac.mouse_drop(&m, d, 3, {500, 400}) != "")
	testing.expect_value(t, m.windows[1].space, u64(100))
	r.fail = false
	testing.expect_value(t, mac.mouse_drop(&m, d, 3, {500, 400}), "")
	testing.expect_value(t, m.windows[1].space, w.space)
	testing.expect_value(t, mac.find(s.view.root, 3).count, 2)
	testing.expect(t, mac.find(mac.space_by_id(&m, 100).view.root, 1) == nil)
}

@(test)
mouse_settings_validate_and_preserve_state :: proc(t: ^testing.T) {
	m: mac.Manager;r: Recorder;fixture(&m, &r);defer mac.manager_destroy(&m);defer delete(r.actions)
	testing.expect_value(t, mac.config(&m, []string{"mouse_modifier"}).text, "fn")
	pairs := [][2]string {
		{"mouse_modifier", "alt"},
		{"mouse_action1", "resize"},
		{"mouse_action2", "none"},
		{"mouse_drop_action", "stack"},
		{"focus_follows_mouse", "autoraise"},
		{"mouse_follows_focus", "on"},
	}
	for &pair in pairs {
		testing.expect(t, !mac.config(&m, pair[:]).failed)
		testing.expect_value(t, mac.config(&m, pair[:1]).text, pair[1])
		testing.expect(t, mac.config(&m, []string{pair[0], "invalid"}).failed)
		testing.expect_value(t, mac.config(&m, pair[:1]).text, pair[1])
	}
	testing.expect(t, mac.config(&m, []string{"--space", "1", "mouse_modifier", "cmd"}).failed)
	testing.expect_value(t, len(r.actions), 0)
}
@(test)
mouse_resize_preserves_opposite_edges :: proc(t: ^testing.T) {
	d := mac.Mouse_Drag {
		action = .Resize,
		origin = {100, 100},
		frame  = {100, 100, 400, 300},
		left   = true,
		top    = true,
	}
	testing.expect_value(t, mac.mouse_drag_frame(d, {150, 130}), mac.Rect{150, 130, 350, 270})
	testing.expect_value(t, mac.mouse_drag_frame(d, {1000, 1000}), mac.Rect{499, 399, 1, 1})
	d.left = false;d.top = false
	testing.expect_value(t, mac.mouse_drag_frame(d, {150, 130}), mac.Rect{100, 100, 450, 330})
	d.action = .Move
	testing.expect_value(t, mac.mouse_drag_frame(d, {50, 75}), mac.Rect{50, 75, 400, 300})
}
@(test)
mouse_drop_regions_match_upstream_geometry :: proc(t: ^testing.T) {
	frame := mac.Rect{10, 20, 800, 400}
	testing.expect_value(t, mac.mouse_drop_region(frame, {410, 220}, false, 1), mac.Mouse_Drop.Swap)
	testing.expect_value(t, mac.mouse_drop_region(frame, {410, 220}, true, 1), mac.Mouse_Drop.Stack)
	points := []mac.Mouse_Point{{410, 30}, {800, 220}, {410, 410}, {20, 220}, {0, 0}}
	expected := []mac.Mouse_Drop{.North, .East, .South, .West, .None}
	for point, i in points {testing.expect_value(
			t,
			mac.mouse_drop_region(frame, point, false, 1),
			expected[i],
		)}
}
@(test)
mouse_floating_drag_reports_failure_without_model_update :: proc(t: ^testing.T) {
	m: mac.Manager;r: Recorder;fixture(&m, &r);defer mac.manager_destroy(&m);defer delete(r.actions)
	s := mac.space_by_id(&m, 100);mac.set_layout(&m, s, .Float)
	w := m.windows[1];w.frame = {0, 0, 100, 100}
	d := mac.mouse_begin(&m, 1, .Move, {10, 10})
	r.fail = true
	testing.expect(t, mac.mouse_update(&m, &d, {50, 50}) != "")
	testing.expect_value(t, w.frame, mac.Rect{0, 0, 100, 100})
	r.fail = false
	testing.expect_value(t, mac.mouse_update(&m, &d, {50, 50}), "")
	testing.expect_value(t, w.frame, mac.Rect{40, 40, 100, 100})
	w.fullscreen = true
	testing.expect_value(t, mac.mouse_begin(&m, 1, .Resize, {0, 0}).window, u32(0))
}
@(test)
mouse_bsp_resize_and_drop_preserve_membership :: proc(t: ^testing.T) {
	m: mac.Manager;r: Recorder;fixture(&m, &r);defer mac.manager_destroy(&m);defer delete(r.actions)
	s := mac.space_by_id(&m, 100);s.view.split = .Vertical;mac.flush(&m, s)
	w :=
		m.windows[1];d := mac.mouse_begin(&m, 1, .Resize, {w.frame.x + w.frame.w - 1, w.frame.y + 1})
	n := mac.find(s.view.root, 1)
	testing.expect(t, mac.mouse_fence(n, .Vertical, false) == s.view.root)
	testing.expect(t, mac.mouse_fence(n, .Vertical, true) == nil)
	testing.expect_value(t, mac.mouse_update(&m, &d, {d.origin.x + 100, d.origin.y}), "")
	testing.expect(t, s.view.root.ratio > 0.5)
	d = mac.mouse_begin(&m, 1, .Move, {0, 0})
	target :=
		m.windows[2];center := mac.Mouse_Point{target.frame.x + target.frame.w / 2, target.frame.y + target.frame.h / 2}
	m.mouse.drop_stack = true
	testing.expect_value(t, mac.mouse_drop(&m, d, 2, center), "")
	testing.expect_value(t, mac.find(s.view.root, 2).count, 2)
	testing.expect(t, mac.find(s.view.root, 1) == mac.find(s.view.root, 2))
}
foreign import test_cg "system:CoreGraphics.framework"
@(default_calling_convention = "c")
foreign test_cg {
	CGEventCreateMouseEvent :: proc(source: mac.Ref, type: u32, point: mac.Point, button: u32) -> mac.Ref ---
	CGEventSetFlags :: proc(event: mac.Ref, flags: u64) ---
	CGEventSetIntegerValueField :: proc(event: mac.Ref, field: u32, value: i64) ---
}

@(test)
scroll_double_click_resize_edge_toggles_width_and_resets_row :: proc(t: ^testing.T) {
	state: mac.State; r: Recorder; niri_fixture(&state.manager, &r)
	defer mac.manager_destroy(&state.manager); defer delete(r.actions)
	niri_open(&state.manager, 2)
	mac.execute(&state.manager, {"window", "1", "--stack", "2"})
	mac.execute(&state.manager, {"window", "1", "--row-height", "abs:250"})
	w := state.manager.windows[1]
	n := mac.find(state.manager.spaces[0].view.root, 1)
	frame := w.frame
	down := CGEventCreateMouseEvent(nil, 1, {frame.x + frame.w - 1, frame.y + frame.h / 2}, 0)
	defer mac.CFRelease(down)
	CGEventSetFlags(down, 0); CGEventSetIntegerValueField(down, 91, 1); CGEventSetIntegerValueField(down, 1, 1)
	up := CGEventCreateMouseEvent(nil, 2, {frame.x + frame.w - 1, frame.y + frame.h / 2}, 0)
	defer mac.CFRelease(up)
	testing.expect(t, mac.mouse_callback(nil, 1, down, &state) == down)
	testing.expect(t, mac.mouse_callback(nil, 2, up, &state) == up)
	mac.mouse_tick(&state, false)
	CGEventSetIntegerValueField(down, 1, 2)
	testing.expect(t, mac.mouse_callback(nil, 1, down, &state) == nil)
	mac.mouse_tick(&state, false)
	testing.expect(t, n.column_full)
	testing.expect(t, mac.mouse_callback(nil, 2, up, &state) == nil)
	frame = w.frame
	top := CGEventCreateMouseEvent(nil, 1, {frame.x + frame.w / 2, frame.y + 1}, 0)
	defer mac.CFRelease(top)
	CGEventSetFlags(top, 0); CGEventSetIntegerValueField(top, 91, 1); CGEventSetIntegerValueField(top, 1, 2)
	testing.expect(t, mac.mouse_callback(nil, 1, top, &state) == nil)
	mac.mouse_tick(&state, false)
	testing.expect_value(t, w.row_fixed, f64(0))
	testing.expect_value(t, w.row_weight, f64(1))
	testing.expect(t, mac.mouse_callback(nil, 2, up, &state) == nil)
	frame = w.frame
	right := CGEventCreateMouseEvent(nil, 3, {frame.x + frame.w - 1, frame.y + frame.h / 2}, 1)
	defer mac.CFRelease(right)
	CGEventSetFlags(right, state.manager.mouse.modifier)
	CGEventSetIntegerValueField(right, 91, 1); CGEventSetIntegerValueField(right, 1, 2)
	testing.expect(t, mac.mouse_callback(nil, 3, right, &state) == nil)
	mac.mouse_tick(&state, false)
	testing.expect(t, !n.column_full)
	right_up := CGEventCreateMouseEvent(nil, 4, {frame.x + frame.w - 1, frame.y + frame.h / 2}, 1)
	defer mac.CFRelease(right_up)
	testing.expect(t, mac.mouse_callback(nil, 4, right_up, &state) == nil)
}
// These synthetic events are passed directly to our callback, never posted to macOS.
@(test)
mouse_event_capture_coalesces_drag_and_releases_up :: proc(t: ^testing.T) {
	state: mac.State;r: Recorder;fixture(&state.manager, &r)
	defer mac.manager_destroy(&state.manager);defer delete(r.actions)
	mac.set_layout(&state.manager, mac.space_by_id(&state.manager, 100), .Float)
	state.manager.windows[1].frame = {0, 0, 100, 100}
	down := CGEventCreateMouseEvent(nil, 1, {10, 10}, 0);defer mac.CFRelease(down)
	CGEventSetFlags(down, 0)
	CGEventSetIntegerValueField(down, 91, 1)
	testing.expect(t, mac.mouse_callback(nil, 1, down, &state) == down)
	CGEventSetFlags(down, state.manager.mouse.modifier)
	testing.expect(t, mac.mouse_callback(nil, 1, down, &state) == nil)
	drag := CGEventCreateMouseEvent(nil, 6, {40, 50}, 0);defer mac.CFRelease(drag)
	testing.expect(t, mac.mouse_callback(nil, 6, drag, &state) == nil)
	testing.expect_value(t, len(r.actions), 0)
	mac.mouse_tick(&state)
	testing.expect_value(t, state.manager.windows[1].frame, mac.Rect{30, 40, 100, 100})
	up := CGEventCreateMouseEvent(nil, 2, {40, 50}, 0);defer mac.CFRelease(up)
	testing.expect(t, mac.mouse_callback(nil, 2, up, &state) == nil)
	mac.mouse_tick(&state)
	testing.expect_value(t, state.mouse.drag.window, u32(0))
	testing.expect(t, state.mouse.down == nil)
}

@(test)
window_resize_handles_work_in_float_layout :: proc(t: ^testing.T) {
	m: mac.Manager;r: Recorder;fixture(&m, &r);defer mac.manager_destroy(&m);defer delete(r.actions)
	mac.set_layout(&m, mac.space_by_id(&m, 100), .Float)
	w := m.windows[1]
	names := []string {
		"top_left",
		"top_right",
		"bottom_left",
		"bottom_right",
		"top",
		"bottom",
		"left",
		"right",
	}
	expected := []mac.Rect {
		{10, 20, 90, 80},
		{0, 20, 110, 80},
		{10, 0, 90, 120},
		{0, 0, 110, 120},
		{0, 20, 100, 80},
		{0, 0, 100, 120},
		{10, 0, 90, 100},
		{0, 0, 110, 100},
	}
	for name, i in names {
		w.frame = {0, 0, 100, 100}
		testing.expect_value(t, mac.resize_window(&m, w, name, 10, 20), "")
		testing.expect_value(t, w.frame, expected[i])
	}
	testing.expect(t, mac.resize_window(&m, w, "bogus", 0, 0) != "")
	testing.expect(t, !mac.window_command(&m, []string{"1", "--move", "abs:42:84"}).failed)
	testing.expect_value(t, w.frame.x, f64(42));testing.expect_value(t, w.frame.y, f64(84))
}
