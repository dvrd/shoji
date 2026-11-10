package tests

import e "../src"
import layout "../src/layout"
import "core:testing"

@(test)
scroll_width_presets_reset_after_explicit_resize_and_survive_output_resize :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect(
		t,
		!e.execute(&m, {"config", "scroll_width_presets", "abs:400,abs:600,abs:800"}).failed,
	)
	testing.expect(t, !e.execute(&m, {"window", "--column-width", "abs:398"}).failed)
	testing.expect(t, !e.execute(&m, {"window", "--cycle-column-width", "next"}).failed)
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
scroll_consume_and_expel_have_distinct_membership_and_focus :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	e.execute(&m, {"window", "1", "--focus"})
	testing.expect(t, !e.execute(&m, {"window", "--consume"}).failed)
	n := layout.find(m.spaces[0].view.root, 1)
	testing.expect_value(t, n.count, 2)
	testing.expect_value(t, n.windows[1], u32(2))
	testing.expect_value(t, m.focused, u32(1))
	e.execute(&m, {"window", "2", "--focus"})
	testing.expect(t, !e.execute(&m, {"window", "--expel"}).failed)
	testing.expect_value(t, m.focused, u32(1))
	testing.expect_value(t, layout.next(layout.find(m.spaces[0].view.root, 1)).windows[0], u32(2))
	testing.expect_value(t, layout.find(m.spaces[0].view.root, 1).count, 1)
}

@(test)
scroll_directional_consume_expel_preserves_selected_focus :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	testing.expect(t, !e.execute(&m, {"window", "--consume-or-expel", "west"}).failed)
	testing.expect_value(
		t,
		layout.find(m.spaces[0].view.root, 3),
		layout.find(m.spaces[0].view.root, 2),
	)
	testing.expect_value(t, m.focused, u32(3))
	testing.expect(t, !e.execute(&m, {"window", "--consume-or-expel", "east"}).failed)
	testing.expect(
		t,
		layout.find(m.spaces[0].view.root, 3) != layout.find(m.spaces[0].view.root, 2),
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
	testing.expect(t, !e.execute(&m, {"window", "1", "--row-height", "abs:200"}).failed)
	testing.expect(t, !e.execute(&m, {"window", "2", "--row-height", "weight:2"}).failed)
	testing.expect(t, !e.execute(&m, {"window", "3", "--row-height", "weight:1"}).failed)
	testing.expect_value(t, m.windows[1].frame.h, f64(200))
	testing.expect_value(t, m.windows[2].frame.h + m.windows[3].frame.h, f64(536))
	testing.expect(t, m.windows[2].frame.h > m.windows[3].frame.h)
	testing.expect(t, e.execute(&m, {"window", "--row-height", "weight:NaN"}).failed)
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
scroll_default_column_display_applies_to_new_columns_only :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect_value(t, e.config(&m, {"scroll_default_column_display"}).text, "normal")
	testing.expect(t, e.config(&m, {"scroll_default_column_display", "invalid"}).failed)
	testing.expect(t, !e.config(&m, {"scroll_default_column_display", "tabbed"}).failed)
	testing.expect(t, !layout.find(m.spaces[0].view.root, 1).column_tabbed)
	niri_open(&m, 2)
	testing.expect(t, layout.find(m.spaces[0].view.root, 2).column_tabbed)
	testing.expect(t, !e.config(&m, {"scroll_default_column_display", "normal"}).failed)
	e.focus_window(&m, 1)
	niri_open(&m, 3)
	testing.expect(t, !layout.find(m.spaces[0].view.root, 3).column_tabbed)
	testing.expect(t, layout.find(m.spaces[0].view.root, 2).column_tabbed)
	e.remove_window(&m, 1); e.remove_window(&m, 2); e.remove_window(&m, 3)
	testing.expect(t, !e.config(&m, {"scroll_default_column_display", "tabbed"}).failed)
	niri_open(&m, 4)
	testing.expect(t, layout.find(m.spaces[0].view.root, 4).column_tabbed)
}

// A live open goes through admission, the only path that may join a tab.
niri_open_live :: proc(t: ^testing.T, m: ^e.Manager, id: u32) {
	w := e.discover_window(
		m,
		{
			id = id,
			pid = i32(id) + 40,
			role = "AXWindow",
			subrole = "AXStandardWindow",
			space = 100,
			display = 10,
			frame = {20, 20, 600, 500},
		},
	)
	admitted, err := e.admit_window(m, w)
	testing.expect(t, admitted)
	testing.expect_value(t, err, "")
	testing.expect_value(t, e.finish_opening(m, w), "")
	e.focus_window(m, id)
}

