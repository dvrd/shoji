package tests

import e "../src/engine"
import mac "../src/macos"
import "core:testing"
import "core:time"

@(test)
desktop_swipe_suppresses_tiling_until_settled :: proc(t: ^testing.T) {
	state: mac.State;r: Recorder;fixture(&state.manager, &r)
	defer e.manager_destroy(&state.manager);defer delete(r.actions)
	// Public CGEvent setters cannot fabricate the private Dock-swipe fields.
	// Exercise the extracted record path without posting a real gesture.
	now := time.now()
	mac.mouse_gesture_record(&state, 23, 1, 1, now)
	testing.expect(t, state.manager.gesture_active)
	testing.expect_value(t, e.flush(&state.manager, state.manager.spaces[0]), "")
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
	testing.expect_value(t, e.flush(&state.manager, state.manager.spaces[0]), "")
	testing.expect(t, len(r.actions) > 0)
}

@(test)
cross_space_mouse_stack_commits_only_after_transport_success :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	s := e.add_space(&m, 200, 10, 2, {0, 0, 1000, 800})
	w := e.add_window(
		&m,
		e.Window {
			id = 3,
			role = "AXWindow",
			subrole = "AXStandardWindow",
			space = 200,
			display = 10,
			frame = {0, 0, 1000, 800},
		},
	)
	m.mouse.drop_stack = true
	d := e.mouse_begin(&m, 1, .Move, {0, 0})
	r.fail = true
	testing.expect(t, e.mouse_drop(&m, d, 3, {500, 400}) != "")
	testing.expect_value(t, m.windows[1].space, u64(100))
	r.fail = false
	testing.expect_value(t, e.mouse_drop(&m, d, 3, {500, 400}), "")
	testing.expect_value(t, m.windows[1].space, w.space)
	testing.expect_value(t, e.find(s.view.root, 3).count, 2)
	testing.expect(t, e.find(e.space_by_id(&m, 100).view.root, 1) == nil)
}

