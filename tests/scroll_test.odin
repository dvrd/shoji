package tests

import e "../src"
import dock "../src/dock"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"
import layout "../src/layout"

@(thread_local) scale_seen: [8]dock.Present_Request
@(thread_local) scale_last: dock.Present_Request
@(thread_local) scale_count: int

scale_record :: proc(_: rawptr, req: dock.Present_Request) -> string {
	if scale_count < len(scale_seen) {
		scale_seen[scale_count] = req
	}
	scale_last = req
	scale_count += 1
	return ""
}

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
	// left:+ moves that edge inward. left:- grows. right:+ is the grow key.
	testing.expect(t, !e.execute(&m, {"window", "1", "--resize", "left:100:0"}).failed)
	testing.expect_value(t, m.windows[1].frame.w, f64(500))
	testing.expect(t, !e.execute(&m, {"window", "1", "--resize", "left:-100:0"}).failed)
	testing.expect_value(t, m.windows[1].frame.w, f64(600))
	// Keyboard scroll resize stays on the geometry spring. A live write would
	// resize the app on every key repeat.
	animated := 0
	for a in r.actions {
		if a.kind == .Frame {
			animated += 1
			testing.expect(t, !a.live_resize)
		}
	}
	testing.expect(t, animated >= 1)
	testing.expect(t, !e.execute(&m, {"window", "1", "--swap", "east"}).failed)
	testing.expect_value(t, layout.first(m.spaces[0].view.root).windows[0], u32(2))
	frames := 0
	for a in r.actions {
		if a.kind == .Frame {
			frames += 1; testing.expect_value(t, a.duration, f64(0.2))
		}
	}
	testing.expect(t, frames >= 2)
}

@(test)
scroll_keyboard_resize_keeps_the_geometry_spring :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	m.scroll_animate = true
	m.animation_duration = 0.2
	testing.expect(t, !e.execute(&m, {"space", "--layout", "scroll"}).failed)
	testing.expect_value(t, e.flush(&m, m.spaces[0]), "")
	testing.expect(t, !e.execute(&m, {"window", "1", "--resize", "right:100:0"}).failed)
	testing.expect(t, m.spaces[0].view.scroll.geometry_active)
	testing.expect_value(t, m.windows[1].frame.w, f64(500))
	testing.expect_value(t, layout.find(m.spaces[0].view.root, 1).column_width, f64(600))
	for a in r.actions {
		if a.kind == .Frame {
			testing.expect(t, !a.live_resize)
		}
	}
}

@(test)
scroll_keyboard_resize_chase_starts_at_omega_and_does_not_overshoot :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	m.scroll_animate = true
	m.animation_duration = 0.2
	testing.expect(t, !e.execute(&m, {"space", "--layout", "scroll"}).failed)
	testing.expect_value(t, e.flush(&m, m.spaces[0]), "")
	w := m.windows[1]
	w.scroll_frame.velocity.w = 5000
	w.scroll_frame.initial_velocity.w = 5000
	m.scroll_time = 10
	testing.expect(t, !e.execute(&m, {"window", "1", "--resize", "right:100:0"}).failed)
	f := w.scroll_frame
	delta := f.target.w - f.from.w
	testing.expect_value(t, f.from.w, f64(500))
	testing.expect_value(t, f.target.w, f64(600))
	testing.expect(t, math.abs(f.initial_velocity.w - e.SCROLL_SPRING_OMEGA * delta) < 0.001)
	testing.expect(t, math.abs(f.initial_velocity.w - 5000) > 1)
	testing.expect_value(t, e.scroll_motion_tick(&m, 10.05), "")
	expect := f.target.w + (f.from.w - f.target.w) * math.exp(-e.SCROLL_SPRING_OMEGA * 0.05)
	testing.expect(t, w.frame.w > f.from.w && w.frame.w < f.target.w)
	testing.expect(t, math.abs(w.frame.w - expect) < 0.05)
}

@(test)
scroll_keyboard_resize_repeat_configures_once_per_target :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	scale_count = 0
	m.scale_present = scale_record
	m.scroll_animate = true
	m.animation_duration = 0.2
	testing.expect(t, !e.execute(&m, {"space", "--layout", "scroll"}).failed)
	testing.expect_value(t, e.flush(&m, m.spaces[0]), "")
	resize(&r.actions, 0)
	m.scroll_time = 10
	testing.expect(t, !e.execute(&m, {"window", "1", "--resize", "right:100:0"}).failed)
	testing.expect_value(t, e.scroll_motion_tick(&m, 10.02), "")
	testing.expect_value(t, e.scroll_motion_tick(&m, 10.04), "")
	m.scroll_time = 10.04
	testing.expect(t, !e.execute(&m, {"window", "1", "--resize", "right:100:0"}).failed)
	testing.expect_value(t, e.scroll_motion_tick(&m, 10.06), "")
	widths: [dynamic]f64
	defer delete(widths)
	for a in r.actions {
		if a.kind == .Frame && a.window == 1 {
			append(&widths, a.frame.w)
		}
	}
	testing.expect_value(t, len(widths), 2)
	if len(widths) == 2 {
		testing.expect_value(t, widths[0], f64(600))
		testing.expect_value(t, widths[1], f64(700))
	}
}

