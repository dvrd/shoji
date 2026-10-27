package tests

import e "../src/engine"
import mac "../src/macos"
import "core:testing"
import "core:time"

resize_collect :: proc(state: ^mac.State) {
	r := (^Recorder)(state.event_user)
	r.calls += 1
	state.dirty = false
}

@(test)
native_drag_defers_desktop_rediscovery_and_reconciles_after_release :: proc(
	t: ^testing.T,
) {
	state: mac.State; r: Recorder
	state.event_user = &r
	state.dirty = true
	state.mouse.drag.window = 1
	last := time.now(); before := last
	now := time.time_add(last, 2 * time.Second)
	mac.desktop_refresh_tick(&state, &last, now, resize_collect)
	testing.expect_value(t, r.calls, 0)
	testing.expect_value(t, last, before)
	testing.expect(t, state.dirty)
	state.mouse.drag = {}
	mac.desktop_refresh_tick(&state, &last, now, resize_collect)
	testing.expect_value(t, r.calls, 1)
	testing.expect(t, !state.dirty)
	testing.expect_value(t, last, now)
	mac.desktop_refresh_tick(&state, &last, now, resize_collect)
	testing.expect_value(t, r.calls, 1)
	state.mouse.drag.window = 1; state.mouse.failed = true; state.dirty = true
	mac.desktop_refresh_tick(&state, &last, now, resize_collect)
	testing.expect_value(t, r.calls, 2)
	state.mouse.drag = {}; state.mouse.failed = false; state.dirty = true
	state.animations = make(map[u32]mac.Animation_Job)
	defer delete(state.animations)
	state.animations[1] = {
		presentation = mac.Live_Resize{},
	}
	mac.desktop_refresh_tick(&state, &last, now, resize_collect)
	testing.expect_value(t, r.calls, 2)
	testing.expect(t, state.dirty)
}

resize_hit_test :: proc(state: ^mac.State, point: e.Mouse_Point) -> u32 {
	return 1
}
resize_frame_from_pointer :: proc(
	state: ^mac.State,
	_: u32,
) -> (
	e.Rect,
	bool,
) {
	d := state.mouse.drag; point := state.mouse.point
	if d.lock_x {
		point.x = d.origin.x
	}; if d.lock_y {
		point.y = d.origin.y
	}
	return e.mouse_drag_frame(d, point), true
}

native_resize_observation :: proc(
	state: ^mac.State,
	_: u32,
) -> (
	e.Rect,
	bool,
) {
	return (^e.Rect)(state.event_user)^, true
}

@(test)
native_resize_follows_app_commits_without_writing_back_to_dragged_window :: proc(
	t: ^testing.T,
) {
	state: mac.State; r: Recorder; fixture(&state.manager, &r)
	defer e.manager_destroy(&state.manager); defer delete(r.actions)
	defer mac.mouse_stop(&state)
	m := &state.manager; s := e.space_by_id(m, 100); e.flush(m, s)
	clear(&r.actions)
	accepted := e.Rect{0, 0, 550, 800}
	state.event_user = &accepted; state.mouse.hit_test = resize_hit_test
	state.mouse.resize_frame = native_resize_observation
	down := CGEventCreateMouseEvent(nil, 1, {499, 400}, 0)
	defer mac.CFRelease(down)
	CGEventSetFlags(down, 0)
	testing.expect(t, mac.mouse_callback(nil, 1, down, &state) == down)
	drag := CGEventCreateMouseEvent(nil, 6, {799, 400}, 0)
	defer mac.CFRelease(drag)
	testing.expect(t, mac.mouse_callback(nil, 6, drag, &state) == drag)
	mac.mouse_tick(&state)
	testing.expect_value(t, m.windows[1].frame.w, f64(550))
	testing.expect_value(t, m.windows[2].frame.x, f64(550))
	accepted.w = 450
	mac.mouse_tick(&state)
	testing.expect_value(t, m.windows[2].frame.x, f64(450))
	up := CGEventCreateMouseEvent(nil, 2, {799, 400}, 0)
	defer mac.CFRelease(up)
	testing.expect(t, mac.mouse_callback(nil, 2, up, &state) == up)
	mac.mouse_tick(&state)
	testing.expect_value(t, m.native_resize_window, u32(0))
	for action in r.actions {
		if action.kind == .Frame {
			testing.expect(t, action.window != 1)
		}
	}
}

