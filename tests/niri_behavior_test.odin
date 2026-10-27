package tests

import e "../src/engine"
import "core:testing"

// Independently authored behavior fixtures. Numerical expectations and assumptions
// are documented in docs/NIRI_PORT_REFERENCE.md; upstream tests are not copied.
niri_fixture :: proc(m: ^e.Manager, r: ^Recorder) {
	fixture(m, r)
	e.remove_window(m, 2)
	m.spaces[0].view.frame = {0, 0, 1280, 800}
	m.spaces[0].view.gap = 16
	e.set_layout(m, m.spaces[0], .Scroll)
	e.flush(m, m.spaces[0])
}

niri_open :: proc(m: ^e.Manager, id: u32, width: f64 = 0) {
	e.add_window(
		m,
		e.Window {
			id = id,
			pid = i32(id) + 40,
			role = "AXWindow",
			subrole = "AXStandardWindow",
			space = 100,
			display = 10,
		},
	)
	if width > 0 {
		e.find(m.spaces[0].view.root, id).column_width = width
	}
	e.focus_window(m, id)
	e.flush(m, m.spaces[0])
}

@(test)
niri_behavior_three_and_four_columns_keep_half_width :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect_value(t, m.windows[1].frame, e.Rect{16, 16, 616, 768})
	niri_open(&m, 2)
	testing.expect_value(t, m.windows[1].frame.x, f64(16))
	testing.expect_value(t, m.windows[2].frame.x, f64(648))
	niri_open(&m, 3)
	testing.expect_value(
		t,
		e.find(m.spaces[0].view.root, 1).frame.x,
		f64(-616),
	)
	testing.expect_value(t, m.windows[2].frame.x, f64(16))
	testing.expect_value(t, m.windows[3].frame.x, f64(648))
	niri_open(&m, 4)
	testing.expect_value(t, m.windows[3].frame.x, f64(16))
	testing.expect_value(t, m.windows[4].frame.x, f64(648))
	for _, w in m.windows { testing.expect_value(t, w.frame.w, f64(616)) }
}

@(test)
niri_behavior_insert_right_of_active_and_restore_after_close :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	e.remove_window(&m, 3); e.flush(&m, m.spaces[0])
	testing.expect_value(t, m.windows[1].frame.x, f64(16))
	testing.expect_value(t, m.windows[2].frame.x, f64(648))
	e.focus_window(&m, 2); e.flush(&m, m.spaces[0]); niri_open(&m, 3)
	e.focus_window(&m, 2); e.flush(&m, m.spaces[0]); niri_open(&m, 4)
	ids := [4]u32{1, 2, 4, 3}
	n := e.first(m.spaces[0].view.root)
	for id in ids { testing.expect_value(t, n.windows[0], id); n = e.next(n) }
	testing.expect_value(t, m.windows[2].frame.x, f64(16))
	testing.expect_value(t, m.windows[4].frame.x, f64(648))
}

@(test)
niri_behavior_intervening_focus_cancels_close_return :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	e.focus_window(&m, 2); e.flush(&m, m.spaces[0])
	e.focus_window(&m, 3); e.flush(&m, m.spaces[0])
	e.remove_window(&m, 3); e.flush(&m, m.spaces[0])
	testing.expect_value(t, m.windows[2].frame.x, f64(16))
}

@(test)
niri_behavior_left_resize_preserves_active_screen_position :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	e.execute(&m, {"window", "1", "--column-width", "abs:400"})
	niri_open(&m, 2, 600)
	niri_open(&m, 3, 500)
	// A width change acknowledged on the left must not move the focused C.
	before := m.windows[3].frame.x
	e.find(m.spaces[0].view.root, 1).column_width = 700
	e.flush(&m, m.spaces[0])
	testing.expect_value(t, m.windows[3].frame.x, before)
	testing.expect_value(t, m.windows[2].frame.x, f64(148))
}

@(test)
niri_behavior_rows_use_integer_edges_without_losing_height :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	testing.expect(t, !e.execute(&m, {"window", "1", "--stack", "2"}).failed)
	testing.expect(t, !e.execute(&m, {"window", "1", "--stack", "3"}).failed)
	n := e.find(m.spaces[0].view.root, 1)
	heights := [3]f64{245, 246, 245}
	ys := [3]f64{16, 277, 539}
	for i in 0 ..< n.count {
		w := m.windows[n.windows[i]]
		testing.expect_value(t, w.frame.y, ys[i])
		testing.expect_value(t, w.frame.h, heights[i])
	}
}

@(test)
niri_behavior_removing_left_column_preserves_active_position :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3); niri_open(&m, 4)
	before := m.windows[4].frame.x
	e.remove_window(&m, 1); e.flush(&m, m.spaces[0])
	testing.expect_value(t, m.windows[4].frame.x, before)
	testing.expect_value(t, m.windows[3].frame.x, f64(16))
}

@(test)
niri_behavior_close_return_refits_a_resized_previous_column :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	e.find(m.spaces[0].view.root, 2).column_width = 900
	e.flush(&m, m.spaces[0])
	e.remove_window(&m, 3); e.flush(&m, m.spaces[0])
	testing.expect_value(t, m.windows[2].frame.x, f64(364))
	testing.expect_value(t, m.spaces[0].view.scroll.focused, u32(2))
}
