package tests

import mac "../src"
import "core:testing"
import layout "../src/layout"

@(test)
fullscreen_return_restores_scroll_column_order_and_requested_width :: proc(t: ^testing.T) {
	m: mac.Manager; r: Recorder; niri_fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2, 430); niri_open(&m, 3)
	w := m.windows[2]; s := m.spaces[0]
	value := w^
	value.fullscreen = true
	mac.reconcile_window_model(&m, value)
	testing.expect_value(t, mac.reconcile_window_memberships(&m), "")
	testing.expect(t, layout.find(s.view.root, w.id) == nil)
	mac.focus_window(&m, 3)
	value = w^; value.fullscreen = false
	mac.reconcile_window_model(&m, value)
	testing.expect_value(t, mac.reconcile_window_memberships(&m), "")
	mac.flush(&m, s)
	n := layout.first(s.view.root)
	for id in ([3]u32{1, 2, 3}) {
		if !testing.expect(t, n != nil) { return }
		testing.expect_value(t, n.windows[0], id)
		n = layout.next(n)
	}
	testing.expect_value(t, layout.find(s.view.root, 2).column_width, f64(430))
}

@(test)
fullscreen_return_keeps_first_and_last_columns_and_full_width_setting :: proc(t: ^testing.T) {
	for target in ([2]u32{1, 3}) {
		m: mac.Manager; r: Recorder; niri_fixture(&m, &r)
		niri_open(&m, 2); niri_open(&m, 3)
		s := m.spaces[0]; w := m.windows[target]
		layout.find(s.view.root, target).column_full = true
		w.fullscreen = true
		testing.expect_value(t, mac.reconcile_window_memberships(&m), "")
		w.fullscreen = false; mac.focus_window(&m, 2)
		testing.expect_value(t, mac.reconcile_window_memberships(&m), "")
		n := layout.first(s.view.root)
		for id in ([3]u32{1, 2, 3}) {
			if !testing.expect(t, n != nil) { break }
			testing.expect_value(t, n.windows[0], id); n = layout.next(n)
		}
		testing.expect(t, layout.find(s.view.root, target).column_full)
		mac.manager_destroy(&m); delete(r.actions)
	}
}

@(test)
fullscreen_return_restores_row_to_surviving_tabbed_column :: proc(t: ^testing.T) {
	m: mac.Manager; r: Recorder; niri_fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3); niri_open(&m, 4)
	testing.expect(t, !mac.execute(&m, {"window", "1", "--stack", "2"}).failed)
	testing.expect(t, !mac.execute(&m, {"window", "1", "--stack", "3"}).failed)
	s := m.spaces[0]; n := layout.find(s.view.root, 1)
	n.column_tabbed = true
	order := n.windows
	w := m.windows[2]; w.fullscreen = true
	testing.expect_value(t, mac.reconcile_window_memberships(&m), "")
	mac.focus_window(&m, 4); w.fullscreen = false
	testing.expect_value(t, mac.reconcile_window_memberships(&m), "")
	n = layout.find(s.view.root, 2)
	testing.expect(t, n == layout.find(s.view.root, 1) && n == layout.find(s.view.root, 3))
	testing.expect_value(t, n.count, 3)
	testing.expect(t, n.column_tabbed)
	for i in 0 ..< 3 { testing.expect_value(t, n.windows[i], order[i]) }
}

@(test)
fullscreen_space_transition_restores_position_even_before_ax_flag_arrives :: proc(t: ^testing.T) {
	m: mac.Manager; r: Recorder; niri_fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	full := mac.add_space(&m, 200, 10, 2, {0, 0, 1280, 800})
	full.fullscreen = true
	w := m.windows[2]; w.space = 200
	testing.expect_value(t, mac.reconcile_window_memberships(&m), "")
	w.space = 100; mac.focus_window(&m, 3)
	testing.expect_value(t, mac.reconcile_window_memberships(&m), "")
	testing.expect_value(t, layout.next(layout.first(m.spaces[0].view.root)).windows[0], u32(2))
}

@(test)
video_fullscreen_ordered_out_browser_restores_its_scroll_slot :: proc(t: ^testing.T) {
	m: mac.Manager; r: Recorder; niri_fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2, 430); niri_open(&m, 3)
	w := m.windows[2]
	// A browser may hide/order out its document window while presenting video
	// in a separate fullscreen surface, without AXFullScreen on the document.
	w.ordered_in = false
	testing.expect_value(t, mac.reconcile_window_memberships(&m), "")
	mac.focus_window(&m, 3); w.ordered_in = true
	testing.expect_value(t, mac.reconcile_window_memberships(&m), "")
	mac.flush(&m, m.spaces[0])
	testing.expect_value(t, layout.next(layout.first(m.spaces[0].view.root)).windows[0], u32(2))
	testing.expect_value(t, layout.find(m.spaces[0].view.root, 2).column_width, f64(430))
}

@(test)
video_fullscreen_temporary_child_window_keeps_its_scroll_position :: proc(t: ^testing.T) {
	m: mac.Manager; r: Recorder; niri_fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2, 430); niri_open(&m, 3)
	w := m.windows[2]
	w.root_window = false
	testing.expect_value(t, mac.reconcile_window_memberships(&m), "")
	mac.focus_window(&m, 3); w.root_window = true
	testing.expect_value(t, mac.reconcile_window_memberships(&m), "")
	mac.flush(&m, m.spaces[0])
	testing.expect_value(t, layout.next(layout.first(m.spaces[0].view.root)).windows[0], u32(2))
	testing.expect_value(t, layout.find(m.spaces[0].view.root, 2).column_width, f64(430))
}