@(test)
mouse_settings_validate_and_preserve_state :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r);defer e.manager_destroy(&m);defer delete(r.actions)
	testing.expect_value(t, e.config(&m, []string{"mouse_modifier"}).text, "fn")
	pairs := [][2]string {
		{"mouse_modifier", "alt"},
		{"mouse_action1", "resize"},
		{"mouse_action2", "none"},
		{"mouse_drop_action", "stack"},
		{"focus_follows_mouse", "autoraise"},
		{"mouse_follows_focus", "on"},
	}
	for &pair in pairs {
		testing.expect(t, !e.config(&m, pair[:]).failed)
		testing.expect_value(t, e.config(&m, pair[:1]).text, pair[1])
		testing.expect(t, e.config(&m, []string{pair[0], "invalid"}).failed)
		testing.expect_value(t, e.config(&m, pair[:1]).text, pair[1])
	}
	testing.expect(t, e.config(&m, []string{"--space", "1", "mouse_modifier", "cmd"}).failed)
	testing.expect_value(t, len(r.actions), 0)
}
@(test)
mouse_resize_preserves_opposite_edges :: proc(t: ^testing.T) {
	d := e.Mouse_Drag {
		action = .Resize,
		origin = {100, 100},
		frame  = {100, 100, 400, 300},
		left   = true,
		top    = true,
	}
	testing.expect_value(t, e.mouse_drag_frame(d, {150, 130}), e.Rect{150, 130, 350, 270})
	testing.expect_value(t, e.mouse_drag_frame(d, {1000, 1000}), e.Rect{499, 399, 1, 1})
	d.left = false;d.top = false
	testing.expect_value(t, e.mouse_drag_frame(d, {150, 130}), e.Rect{100, 100, 450, 330})
	d.action = .Move
	testing.expect_value(t, e.mouse_drag_frame(d, {50, 75}), e.Rect{50, 75, 400, 300})
}
@(test)
mouse_drop_regions_match_upstream_geometry :: proc(t: ^testing.T) {
	frame := e.Rect{10, 20, 800, 400}
	testing.expect_value(t, e.mouse_drop_region(frame, {410, 220}, false, 1), e.Mouse_Drop.Swap)
	testing.expect_value(t, e.mouse_drop_region(frame, {410, 220}, true, 1), e.Mouse_Drop.Stack)
	points := []e.Mouse_Point{{410, 30}, {800, 220}, {410, 410}, {20, 220}, {0, 0}}
	expected := []e.Mouse_Drop{.North, .East, .South, .West, .None}
	for point, i in points {testing.expect_value(
			t,
			e.mouse_drop_region(frame, point, false, 1),
			expected[i],
		)}
}
@(test)
mouse_floating_drag_reports_failure_without_model_update :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r);defer e.manager_destroy(&m);defer delete(r.actions)
	s := e.space_by_id(&m, 100);e.set_layout(&m, s, .Float)
	w := m.windows[1];w.frame = {0, 0, 100, 100}
	d := e.mouse_begin(&m, 1, .Move, {10, 10})
	r.fail = true
	testing.expect(t, e.mouse_update(&m, &d, {50, 50}) != "")
	testing.expect_value(t, w.frame, e.Rect{0, 0, 100, 100})
	r.fail = false
	testing.expect_value(t, e.mouse_update(&m, &d, {50, 50}), "")
	testing.expect_value(t, w.frame, e.Rect{40, 40, 100, 100})
	w.fullscreen = true
	testing.expect_value(t, e.mouse_begin(&m, 1, .Resize, {0, 0}).window, u32(0))
}
@(test)
mouse_bsp_resize_and_drop_preserve_membership :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r);defer e.manager_destroy(&m);defer delete(r.actions)
	s := e.space_by_id(&m, 100);s.view.split = .Vertical;e.flush(&m, s)
	w :=
		m.windows[1];d := e.mouse_begin(&m, 1, .Resize, {w.frame.x + w.frame.w - 1, w.frame.y + 1})
	n := e.find(s.view.root, 1)
	testing.expect(t, e.mouse_fence(n, .Vertical, false) == s.view.root)
	testing.expect(t, e.mouse_fence(n, .Vertical, true) == nil)
	testing.expect_value(t, e.mouse_update(&m, &d, {d.origin.x + 100, d.origin.y}), "")
	testing.expect(t, s.view.root.ratio > 0.5)
	d = e.mouse_begin(&m, 1, .Move, {0, 0})
	target :=
		m.windows[2];center := e.Mouse_Point{target.frame.x + target.frame.w / 2, target.frame.y + target.frame.h / 2}
	m.mouse.drop_stack = true
	testing.expect_value(t, e.mouse_drop(&m, d, 2, center), "")
	testing.expect_value(t, e.find(s.view.root, 2).count, 2)
	testing.expect(t, e.find(s.view.root, 1) == e.find(s.view.root, 2))
}
foreign import test_cg "system:CoreGraphics.framework"
@(default_calling_convention = "c")
foreign test_cg {
	CGEventCreateMouseEvent :: proc(source: mac.Ref, type: u32, point: mac.Point, button: u32) -> mac.Ref ---
	CGEventSetFlags :: proc(event: mac.Ref, flags: u64) ---
	CGEventSetIntegerValueField :: proc(event: mac.Ref, field: u32, value: i64) ---
}
// These synthetic events are passed directly to our callback, never posted to macOS.
@(test)
mouse_event_capture_coalesces_drag_and_releases_up :: proc(t: ^testing.T) {
	state: mac.State;r: Recorder;fixture(&state.manager, &r)
	defer e.manager_destroy(&state.manager);defer delete(r.actions)
	e.set_layout(&state.manager, e.space_by_id(&state.manager, 100), .Float)
	state.manager.windows[1].frame = {0, 0, 100, 100}
	down := CGEventCreateMouseEvent(nil, 1, {10, 10}, 0);defer mac.CFRelease(down)
	CGEventSetIntegerValueField(down, 91, 1)
	testing.expect(t, mac.mouse_callback(nil, 1, down, &state) == down)
	CGEventSetFlags(down, state.manager.mouse.modifier)
	testing.expect(t, mac.mouse_callback(nil, 1, down, &state) == nil)
	drag := CGEventCreateMouseEvent(nil, 6, {40, 50}, 0);defer mac.CFRelease(drag)
	testing.expect(t, mac.mouse_callback(nil, 6, drag, &state) == nil)
	testing.expect_value(t, len(r.actions), 0)
	mac.mouse_tick(&state)
	testing.expect_value(t, state.manager.windows[1].frame, e.Rect{30, 40, 100, 100})
	up := CGEventCreateMouseEvent(nil, 2, {40, 50}, 0);defer mac.CFRelease(up)
	testing.expect(t, mac.mouse_callback(nil, 2, up, &state) == nil)
	mac.mouse_tick(&state)
	testing.expect_value(t, state.mouse.drag.window, u32(0))
	testing.expect(t, state.mouse.down == nil)
}

@(test)
window_resize_handles_work_in_float_layout :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r);defer e.manager_destroy(&m);defer delete(r.actions)
	e.set_layout(&m, e.space_by_id(&m, 100), .Float)
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
	expected := []e.Rect {
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
		testing.expect_value(t, e.resize_window(&m, w, name, 10, 20), "")
		testing.expect_value(t, w.frame, expected[i])
	}
	testing.expect(t, e.resize_window(&m, w, "bogus", 0, 0) != "")
	testing.expect(t, !e.window_command(&m, []string{"1", "--move", "abs:42:84"}).failed)
	testing.expect_value(t, w.frame.x, f64(42));testing.expect_value(t, w.frame.y, f64(84))
}
