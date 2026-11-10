package tests

import e "../src"
import layout "../src/layout"
import "core:testing"

// Pinned camera numbers from docs/NIRI_PORT_REFERENCE.md. Assertions are the
// settled screen positions and the absolute camera, checked independently of
// upstream tests.

column_x :: proc(m: ^e.Manager, id: u32) -> f64 {
	return layout.find(m.spaces[0].view.root, id).frame.x
}

camera :: proc(m: ^e.Manager) -> f64 {
	return m.spaces[0].view.scroll.offset
}

expect_xs :: proc(t: ^testing.T, m: ^e.Manager, ids: []u32, xs: []f64) {
	for id, i in ids {
		testing.expect_value(t, column_x(m, id), xs[i])
	}
}

@(test)
scroll_camera_never_tracks_insert_close_and_active_neighbor :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect_value(t, camera(&m), f64(-16))
	testing.expect_value(t, column_x(&m, 1), f64(16))
	niri_open(&m, 2)
	testing.expect_value(t, camera(&m), f64(-16))
	expect_xs(t, &m, []u32{1, 2}, []f64{16, 648})
	niri_open(&m, 3)
	testing.expect_value(t, camera(&m), f64(616))
	expect_xs(t, &m, []u32{1, 2, 3}, []f64{-616, 16, 648})
	e.remove_window(&m, 3); e.flush(&m, m.spaces[0])
	testing.expect_value(t, camera(&m), f64(-16))
	expect_xs(t, &m, []u32{1, 2}, []f64{16, 648})

	niri_open(&m, 3); niri_open(&m, 4)
	testing.expect_value(t, camera(&m), f64(1248))
	expect_xs(t, &m, []u32{1, 2, 3, 4}, []f64{-1248, -616, 16, 648})
	for id in ([]u32{1, 2, 3, 4}) {
		testing.expect_value(t, layout.find(m.spaces[0].view.root, id).column_width, f64(616))
	}

	e.remove_window(&m, 4); e.flush(&m, m.spaces[0])
	e.focus_window(&m, 2); e.flush(&m, m.spaces[0])
	niri_open(&m, 4)
	ids := [4]u32{1, 2, 4, 3}
	n := layout.first(m.spaces[0].view.root)
	for id in ids {
		testing.expect_value(t, n.windows[0], id)
		n = layout.next(n)
	}
	testing.expect_value(t, camera(&m), f64(616))
	expect_xs(t, &m, []u32{1, 2, 4, 3}, []f64{-616, 16, 648, 1280})
}

@(test)
scroll_camera_heterogeneous_widths_anchor_the_focused_column :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect(t, !e.execute(&m, {"window", "1", "--column-width", "abs:400"}).failed)
	niri_open(&m, 2, 600)
	niri_open(&m, 3, 500)
	testing.expect_value(t, camera(&m), f64(268))
	expect_xs(t, &m, []u32{1, 2, 3}, []f64{-268, 148, 764})
	testing.expect_value(t, layout.find(m.spaces[0].view.root, 1).column_width, f64(400))
	testing.expect_value(t, layout.find(m.spaces[0].view.root, 2).column_width, f64(600))
	testing.expect_value(t, layout.find(m.spaces[0].view.root, 3).column_width, f64(500))

	a := m.windows[1]
	e.size_feedback_request(a, {0, 0, 400, 768}, {0, 0, 616, 768}, 0)
	generation := a.size_feedback.generation
	e.size_feedback_observe(a, generation, {0, 0, 700, 768}, 0.2)
	e.size_feedback_observe(a, generation, {0, 0, 700, 768}, 0.28)
	e.flush(&m, m.spaces[0])
	testing.expect_value(t, camera(&m), f64(568))
	expect_xs(t, &m, []u32{1, 2, 3}, []f64{-568, 148, 764})
	testing.expect_value(t, layout.find(m.spaces[0].view.root, 1).column_size.value, f64(400))
	testing.expect_value(t, a.frame.w, f64(700))
}

