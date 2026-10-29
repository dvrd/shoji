package tests

import e "../src"
import "core:encoding/json"
import "core:testing"

@(test)
scroll_close_fills_the_vacated_viewport_and_restores_widths_on_open :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	e.execute(&m, {"space", "--layout", "scroll"})
	e.remove_window(&m, 2); e.flush(&m, m.spaces[0])
	testing.expect_value(t, m.windows[1].frame, e.Rect{0, 0, 1000, 800})
	e.add_window(&m, e.Window{id = 3, pid = 44, role = "AXWindow", subrole = "AXStandardWindow", space = 100, display = 10})
	e.flush(&m, m.spaces[0])
	testing.expect_value(t, m.windows[1].frame.w, f64(500))
	testing.expect_value(t, m.windows[3].frame.w, f64(500))
}

@(test)
scroll_layout_preserves_widths_and_reveals_focused_columns :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect(t, !e.execute(&m, {"space", "--layout", "scroll"}).failed)
	testing.expect_value(t, m.windows[1].frame, e.Rect{0, 0, 500, 800})
	testing.expect_value(t, m.windows[2].frame.w, f64(500))
	testing.expect(t, !e.execute(&m, {"window", "--focus", "east"}).failed)
	testing.expect_value(t, m.focused, u32(2))
	testing.expect_value(t, m.windows[2].frame, e.Rect{500, 0, 500, 800})
	testing.expect_value(t, m.windows[1].frame, e.Rect{0, 0, 500, 800})
	testing.expect(
		t,
		!e.execute(&m, {"window", "--column-width", "abs:450"}).failed,
	)
	testing.expect_value(t, m.windows[2].frame.w, f64(450))
	testing.expect_value(t, m.windows[1].frame.w, f64(500))
}

@(test)
scroll_resize_shuffle_and_focus_use_animated_frame_actions :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect(t, !e.execute(&m, {"space", "--layout", "scroll"}).failed)
	m.animation_duration = 0.2
	resize(&r.actions, 0)
	testing.expect(
		t,
		!e.execute(&m, {"window", "1", "--resize", "right:100:0"}).failed,
	)
	testing.expect_value(t, m.windows[1].frame.w, f64(600))
	testing.expect_value(t, m.windows[2].frame.w, f64(500))
	testing.expect(t, !e.execute(&m, {"window", "1", "--swap", "east"}).failed)
	testing.expect_value(t, e.first(m.spaces[0].view.root).windows[0], u32(2))
	frames := 0
	for a in r.actions {
		if a.kind == .Frame {
			frames += 1; testing.expect_value(t, a.duration, f64(0.2))
		}
	}
	testing.expect(t, frames >= 2)
}

@(test)
scroll_rows_and_return_to_bsp_keep_all_window_memberships :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect(t, !e.execute(&m, {"space", "--layout", "scroll"}).failed)
	testing.expect(t, !e.execute(&m, {"window", "1", "--stack", "2"}).failed)
	testing.expect_value(t, m.windows[1].frame, e.Rect{0, 0, 1000, 400})
	testing.expect_value(t, m.windows[2].frame, e.Rect{0, 400, 1000, 400})
	testing.expect(t, !e.execute(&m, {"window", "--focus", "south"}).failed)
	testing.expect_value(t, m.focused, u32(2))
	testing.expect(t, !e.execute(&m, {"window", "--swap", "north"}).failed)
	testing.expect_value(t, m.windows[2].frame.y, f64(0))
	testing.expect(t, !e.execute(&m, {"space", "--layout", "bsp"}).failed)
	testing.expect(
		t,
		e.find(m.spaces[0].view.root, 1) != nil &&
		e.find(m.spaces[0].view.root, 2) != nil,
	)
	testing.expect_value(t, m.windows[1].frame.w, f64(500))
}

@(test)
scroll_manual_pan_is_clamped_and_not_undone_by_refresh :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect(t, !e.execute(&m, {"space", "--layout", "scroll"}).failed)
	e.add_window(
		&m,
		e.Window {
			id = 3,
			pid = 44,
			role = "AXWindow",
			subrole = "AXStandardWindow",
			space = 100,
			display = 10,
		},
	)
	testing.expect(
		t,
		!e.execute(&m, {"space", "--scroll", "abs:99999"}).failed,
	)
	testing.expect_value(
		t,
		e.find(m.spaces[0].view.root, 1).frame.x,
		f64(-500),
	)
	testing.expect_value(t, e.flush(&m, m.spaces[0]), "")
	testing.expect_value(
		t,
		e.find(m.spaces[0].view.root, 1).frame.x,
		f64(-500),
	)
	data: [dynamic]e.Space_JSON
	testing.expect_value(
		t,
		json.unmarshal_string(e.query(&m, {"--spaces"}).text, &data),
		nil,
	)
	defer delete(data)
	for item in data {
		delete(item.uuid); delete(item.label); delete(item.type)
		delete(item.windows)
	}
	testing.expect_value(t, data[0].scroll_offset, f64(500))
	testing.expect_value(t, data[0].scroll_width, f64(1500))
	testing.expect(t, !e.execute(&m, {"window", "1", "--focus"}).failed)
	testing.expect_value(t, m.windows[1].frame.x, f64(0))
	testing.expect(
		t,
		!e.execute(&m, {"space", "--scroll", "rel:-99999"}).failed,
	)
	testing.expect_value(t, m.windows[1].frame.x, f64(0))
	testing.expect(t, e.execute(&m, {"space", "--scroll", "abs:NaN"}).failed)
	testing.expect(
		t,
		e.execute(&m, {"window", "--column-width", "abs:-1"}).failed,
	)
	testing.expect(t, e.execute(&m, {"window", "--ratio", "abs:0.5"}).failed)
}