@(test)
new_edge_drag_interrupts_fill_at_the_current_real_frame :: proc(
	t: ^testing.T,
) {
	state: mac.State; r: Recorder; fixture(&state.manager, &r)
	defer e.manager_destroy(&state.manager); defer delete(r.actions)
	defer mac.mouse_stop(&state)
	e.remove_window(&state.manager, 2)
	e.flush(&state.manager, e.space_by_id(&state.manager, 100))
	state.mouse.hit_test = resize_hit_test
	state.mouse.resize_frame = resize_frame_from_pointer
	state.animations = make(map[u32]mac.Animation_Job)
	defer delete(state.animations)
	state.animations[1] = {
		presentation = mac.Live_Resize{current = {0, 0, 800, 800}},
		target      = {0, 0, 1000, 800},
	}
	down := CGEventCreateMouseEvent(nil, 1, {799, 400}, 0)
	defer mac.CFRelease(down)
	CGEventSetFlags(down, 0)
	testing.expect(t, mac.mouse_callback(nil, 1, down, &state) == down)
	testing.expect_value(t, state.mouse.drag.frame, e.Rect{0, 0, 800, 800})
	testing.expect_value(t, len(state.animations), 0)
	testing.expect_value(t, state.manager.windows[1].frame.w, f64(800))
}

@(test)
single_tile_follows_drag_then_fills_space_on_mouse_release :: proc(
	t: ^testing.T,
) {
	state: mac.State; r: Recorder; fixture(&state.manager, &r)
	defer e.manager_destroy(&state.manager); defer delete(r.actions)
	defer mac.mouse_stop(&state)
	m := &state.manager; s := e.space_by_id(m, 100)
	e.remove_window(m, 2); e.flush(m, s)
	m.animation_duration = 0.18
	state.mouse.hit_test = resize_hit_test
	state.mouse.resize_frame = resize_frame_from_pointer
	down := CGEventCreateMouseEvent(nil, 1, {999, 400}, 0)
	defer mac.CFRelease(down)
	CGEventSetFlags(down, 0)
	testing.expect(t, mac.mouse_callback(nil, 1, down, &state) == down)
	drag := CGEventCreateMouseEvent(nil, 6, {799, 400}, 0)
	defer mac.CFRelease(drag)
	testing.expect(t, mac.mouse_callback(nil, 6, drag, &state) == drag)
	mac.mouse_tick(&state)
	testing.expect_value(t, m.windows[1].frame.w, f64(800))
	for action in r.actions {
		if action.kind == .Frame {
			testing.expect_value(t, action.duration, f64(0))
		}
	}
	clear(&r.actions)
	up := CGEventCreateMouseEvent(nil, 2, {799, 400}, 0)
	defer mac.CFRelease(up)
	testing.expect(t, mac.mouse_callback(nil, 2, up, &state) == up)
	mac.mouse_tick(&state)
	testing.expect_value(t, m.windows[1].frame, e.Rect{0, 0, 1000, 800})
	testing.expect(t, m.windows[1].solo_tile_frame == nil)
	testing.expect(t, !m.windows[1].floating)
	e.flush(m, s)
	testing.expect_value(t, m.windows[1].frame.w, f64(1000))
	for action in r.actions {
		if action.kind == .Frame {
			// Mouse-up processes the final pointer position immediately, then
			// animates the fill using the normal configured duration.
			expected := action.frame.w == 1000 ? f64(0.18) : f64(0)
			testing.expect_value(t, action.duration, expected)
			testing.expect_value(t, action.live_resize, action.frame.w == 1000)
		}
	}
	testing.expect_value(t, m.animation_duration, f64(0.18))
}