@(test)
opening_into_a_tabbed_column_inserts_to_the_right_of_the_active_tab :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	testing.expect(t, !e.execute(&m, {"window", "1", "--stack", "2"}).failed)
	testing.expect(t, !e.execute(&m, {"window", "1", "--column-display", "tabbed"}).failed)
	testing.expect(t, !e.execute(&m, {"window", "2", "--focus"}).failed)
	niri_open_live(t, &m, 4)
	n := layout.find(m.spaces[0].view.root, 1)
	testing.expect(t, n != nil && n == layout.find(m.spaces[0].view.root, 4))
	testing.expect(t, n.column_tabbed && n.count == 3)
	testing.expect_value(t, n.windows[0], u32(1))
	testing.expect_value(t, n.windows[1], u32(2))
	testing.expect_value(t, n.windows[2], u32(4))
	testing.expect_value(t, n.order[0], u32(4))
	other := layout.find(m.spaces[0].view.root, 3)
	testing.expect(t, other != nil && other != n && other.count == 1)
	e.execute(&m, {"window", "1", "--column-display", "tabbed"})
	e.execute(&m, {"window", "1", "--insert", "east"})
	niri_open_live(t, &m, 5)
	opened := layout.find(m.spaces[0].view.root, 5)
	testing.expect(t, opened != nil && opened != n && opened.count == 1)
}

// Startup enumeration and restores add already-open windows. They must keep
// their own columns even while a tabbed column has focus.
@(test)
enumerated_windows_do_not_join_a_focused_tabbed_column :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect(t, !e.execute(&m, {"window", "1", "--column-display", "tabbed"}).failed)
	niri_open(&m, 2); niri_open(&m, 3)
	tabbed := layout.find(m.spaces[0].view.root, 1)
	testing.expect(t, tabbed != nil && tabbed.count == 1)
	two := layout.find(m.spaces[0].view.root, 2)
	three := layout.find(m.spaces[0].view.root, 3)
	testing.expect(t, two != nil && two != tabbed && two.count == 1)
	testing.expect(t, three != nil && three != tabbed && three != two)
}

@(test)
scroll_default_column_display_supports_space_overrides :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect(
		t,
		!e.config(&m, {"--space", "1", "scroll_default_column_display", "tabbed"}).failed,
	)
	testing.expect(t, !e.config(&m, {"scroll_default_column_display", "normal"}).failed)
	testing.expect_value(
		t,
		e.config(&m, {"--space", "1", "scroll_default_column_display"}).text,
		"tabbed",
	)
	niri_open(&m, 2)
	testing.expect(t, layout.find(m.spaces[0].view.root, 2).column_tabbed)
}

@(test)
scroll_tabbed_columns_preserve_rows_and_only_raise_active :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2)
	e.execute(&m, {"window", "1", "--stack", "2"})
	testing.expect(t, !e.execute(&m, {"window", "--column-display", "tabbed"}).failed)
	testing.expect_value(t, m.windows[1].frame, m.windows[2].frame)
	orders := 0
	for a in r.actions {
		if a.kind == .Order {
			orders += 1; testing.expect_value(t, a.window, m.focused)
		}
	}
	testing.expect_value(t, orders, 1)
	n := layout.find(m.spaces[0].view.root, 1)
	testing.expect_value(t, m.windows[1].frame.x, n.frame.x + 9)
	testing.expect_value(t, m.windows[1].frame.w, n.frame.w - 9)
	testing.expect_value(t, m.windows[1].size_intent.w, n.column_width - 9)
	e.execute(&m, {"window", "--toggle", "column-full-width"})
	testing.expect_value(t, m.windows[1].frame.x, n.frame.x + 9)
	testing.expect_value(t, m.windows[1].frame.w, n.frame.w - 9)
	resize(&r.actions, 0); e.flush(&m, m.spaces[0])
	testing.expect_value(t, len(r.actions), 0)
	e.execute(&m, {"window", "--column-display", "normal"})
	testing.expect(t, m.windows[1].frame.y != m.windows[2].frame.y)
}