@(test)
scroll_new_columns_keep_existing_widths_and_park_with_visible_edges :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect(t, !e.execute(&m, {"space", "--layout", "scroll"}).failed)
	testing.expect(
		t,
		!e.execute(&m, {"window", "1", "--column-width", "abs:450"}).failed,
	)
	for id in 3 ..= 6 { e.add_window(&m, e.Window{id = u32(id), pid = i32(id) + 40, role = "AXWindow", subrole = "AXStandardWindow", space = 100, display = 10}) }
	testing.expect_value(t, e.flush(&m, m.spaces[0]), "")
	testing.expect_value(t, m.windows[1].frame.w, f64(450))
	testing.expect_value(t, m.windows[2].frame.w, f64(500))
	for _, w in m.windows { testing.expect(t, w.frame.x + w.frame.w >= 32 && w.frame.x <= 968) }
	testing.expect(t, !e.execute(&m, {"window", "--focus", "last"}).failed)
	e.remove_window(&m, m.focused)
	testing.expect_value(t, e.flush(&m, m.spaces[0]), "")
	testing.expect(t, m.spaces[0].view.scroll.offset >= 0)
	testing.expect(t, !e.execute(&m, {"space", "--layout", "float"}).failed)
	testing.expect(
		t,
		e.execute(&m, {"window", "--column-width", "abs:600"}).failed,
	)
}

@(test)
scroll_failed_focus_does_not_change_viewport :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect(t, !e.execute(&m, {"space", "--layout", "scroll"}).failed)
	r.fail = true
	testing.expect(t, e.execute(&m, {"window", "--focus", "east"}).failed)
	testing.expect_value(t, m.focused, u32(1))
	testing.expect_value(t, m.spaces[0].view.scroll.offset, f64(0))
}

@(test)
scroll_single_column_keeps_viewport_separate_from_its_window_frame :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	e.remove_window(&m, 2)
	testing.expect(t, !e.execute(&m, {"space", "--layout", "scroll"}).failed)
	testing.expect(
		t,
		!e.execute(&m, {"window", "--column-width", "ratio:0.8"}).failed,
	)
	testing.expect_value(t, m.windows[1].frame.w, f64(800))
	testing.expect(
		t,
		!e.execute(&m, {"window", "--toggle", "zoom-fullscreen"}).failed,
	)
	testing.expect_value(t, m.windows[1].frame, e.Rect{0, 0, 1000, 800})
	testing.expect(
		t,
		!e.execute(&m, {"window", "--toggle", "zoom-fullscreen"}).failed,
	)
	testing.expect_value(t, m.windows[1].frame.w, f64(800))
}

@(test)
scroll_can_center_edge_columns_and_restore_normal_pan_limits :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect(t, !e.execute(&m, {"space", "--layout", "scroll"}).failed)
	testing.expect(t, !e.execute(&m, {"window", "1", "--center"}).failed)
	testing.expect_value(t, m.windows[1].frame.x, f64(250))
	testing.expect(t, !e.execute(&m, {"window", "2", "--center"}).failed)
	testing.expect_value(t, m.windows[2].frame.x, f64(250))
	testing.expect(
		t,
		!e.execute(&m, {"space", "--scroll", "abs:-99999"}).failed,
	)
	testing.expect_value(t, m.windows[1].frame.x, f64(0))
}

@(test)
scroll_warp_preserves_width_and_places_window_before_its_west_neighbor :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect(t, !e.execute(&m, {"space", "--layout", "scroll"}).failed)
	testing.expect(
		t,
		!e.execute(&m, {"window", "2", "--column-width", "abs:450"}).failed,
	)
	testing.expect(t, !e.execute(&m, {"window", "2", "--warp", "west"}).failed)
	testing.expect_value(t, e.first(m.spaces[0].view.root).windows[0], u32(2))
	testing.expect_value(t, m.windows[2].frame.w, f64(450))
	testing.expect_value(t, m.windows[1].frame.w, f64(500))
}