@(test)
scroll_camera_focused_growth_keeps_the_right_margin :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect(t, !e.execute(&m, {"window", "1", "--column-width", "abs:400"}).failed)
	niri_open(&m, 2, 600)
	niri_open(&m, 3, 500)
	c := m.windows[3]
	e.size_feedback_request(c, {0, 0, 500, 768}, {0, 0, 616, 768}, 0)
	generation := c.size_feedback.generation
	e.size_feedback_observe(c, generation, {0, 0, 700, 768}, 0.2)
	e.size_feedback_observe(c, generation, {0, 0, 700, 768}, 0.28)
	e.flush(&m, m.spaces[0])
	testing.expect_value(t, camera(&m), f64(468))
	expect_xs(t, &m, []u32{1, 2, 3}, []f64{-468, -52, 564})
	testing.expect_value(t, layout.find(m.spaces[0].view.root, 3).column_size.value, f64(500))
	testing.expect_value(t, c.frame.w, f64(700))

	c.size_feedback.width_valid = false
	testing.expect(t, !e.execute(&m, {"window", "3", "--column-width", "abs:700"}).failed)
	testing.expect_value(t, camera(&m), f64(468))
	expect_xs(t, &m, []u32{1, 2, 3}, []f64{-468, -52, 564})
}

@(test)
scroll_camera_centering_modes_match_pinned_offsets :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect(t, !e.execute(&m, {"config", "scroll_center_focused_column", "always"}).failed)
	testing.expect_value(t, camera(&m), f64(-332))
	testing.expect_value(t, column_x(&m, 1), f64(332))
	niri_open(&m, 2)
	testing.expect_value(t, camera(&m), f64(300))
	niri_open(&m, 3)
	testing.expect_value(t, camera(&m), f64(932))
	testing.expect_value(t, column_x(&m, 3), f64(332))
}

@(test)
scroll_camera_oversized_column_left_aligns :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect(t, !e.execute(&m, {"config", "scroll_center_focused_column", "always"}).failed)
	testing.expect(t, !e.execute(&m, {"window", "1", "--column-width", "abs:1400"}).failed)
	testing.expect_value(t, column_x(&m, 1), f64(0))
}

@(test)
scroll_camera_on_overflow_matches_never_until_a_pair_overflows :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect(
		t,
		!e.execute(&m, {"config", "scroll_center_focused_column", "on-overflow"}).failed,
	)
	testing.expect_value(t, column_x(&m, 1), f64(16))
	niri_open(&m, 2); niri_open(&m, 3)
	testing.expect_value(t, camera(&m), f64(616))
	expect_xs(t, &m, []u32{1, 2, 3}, []f64{-616, 16, 648})
}

@(test)
scroll_camera_single_column_centers_only_when_asked :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect(
		t,
		!e.execute(&m, {"config", "scroll_center_focused_column", "on-overflow"}).failed,
	)
	testing.expect_value(t, column_x(&m, 1), f64(16))
	testing.expect(t, !e.execute(&m, {"config", "scroll_center_single_column", "on"}).failed)
	testing.expect_value(t, column_x(&m, 1), f64(332))
}

@(test)
scroll_camera_overflow_centers_only_the_arrival_pair :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect(
		t,
		!e.execute(&m, {"config", "scroll_center_focused_column", "on-overflow"}).failed,
	)
	testing.expect(t, !e.execute(&m, {"window", "1", "--column-width", "abs:700"}).failed)
	testing.expect_value(t, column_x(&m, 1), f64(16))
	niri_open(&m, 2, 700)
	e.focus_window(&m, 1); e.flush(&m, m.spaces[0])
	e.focus_window(&m, 2); e.flush(&m, m.spaces[0])
	testing.expect_value(t, column_x(&m, 2), f64(290))
	testing.expect_value(t, camera(&m), f64(426))

	e.remove_window(&m, 2); e.flush(&m, m.spaces[0])
	testing.expect(t, !e.execute(&m, {"window", "1", "--column-width", "abs:900"}).failed)
	niri_open(&m, 2, 400)
	niri_open(&m, 3, 400)
	e.focus_window(&m, 1); e.flush(&m, m.spaces[0])
	e.focus_window(&m, 3); e.flush(&m, m.spaces[0])
	testing.expect_value(t, camera(&m), f64(468))
	testing.expect_value(t, column_x(&m, 3), f64(864))
}

