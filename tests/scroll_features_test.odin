package tests

import e "../src/engine"
import "core:testing"

@(test)
scroll_width_presets_reset_after_explicit_resize_and_survive_output_resize :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect(
		t,
		!e.execute(&m, {"config", "scroll_width_presets", "abs:400,abs:600,abs:800"}).failed,
	)
	testing.expect(
		t,
		!e.execute(&m, {"window", "--column-width", "abs:398"}).failed,
	)
	testing.expect(
		t,
		!e.execute(&m, {"window", "--cycle-column-width", "next"}).failed,
	)
	testing.expect_value(t, m.windows[1].frame.w, f64(400))
	e.execute(&m, {"window", "--column-width", "rel:-1"})
	e.execute(&m, {"window", "--cycle-column-width", "next"})
	testing.expect_value(t, m.windows[1].frame.w, f64(600))
	e.execute(&m, {"window", "--column-width", "ratio:0.5"})
	testing.expect_value(t, m.windows[1].frame.w, f64(616))
	m.spaces[0].view.frame.w = 1600
	e.flush(&m, m.spaces[0])
	testing.expect_value(t, m.windows[1].frame.w, f64(776))
	e.execute(&m, {"window", "--toggle", "column-full-width"})
	testing.expect_value(t, m.windows[1].frame.w, f64(1568))
	e.execute(&m, {"window", "--toggle", "column-full-width"})
	testing.expect_value(t, m.windows[1].frame.w, f64(776))
}

@(test)
scroll_consume_and_expel_have_distinct_membership_and_focus :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	e.execute(&m, {"window", "1", "--focus"})
	testing.expect(t, !e.execute(&m, {"window", "--consume"}).failed)
	n := e.find(m.spaces[0].view.root, 1)
	testing.expect_value(t, n.count, 2)
	testing.expect_value(t, n.windows[1], u32(2))
	testing.expect_value(t, m.focused, u32(1))
	e.execute(&m, {"window", "2", "--focus"})
	testing.expect(t, !e.execute(&m, {"window", "--expel"}).failed)
	testing.expect_value(t, m.focused, u32(1))
	testing.expect_value(
		t,
		e.next(e.find(m.spaces[0].view.root, 1)).windows[0],
		u32(2),
	)
	testing.expect_value(t, e.find(m.spaces[0].view.root, 1).count, 1)
}

@(test)
scroll_directional_consume_expel_preserves_selected_focus :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	testing.expect(
		t,
		!e.execute(&m, {"window", "--consume-or-expel", "west"}).failed,
	)
	testing.expect_value(
		t,
		e.find(m.spaces[0].view.root, 3),
		e.find(m.spaces[0].view.root, 2),
	)
	testing.expect_value(t, m.focused, u32(3))
	testing.expect(
		t,
		!e.execute(&m, {"window", "--consume-or-expel", "east"}).failed,
	)
	testing.expect(
		t,
		e.find(m.spaces[0].view.root, 3) != e.find(m.spaces[0].view.root, 2),
	)
	testing.expect_value(t, m.focused, u32(3))
}

@(test)
scroll_fixed_and_weighted_rows_preserve_total_height :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	e.execute(&m, {"window", "1", "--stack", "2"})
	e.execute(&m, {"window", "1", "--stack", "3"})
	testing.expect(
		t,
		!e.execute(&m, {"window", "1", "--row-height", "abs:200"}).failed,
	)
	testing.expect(
		t,
		!e.execute(&m, {"window", "2", "--row-height", "weight:2"}).failed,
	)
	testing.expect(
		t,
		!e.execute(&m, {"window", "3", "--row-height", "weight:1"}).failed,
	)
	testing.expect_value(t, m.windows[1].frame.h, f64(200))
	testing.expect_value(
		t,
		m.windows[2].frame.h + m.windows[3].frame.h,
		f64(536),
	)
	testing.expect(t, m.windows[2].frame.h > m.windows[3].frame.h)
	testing.expect(
		t,
		e.execute(&m, {"window", "--row-height", "weight:NaN"}).failed,
	)
}

@(test)
scroll_center_modes_are_configurable_per_space :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect(
		t,
		!e.execute(&m, {"config", "--space", "1", "scroll_center_focused_column", "always"}).failed,
	)
	testing.expect_value(t, m.windows[1].frame.x, f64(332))
	niri_open(&m, 2)
	testing.expect_value(t, m.windows[2].frame.x, f64(332))
	testing.expect(
		t,
		!e.execute(&m, {"config", "--space", "1", "scroll_center_focused_column", "on-overflow"}).failed,
	)
	testing.expect(
		t,
		e.execute(&m, {"config", "scroll_center_focused_column", "sometimes"}).failed,
	)
}