@(test)
scroll_tab_indicators_follow_stable_order_and_active_window :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	e.execute(&m, {"window", "1", "--stack", "2"})
	e.execute(&m, {"window", "1", "--stack", "3"})
	e.execute(&m, {"window", "1", "--column-display", "tabbed"})
	e.execute(&m, {"window", "1", "--focus"})
	frame := e.Rect{100, 50, 400, 600}
	tabs, count := e.tab_indicators(&m, frame)
	testing.expect_value(t, count, 3)
	testing.expect_value(t, tabs[0].window, u32(1))
	testing.expect_value(t, tabs[1].window, u32(2))
	testing.expect_value(t, tabs[2].window, u32(3))
	testing.expect(t, tabs[0].active && !tabs[1].active && !tabs[2].active)
	testing.expect_value(t, tabs[0].frame, e.Rect{91, 200, 4, 100})
	testing.expect_value(t, tabs[0].frame.y + tabs[0].frame.h, tabs[1].frame.y)
	edge_tabs, _ := e.tab_indicators(&m, {0, 50, 400, 600})
	testing.expect(t, edge_tabs[0].frame.x > m.focus_ring.width)
	e.execute(&m, {"window", "2", "--focus"})
	tabs, count = e.tab_indicators(&m, frame)
	testing.expect_value(t, count, 3)
	testing.expect(t, tabs[1].active && tabs[0].window == 1 && tabs[2].window == 3)
	e.execute(&m, {"window", "2", "--column-display", "normal"})
	_, count = e.tab_indicators(&m, frame)
	testing.expect_value(t, count, 0)
}

@(test)
scroll_unfocused_tabbed_columns_keep_indicators :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3); niri_open(&m, 4)
	testing.expect(t, !e.execute(&m, {"window", "1", "--stack", "2"}).failed)
	testing.expect(t, !e.execute(&m, {"window", "3", "--stack", "4"}).failed)
	testing.expect(t, !e.execute(&m, {"window", "1", "--column-display", "tabbed"}).failed)
	testing.expect(t, !e.execute(&m, {"window", "3", "--column-display", "tabbed"}).failed)
	testing.expect(t, !e.execute(&m, {"window", "1", "--focus"}).failed)
	testing.expect_value(t, e.flush(&m, m.spaces[0]), "")
	focused := m.windows[1].frame
	tabs, count := e.tab_indicators(&m, focused)
	testing.expect_value(t, count, 4)
	testing.expect_value(t, tabs[0].window, u32(1))
	testing.expect_value(t, tabs[1].window, u32(2))
	testing.expect(t, tabs[0].active && !tabs[1].active && !tabs[2].active && !tabs[3].active)
	testing.expect_value(t, tabs[2].window, u32(3))
	testing.expect_value(t, tabs[3].window, u32(4))
	testing.expect(t, tabs[2].frame.x != tabs[0].frame.x)
	other := layout.find(m.spaces[0].view.root, 3)
	testing.expect(t, other != nil && other != layout.find(m.spaces[0].view.root, 1))
	parked := m.windows[other.order[0]]
	parked.frame.x = m.spaces[0].view.scroll.viewport.x - parked.frame.w - 10
	_, count = e.tab_indicators(&m, focused)
	testing.expect_value(t, count, 2)
}

@(test)
scroll_tab_indicator_position_changes_layout_and_preserves_tab_order :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2)
	e.execute(&m, {"window", "1", "--stack", "2"})
	e.execute(&m, {"window", "1", "--column-display", "tabbed"})
	e.execute(&m, {"window", "1", "--focus"})
	testing.expect_value(t, e.config(&m, {"tab_indicator_position"}).text, "left")
	testing.expect(t, e.config(&m, {"tab_indicator_position", "right"}).failed)
	testing.expect(t, !e.config(&m, {"tab_indicator_position", "top"}).failed)
	testing.expect_value(t, e.config(&m, {"tab_indicator_position"}).text, "top")
	n := layout.find(m.spaces[0].view.root, 1)
	testing.expect_value(t, m.windows[1].frame.y, n.frame.y + 9)
	testing.expect_value(t, m.windows[1].frame.h, n.frame.h - 9)
	testing.expect_value(t, m.windows[1].size_intent.h, n.frame.h - 9)
	tabs, count := e.tab_indicators(&m, {100, 50, 400, 600})
	testing.expect_value(t, count, 2)
	testing.expect_value(t, tabs[0].frame, e.Rect{200, 41, 100, 4})
	testing.expect_value(t, tabs[1].frame, e.Rect{300, 41, 100, 4})
	testing.expect(t, e.config(&m, {"tab_indicator_gap", "-1"}).failed)
	testing.expect(t, !e.config(&m, {"tab_indicator_gap", "3"}).failed)
	tabs, count = e.tab_indicators(&m, {100, 50, 400, 600})
	testing.expect_value(t, tabs[0].frame.x + tabs[0].frame.w + 3, tabs[1].frame.x)
	testing.expect(t, !e.config(&m, {"tab_indicator_gap", "0"}).failed)
	testing.expect_value(t, tabs[0].window, u32(1))
	testing.expect_value(t, tabs[1].window, u32(2))
	testing.expect(t, e.config(&m, {"tab_indicator_width", "0"}).failed)
	testing.expect(t, e.config(&m, {"tab_indicator_width", "NaN"}).failed)
	testing.expect(t, !e.config(&m, {"tab_indicator_width", "8"}).failed)
	testing.expect_value(t, m.windows[1].frame.y, n.frame.y + 13)
	tabs, count = e.tab_indicators(&m, {100, 50, 400, 600})
	testing.expect_value(t, tabs[0].frame, e.Rect{200, 37, 100, 8})
	testing.expect(t, !e.config(&m, {"tab_indicator_position", "left"}).failed)
	testing.expect_value(t, m.windows[1].frame.x, n.frame.x + 13)
}