@(test)
scroll_keyboard_resize_holds_hidden_tabs_until_settle :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	scale_count = 0
	m.scale_present = scale_record
	m.scroll_animate = true
	m.animation_duration = 0.2
	testing.expect(t, !e.execute(&m, {"space", "--layout", "scroll"}).failed)
	testing.expect(t, !e.execute(&m, {"window", "1", "--stack", "2"}).failed)
	testing.expect(t, !e.execute(&m, {"window", "1", "--column-display", "tabbed"}).failed)
	testing.expect_value(t, e.flush(&m, m.spaces[0]), "")
	n := layout.find(m.spaces[0].view.root, 1)
	testing.expect(t, n != nil && n.column_tabbed && n.count == 2)
	active := n.order[0]
	hidden := active == 1 ? u32(2) : u32(1)
	resize(&r.actions, 0)
	m.scroll_time = 10
	testing.expect(t, !e.execute(&m, {"window", fmt.tprintf("%d", active), "--resize", "right:-100:0"}).failed)
	testing.expect_value(t, e.scroll_motion_tick(&m, 10.05), "")
	for a in r.actions {
		if a.kind == .Frame && a.window == hidden {
			testing.expect(t, false)
		}
	}
	resize(&r.actions, 0)
	testing.expect_value(t, e.scroll_motion_tick(&m, 10.5), "")
	writes := 0
	for a in r.actions {
		if a.kind == .Frame && a.window == hidden {
			writes += 1
		}
	}
	testing.expect_value(t, writes, 1)
	testing.expect(t, !m.windows[hidden].resize_scaled)
	// Transparent while it keeps the old size, and after its write until
	// WindowServer shows the new size.
	testing.expect(t, m.windows[hidden].resize_faded)
	m.window_bounds = fade_bounds
	fade_bounds_rect = m.windows[hidden].frame
	fade_bounds_rect.w += 100
	e.resize_fade_tick(&m)
	testing.expect(t, m.windows[hidden].resize_faded)
	fade_bounds_rect = m.windows[hidden].frame
	e.resize_fade_tick(&m)
	testing.expect(t, !m.windows[hidden].resize_faded)
	fades: [dynamic]f32
	defer delete(fades)
	for i in 0 ..< min(scale_count, len(scale_seen)) {
		req := scale_seen[i]
		if req.window == hidden {
			testing.expect_value(t, req.mask, dock.PRESENT_ALPHA)
			append(&fades, req.alpha)
		}
	}
	testing.expect_value(t, len(fades), 2)
	if len(fades) == 2 {
		testing.expect_value(t, fades[0], f32(0))
		testing.expect_value(t, fades[1], f32(1))
	}
}

fade_bounds_rect: e.Rect

fade_bounds :: proc(_: rawptr, _: u32) -> (e.Rect, bool) {
	return fade_bounds_rect, true
}