@(test)
scroll_snap_on_overflow_uses_the_arrival_side :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect(
		t,
		!e.execute(&m, {"config", "scroll_center_focused_column", "on-overflow"}).failed,
	)
	testing.expect(t, !e.execute(&m, {"window", "1", "--column-width", "abs:900"}).failed)
	niri_open(&m, 2, 400)
	niri_open(&m, 3, 200)
	testing.expect_value(t, m.spaces[0].view.scroll.focused, u32(3))
	// B's right-edge fit is camera 52. Centering B because A overflows would
	// clamp that candidate to the strip end and miss 52.
	snap := e.scroll_snap_target(&m.spaces[0].view, 52, 0)
	testing.expect_value(t, snap.offset, f64(52))
	testing.expect_value(t, snap.window, u32(2))
}

@(test)
scroll_rows_use_pinned_weights_and_a_minimum :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2)
	testing.expect(t, !e.execute(&m, {"window", "1", "--stack", "2"}).failed)
	testing.expect(t, !e.execute(&m, {"window", "1", "--row-height", "weight:1"}).failed)
	testing.expect(t, !e.execute(&m, {"window", "2", "--row-height", "weight:3"}).failed)
	testing.expect_value(t, m.windows[1].frame.h, f64(188))
	testing.expect_value(t, m.windows[2].frame.h, f64(564))
	testing.expect(t, !e.execute(&m, {"window", "1", "--size-limits", "0:300:0:0"}).failed)
	testing.expect_value(t, m.windows[1].frame.h, f64(300))
	testing.expect_value(t, m.windows[2].frame.h, f64(452))
}

@(test)
scroll_rapid_focus_settles_on_the_last_column :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	testing.expect(t, !e.execute(&m, {"config", "scroll_animation", "on"}).failed)
	m.animation_duration = 0.5
	e.focus_window(&m, 1); e.flush(&m, m.spaces[0])
	e.scroll_motion_tick(&m, 0.08)
	e.focus_window(&m, 3); e.flush(&m, m.spaces[0])
	e.scroll_motion_tick(&m, 0.12)
	e.focus_window(&m, 1); e.flush(&m, m.spaces[0])
	testing.expect_value(t, e.scroll_motion_tick(&m, 0.8), "")
	testing.expect_value(t, column_x(&m, 1), f64(16))
	testing.expect_value(t, camera(&m), f64(-16))
	testing.expect(t, !m.spaces[0].view.scroll.motion.active)
}

@(test)
scroll_minimize_restore_and_floating_focus_keep_the_anchored_view :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	w := m.windows[3]
	w.minimized = true
	testing.expect_value(t, e.reconcile_window_memberships(&m), "")
	e.flush(&m, m.spaces[0])
	testing.expect(t, layout.find(m.spaces[0].view.root, 3) == nil)
	testing.expect_value(t, column_x(&m, 2), f64(648))
	testing.expect_value(t, column_x(&m, 1), f64(16))
	w.minimized = false
	testing.expect_value(t, e.reconcile_window_memberships(&m), "")
	e.flush(&m, m.spaces[0])
	n := layout.first(m.spaces[0].view.root)
	for id in ([]u32{1, 2, 3}) {
		testing.expect_value(t, n.windows[0], id)
		testing.expect_value(t, n.column_width, f64(616))
		n = layout.next(n)
	}
	testing.expect_value(t, camera(&m), f64(616))
	testing.expect_value(t, column_x(&m, 3), f64(648))

	e.add_window(
		&m,
		e.Window {
			id = 9,
			pid = 49,
			role = "AXWindow",
			subrole = "AXStandardWindow",
			space = 100,
			display = 10,
			floating = true,
		},
	)
	before := camera(&m)
	e.focus_window(&m, 9); e.flush(&m, m.spaces[0])
	testing.expect_value(t, camera(&m), before)
	testing.expect_value(t, column_x(&m, 3), f64(648))
	testing.expect_value(t, m.spaces[0].view.scroll.focused, u32(3))
	e.focus_window(&m, 1); e.flush(&m, m.spaces[0])
	testing.expect_value(t, column_x(&m, 1), f64(16))
	testing.expect_value(t, camera(&m), f64(-16))
}