@(test)
scroll_top_tabs_use_horizontal_focus_and_fall_through_to_columns :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	e.execute(&m, {"window", "1", "--stack", "2"})
	e.execute(&m, {"window", "1", "--column-display", "tabbed"})
	e.execute(&m, {"config", "tab_indicator_position", "top"})
	e.execute(&m, {"window", "1", "--focus"})
	testing.expect(t, !e.execute(&m, {"window", "--focus", "east"}).failed)
	testing.expect_value(t, m.focused, u32(2))
	testing.expect(t, !e.execute(&m, {"window", "--focus", "east"}).failed)
	testing.expect_value(t, m.focused, u32(3))
	e.execute(&m, {"window", "2", "--focus"})
	testing.expect(t, !e.execute(&m, {"window", "--focus", "west"}).failed)
	testing.expect_value(t, m.focused, u32(1))
	testing.expect(t, e.scroll_direction(&m, m.spaces[0], m.windows[1], "south") == nil)
	e.execute(&m, {"config", "tab_indicator_position", "left"})
	testing.expect_value(t, e.scroll_direction(&m, m.spaces[0], m.windows[1], "south").id, u32(2))
	testing.expect_value(t, e.scroll_direction(&m, m.spaces[0], m.windows[1], "east").id, u32(3))
}

@(test)
scroll_size_constraints_water_fill_and_preserve_requested_width :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	e.execute(&m, {"window", "1", "--stack", "2"})
	e.execute(&m, {"window", "1", "--stack", "3"})
	testing.expect(t, !e.execute(&m, {"window", "1", "--size-limits", "800:400:0:0"}).failed)
	testing.expect(t, !e.execute(&m, {"window", "2", "--size-limits", "0:0:700:0"}).failed)
	testing.expect_value(t, m.windows[1].frame.w, f64(800))
	testing.expect_value(t, m.windows[1].frame.h, f64(400))
	testing.expect_value(t, m.windows[2].frame.h + m.windows[3].frame.h, f64(336))
	e.execute(&m, {"window", "1", "--column-width", "abs:900"})
	e.execute(&m, {"window", "2", "--size-limits", "0:0:0:0"})
	testing.expect_value(t, m.windows[1].frame.w, f64(900))
	testing.expect(t, e.execute(&m, {"window", "--size-limits", "900:0:500:0"}).failed)
}

@(test)
scroll_legacy_expel_failed_focus_leaves_membership_intact :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2)
	e.execute(&m, {"window", "1", "--stack", "2"})
	r.fail = true
	testing.expect(t, e.execute(&m, {"window", "--expel"}).failed)
	testing.expect_value(t, m.focused, u32(2))
	testing.expect_value(t, layout.find(m.spaces[0].view.root, 2).count, 2)
}

@(test)
scroll_column_move_and_warp_preserve_proportional_width_request :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2)
	e.execute(&m, {"window", "--column-width", "ratio:0.3333333333333333"})
	testing.expect(t, !e.execute(&m, {"window", "--move-column", "west"}).failed)
	testing.expect_value(t, layout.first(m.spaces[0].view.root).windows[0], u32(2))
	e.execute(&m, {"window", "--warp", "east"})
	m.spaces[0].view.frame.w = 1600
	e.flush(&m, m.spaces[0])
	testing.expect(t, m.windows[2].frame.w > 511 && m.windows[2].frame.w < 513)
}

@(test)
scroll_output_shrink_refits_focus_and_preserves_fixed_request :: proc(t: ^testing.T) {
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
scroll_height_presets_and_replacing_fixed_row_preserve_proportions :: proc(t: ^testing.T) {
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
	testing.expect(t, !e.execute(&m, {"window", "2", "--cycle-row-height", "next"}).failed)
	testing.expect_value(t, m.windows[2].frame.h, f64(200))
	e.execute(&m, {"window", "2", "--cycle-row-height", "prev"})
	testing.expect_value(t, m.windows[2].frame.h, f64(100))
}