@(test)
native_border_click_resolves_missing_event_window_id :: proc(t: ^testing.T) {
	state: mac.State; r: Recorder; fixture(&state.manager, &r)
	defer e.manager_destroy(&state.manager); defer delete(r.actions)
	defer mac.mouse_stop(&state)
	e.flush(&state.manager, e.space_by_id(&state.manager, 100))
	state.mouse.hit_test = resize_hit_test
	state.mouse.resize_frame = resize_frame_from_pointer
	down := CGEventCreateMouseEvent(nil, 1, {499, 400}, 0)
	defer mac.CFRelease(down)
	CGEventSetFlags(down, 0)
	// Live session-tap events have zero in both private window-ID fields.
	CGEventSetIntegerValueField(down, 91, 0)
	CGEventSetIntegerValueField(down, 92, 0)
	testing.expect(t, mac.mouse_callback(nil, 1, down, &state) == down)
	testing.expect_value(t, state.mouse.drag.window, u32(1))
}

@(test)
native_edge_drag_resizes_the_split_without_animation :: proc(t: ^testing.T) {
	state: mac.State; r: Recorder; fixture(&state.manager, &r)
	defer e.manager_destroy(&state.manager); defer delete(r.actions)
	m := &state.manager; s := e.space_by_id(m, 100)
	state.mouse.resize_frame = resize_frame_from_pointer
	e.flush(m, s); clear(&r.actions)
	m.animation_duration = 0.4
	w := m.windows[1]
	origin := mac.Point{w.frame.x + w.frame.w - 1, w.frame.y + w.frame.h / 2}
	down := CGEventCreateMouseEvent(nil, 1, origin, 0)
	defer mac.CFRelease(down)
	CGEventSetFlags(down, 0); CGEventSetIntegerValueField(down, 91, 1)
	testing.expect(t, mac.mouse_callback(nil, 1, down, &state) == down)
	if state.mouse.down == nil {
		return
	}
	defer mac.mouse_stop(&state)
	drag := CGEventCreateMouseEvent(nil, 6, {origin.x + 100, origin.y + 40}, 0)
	defer mac.CFRelease(drag)
	testing.expect(t, mac.mouse_callback(nil, 6, drag, &state) == drag)
	mac.mouse_tick(&state)
	testing.expect_value(t, w.frame.w, f64(600))
	testing.expect_value(t, w.frame.h, f64(800))
	testing.expect_value(t, m.windows[2].frame.x, f64(600))
	testing.expect_value(t, m.animation_duration, f64(0.4))
	for action in r.actions {
		if action.kind == .Frame {
			testing.expect_value(t, action.duration, f64(0))
		}
	}
	up := CGEventCreateMouseEvent(nil, 2, {origin.x + 100, origin.y + 40}, 0)
	defer mac.CFRelease(up)
	testing.expect(t, mac.mouse_callback(nil, 2, up, &state) == up)
	mac.mouse_tick(&state)
	testing.expect_value(t, state.mouse.drag.window, u32(0))
	testing.expect(t, !w.grabbed)
}

@(test)
native_resize_leaves_application_clicks_and_floating_edges_alone :: proc(
	t: ^testing.T,
) {
	state: mac.State; r: Recorder; fixture(&state.manager, &r)
	defer e.manager_destroy(&state.manager); defer delete(r.actions)
	e.flush(&state.manager, e.space_by_id(&state.manager, 100))
	for point in ([]mac.Point{{250, 400}, {0, 400}}) {
		state.manager.windows[1].floating = point.x == 0
		down := CGEventCreateMouseEvent(nil, 1, point, 0)
		CGEventSetFlags(down, 0); CGEventSetIntegerValueField(down, 91, 1)
		testing.expect(t, mac.mouse_callback(nil, 1, down, &state) == down)
		mac.CFRelease(down)
	}
}