@(test)
scroll_tabbed_columns_preserve_rows_and_only_raise_active :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2)
	e.execute(&m, {"window", "1", "--stack", "2"})
	testing.expect(
		t,
		!e.execute(&m, {"window", "--column-display", "tabbed"}).failed,
	)
	testing.expect_value(t, m.windows[1].frame, m.windows[2].frame)
	orders := 0
	for a in r.actions {
		if a.kind == .Order {
			orders += 1; testing.expect_value(t, a.window, m.focused)
		}
	}
	testing.expect_value(t, orders, 1)
	resize(&r.actions, 0); e.flush(&m, m.spaces[0])
	testing.expect_value(t, len(r.actions), 0)
	e.execute(&m, {"window", "--column-display", "normal"})
	testing.expect(t, m.windows[1].frame.y != m.windows[2].frame.y)
}

@(test)
scroll_size_constraints_water_fill_and_preserve_requested_width :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	e.execute(&m, {"window", "1", "--stack", "2"})
	e.execute(&m, {"window", "1", "--stack", "3"})
	testing.expect(
		t,
		!e.execute(&m, {"window", "1", "--size-limits", "800:400:0:0"}).failed,
	)
	testing.expect(
		t,
		!e.execute(&m, {"window", "2", "--size-limits", "0:0:700:0"}).failed,
	)
	testing.expect_value(t, m.windows[1].frame.w, f64(800))
	testing.expect_value(t, m.windows[1].frame.h, f64(400))
	testing.expect_value(
		t,
		m.windows[2].frame.h + m.windows[3].frame.h,
		f64(336),
	)
	e.execute(&m, {"window", "1", "--column-width", "abs:900"})
	e.execute(&m, {"window", "2", "--size-limits", "0:0:0:0"})
	testing.expect_value(t, m.windows[1].frame.w, f64(900))
	testing.expect(
		t,
		e.execute(&m, {"window", "--size-limits", "900:0:500:0"}).failed,
	)
}

@(test)
scroll_legacy_expel_failed_focus_leaves_membership_intact :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2)
	e.execute(&m, {"window", "1", "--stack", "2"})
	r.fail = true
	testing.expect(t, e.execute(&m, {"window", "--expel"}).failed)
	testing.expect_value(t, m.focused, u32(2))
	testing.expect_value(t, e.find(m.spaces[0].view.root, 2).count, 2)
}

@(test)
scroll_column_move_and_warp_preserve_proportional_width_request :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2)
	e.execute(&m, {"window", "--column-width", "ratio:0.3333333333333333"})
	testing.expect(
		t,
		!e.execute(&m, {"window", "--move-column", "west"}).failed,
	)
	testing.expect_value(t, e.first(m.spaces[0].view.root).windows[0], u32(2))
	e.execute(&m, {"window", "--warp", "east"})
	m.spaces[0].view.frame.w = 1600
	e.flush(&m, m.spaces[0])
	testing.expect(t, m.windows[2].frame.w > 511 && m.windows[2].frame.w < 513)
}

@(test)
scroll_output_shrink_refits_focus_and_preserves_fixed_request :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	m.spaces[0].view.frame.w = 800
	e.flush(&m, m.spaces[0])
	w := m.windows[3]
	testing.expect(t, w.frame.x >= 16 && w.frame.x + w.frame.w <= 784)
	e.execute(&m, {"window", "--column-width", "abs:1200"})
	testing.expect_value(t, w.frame.x, f64(0))
	testing.expect_value(t, w.frame.w, f64(1200))
	m.spaces[0].view.frame.w = 1600
	e.flush(&m, m.spaces[0])
	testing.expect_value(t, w.frame.w, f64(1200))
}

@(test)
scroll_overflow_center_uses_arrival_side_neighbor :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2, 700); niri_open(&m, 3, 700)
	e.execute(&m, {"config", "scroll_center_focused_column", "on-overflow"})
	e.execute(&m, {"window", "1", "--focus"})
	e.execute(&m, {"window", "3", "--focus"})
	testing.expect_value(t, m.windows[3].frame.x, f64(290))
}

@(test)
scroll_height_presets_and_replacing_fixed_row_preserve_proportions :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	e.execute(&m, {"window", "1", "--stack", "2"})
	e.execute(&m, {"window", "1", "--stack", "3"})
	e.execute(&m, {"window", "1", "--row-height", "abs:200"})
	testing.expect_value(t, m.windows[2].frame.h, f64(268))
	e.execute(&m, {"window", "2", "--row-height", "abs:100"})
	testing.expect_value(t, m.windows[1].frame.h, f64(272))
	testing.expect_value(t, m.windows[2].frame.h, f64(100))
	testing.expect_value(t, m.windows[3].frame.h, f64(364))
	testing.expect(
		t,
		!e.execute(&m, {"config", "scroll_height_presets", "abs:100,abs:200,abs:300"}).failed,
	)
	testing.expect(
		t,
		!e.execute(&m, {"window", "2", "--cycle-row-height", "next"}).failed,
	)
	testing.expect_value(t, m.windows[2].frame.h, f64(200))
	e.execute(&m, {"window", "2", "--cycle-row-height", "prev"})
	testing.expect_value(t, m.windows[2].frame.h, f64(100))
}