@(test)
scroll_keyboard_resize_scales_until_one_configure :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	scale_count = 0
	m.scale_present = scale_record
	m.scroll_animate = true
	m.animation_duration = 0.2
	testing.expect(t, !e.execute(&m, {"space", "--layout", "scroll"}).failed)
	testing.expect_value(t, e.flush(&m, m.spaces[0]), "")
	resize(&r.actions, 0)
	scale_count = 0
	m.scroll_time = 10
	testing.expect(t, !e.execute(&m, {"window", "1", "--resize", "right:100:0"}).failed)
	w := m.windows[1]
	testing.expect(t, w.resize_scaled)
	// Niri order: the app gets its final size at once, then only the
	// presentation scale moves.
	configures := 0
	for a in r.actions {
		if a.kind == .Frame && a.window == 1 {
			configures += 1
			testing.expect(t, !a.live_resize)
			testing.expect_value(t, a.frame.w, f64(600))
		}
	}
	testing.expect_value(t, configures, 1)
	testing.expect_value(t, w.resize_request.w, f64(600))
	testing.expect(t, scale_count >= 1)
	resize(&r.actions, 0)
	scale_count = 0
	testing.expect_value(t, e.scroll_motion_tick(&m, 10.05), "")
	testing.expect(t, scale_count >= 1)
	mid := scale_last
	testing.expect_value(t, mid.window, u32(1))
	testing.expect_value(t, mid.mask, dock.PRESENT_TRANSFORM)
	testing.expect_value(t, mid.b, f64(0))
	testing.expect_value(t, mid.c, f64(0))
	testing.expect(t, w.frame.w > 500 && w.frame.w < 600)
	// The 600 buffer shown at the smaller animated width: a > 1, closing on 1.
	testing.expect(t, math.abs(mid.a - 600 / w.frame.w) < 0.001)
	testing.expect(t, math.abs(mid.d - w.resize_basis.h / w.frame.h) < 0.001)
	testing.expect(t, math.abs(mid.tx - (-w.frame.x * mid.a)) < 0.001)
	testing.expect(t, math.abs(mid.ty - (-w.frame.y * mid.d)) < 0.001)
	for a in r.actions {
		if a.kind == .Frame && a.window == 1 {
			testing.expect(t, false)
		}
	}
	before := scale_count
	resize(&r.actions, 0)
	testing.expect_value(t, e.scroll_motion_tick(&m, 10.5), "")
	testing.expect(t, !m.spaces[0].view.scroll.geometry_active)
	testing.expect(t, !w.resize_scaled)
	testing.expect_value(t, w.frame.w, f64(600))
	frames := 0
	for a in r.actions {
		if a.kind == .Frame && a.window == 1 {
			frames += 1
			testing.expect(t, !a.live_resize)
			testing.expect_value(t, a.frame.w, f64(600))
		}
	}
	testing.expect_value(t, frames, 1)
	testing.expect(t, scale_count > before)
	done := scale_last
	testing.expect_value(t, done.mask, dock.PRESENT_TRANSFORM)
	testing.expect_value(t, done.a, f64(1))
	testing.expect_value(t, done.d, f64(1))
	testing.expect_value(t, done.tx, -w.frame.x)
	testing.expect_value(t, done.ty, -w.frame.y)
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
		layout.find(m.spaces[0].view.root, 1) != nil &&
		layout.find(m.spaces[0].view.root, 2) != nil,
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
		layout.find(m.spaces[0].view.root, 1).frame.x,
		f64(-500),
	)
	testing.expect_value(t, e.flush(&m, m.spaces[0]), "")
	testing.expect_value(
		t,
		layout.find(m.spaces[0].view.root, 1).frame.x,
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
	testing.expect_value(t, layout.first(m.spaces[0].view.root).windows[0], u32(2))
	testing.expect_value(t, m.windows[2].frame.w, f64(450))
	testing.expect_value(t, m.windows[1].frame.w, f64(500))
}

@(test)
scroll_keyboard_grow_stops_at_the_view :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect(t, !e.execute(&m, {"space", "--layout", "scroll"}).failed)
	testing.expect_value(t, e.flush(&m, m.spaces[0]), "")
	s := m.spaces[0]
	n := layout.find(s.view.root, 1)
	fit := s.view.scroll.viewport.w - 2 * layout.scroll_gap(&s.view)
	for _ in 0 ..< 40 {
		testing.expect(t, !e.execute(&m, {"window", "1", "--resize", "right:100:0"}).failed)
	}
	testing.expect_value(t, e.flush(&m, s), "")
	testing.expect(t, math.abs(n.column_width - fit) < 0.01, "a grow must stop at the view width")
	testing.expect(t, !e.execute(&m, {"window", "1", "--resize", "right:-100:0"}).failed)
	testing.expect_value(t, e.flush(&m, s), "")
	testing.expect(t, math.abs(n.column_width - (fit - 100)) < 0.01)
}

@(test)
scroll_keyboard_shrink_stops_at_a_learned_minimum :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect(t, !e.execute(&m, {"space", "--layout", "scroll"}).failed)
	testing.expect_value(t, e.flush(&m, m.spaces[0]), "")
	s := m.spaces[0]
	n := layout.find(s.view.root, 1)
	floor := n.column_width - 150
	m.windows[1].learned_min_width = floor
	delete(m.windows[1].app); m.windows[1].app = strings.clone("Mail")
	Notices :: struct {
		count: int,
		body:  string,
	}
	notices: Notices
	m.health_user = &notices
	m.health_notice = proc(user: rawptr, title, body: string) {
		n := (^Notices)(user)
		n.count += 1
		delete(n.body)
		n.body = strings.clone(body)
	}
	defer delete(notices.body)
	testing.expect(t, !e.execute(&m, {"window", "1", "--resize", "right:-100:0"}).failed)
	testing.expect_value(t, notices.count, 0)
	for _ in 0 ..< 4 {
		testing.expect(t, !e.execute(&m, {"window", "1", "--resize", "right:-100:0"}).failed)
	}
	testing.expectf(t, math.abs(n.column_width - floor) < 0.01, "%v %v", n.column_width, floor)
	testing.expect(t, notices.count > 0, "a stopped shrink must tell the user why")
	testing.expect(t, strings.contains(notices.body, "Mail"))
	m.windows[1].learned_min_width = 0
	testing.expect(t, !e.execute(&m, {"window", "1", "--resize", "right:-100:0"}).failed)
	testing.expect(t, math.abs(n.column_width - (floor - 100)) < 0.01)
}