@(test)
native_resize_reflows_nested_neighbors_and_resizes_single_tiles :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	s := e.space_by_id(&m, 100)
	e.add_window(
		&m,
		{
			id = 3,
			role = "AXWindow",
			subrole = "AXStandardWindow",
			space = 100,
			display = 10,
		},
	)
	e.flush(&m, s)
	w := m.windows[1]; before := w.frame
	d := e.mouse_border_resize(
		&m,
		1,
		{before.x + before.w - 1, before.y + before.h - 1},
	)
	testing.expect_value(t, d.window, u32(1))
	testing.expect_value(
		t,
		e.mouse_update(&m, &d, {d.origin.x + 70, d.origin.y + 60}),
		"",
	)
	testing.expect(t, w.frame.w > before.w && w.frame.h > before.h)
	for _, window in m.windows {
		n := e.find(s.view.root, window.id)
		testing.expect_value(t, window.frame, e.frame_for(n))
	}
	e.remove_window(&m, 2); e.remove_window(&m, 3); e.flush(&m, s)
	before = w.frame; clear(&r.actions)
	d = e.mouse_border_resize(
		&m,
		1,
		{before.x + before.w - 1, before.y + before.h / 2},
	)
	testing.expect_value(t, d.window, u32(1))
	testing.expect_value(
		t,
		e.mouse_update(&m, &d, {d.origin.x - 100, d.origin.y}),
		"",
	)
	expected := before; expected.w -= 100
	testing.expect_value(t, w.frame, expected)
	testing.expect_value(t, len(r.actions), 1)
	e.flush(&m, s)
	testing.expect_value(t, w.frame, expected)
	testing.expect(t, !w.floating)
	e.add_window(
		&m,
		{
			id = 4,
			role = "AXWindow",
			subrole = "AXStandardWindow",
			space = 100,
			display = 10,
		},
	)
	e.flush(&m, s)
	testing.expect_value(t, w.frame, e.frame_for(e.find(s.view.root, 1)))
	testing.expect_value(
		t,
		m.windows[4].frame,
		e.frame_for(e.find(s.view.root, 4)),
	)
}

@(test)
native_scrolling_resize_changes_column_width_and_repositions_neighbors :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	s := e.space_by_id(&m, 100); e.set_layout(&m, s, .Scroll); e.flush(&m, s)
	w := m.windows[1]; before := w.frame
	neighbor_x := m.windows[2].frame.x
	d := e.mouse_border_resize(
		&m,
		1,
		{before.x + before.w - 1, before.y + before.h / 2},
	)
	testing.expect_value(t, d.window, u32(1))
	testing.expect_value(
		t,
		e.mouse_update(&m, &d, {d.origin.x + 80, d.origin.y + 40}),
		"",
	)
	testing.expect_value(t, w.frame.w, before.w + 80)
	testing.expect_value(t, m.windows[2].frame.x, neighbor_x + 80)
	testing.expect_value(t, w.frame.h, before.h)
	testing.expect(t, !w.floating)
	e.remove_window(&m, 2)
	testing.expect_value(t, e.mouse_drop(&m, d, 0, d.previous), "")
	// A scrolling column retains its resized width when it becomes the sole
	// column; only BSP's lone tile returns to the full work area.
	testing.expect_value(t, w.frame, e.Rect{0, 0, before.w + 80, 800})
}

@(test)
single_tile_resize_preserves_opposite_edges_and_survives_refresh :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	s := e.space_by_id(&m, 100); e.remove_window(&m, 2); e.flush(&m, s)
	w := m.windows[1]
	d := e.mouse_border_resize(&m, 1, {1, 1})
	testing.expect_value(t, e.mouse_update(&m, &d, {101, 81}), "")
	expected := e.Rect{100, 80, 900, 720}
	testing.expect_value(t, w.frame, expected)
	w.frame = {0, 0, 1000, 800}
	e.flush(&m, s)
	testing.expect_value(t, w.frame, expected)
	s.view.frame = {0, 0, 500, 400}
	e.flush(&m, s)
	testing.expect_value(t, w.frame, e.Rect{50, 40, 450, 360})
	d = e.mouse_border_resize(&m, 1, {499, 200})
	before := w.frame; preference := w.solo_tile_frame
	r.fail = true
	testing.expect(t, e.mouse_update(&m, &d, {400, 200}) != "")
	testing.expect_value(t, w.frame, before)
	testing.expect_value(t, w.solo_tile_frame, preference)
}
