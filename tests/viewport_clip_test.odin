package tests

import e "../src"
import dock "../src/dock"
import layout "../src/layout"
import "core:math"
import "core:testing"

@(test)
viewport_clip_reports_window_local_intersection :: proc(t: ^testing.T) {
	view := layout.Rect{0, 0, 1280, 800}
	x, y, w, h, partial := layout.viewport_clip({16, 16, 400, 300}, view)
	testing.expect(t, !partial)
	testing.expect_value(t, x, i32(0))
	testing.expect_value(t, y, i32(0))
	testing.expect_value(t, w, i32(400))
	testing.expect_value(t, h, i32(300))
	x, y, w, h, partial = layout.viewport_clip({1200, 0, 400, 400}, view)
	testing.expect(t, partial)
	testing.expect_value(t, x, i32(0))
	testing.expect_value(t, y, i32(0))
	testing.expect_value(t, w, i32(80))
	testing.expect_value(t, h, i32(400))
	x, y, w, h, partial = layout.viewport_clip({-500, 10, 100, 100}, view)
	testing.expect(t, partial)
	testing.expect_value(t, x, i32(0))
	testing.expect_value(t, y, i32(0))
	testing.expect_value(t, w, i32(0))
	testing.expect_value(t, h, i32(0))
	_, _, _, _, partial = layout.viewport_clip({0, 0, 0, 10}, view)
	testing.expect(t, !partial)
	_, _, _, _, partial = layout.viewport_clip({-0.4, 0, 10, 10}, view)
	testing.expect(t, !partial)
	_, _, _, _, partial = layout.viewport_clip({-0.6, 0, 10, 10}, view)
	testing.expect(t, partial)
}

@(thread_local) clip_seen: [8]dock.Present_Request
@(thread_local) clip_count: int
@(thread_local) clip_fail: string

clip_record :: proc(_: rawptr, req: dock.Present_Request) -> string {
	if clip_fail != "" {return clip_fail}
	if clip_count < len(clip_seen) {
		clip_seen[clip_count] = req
		clip_count += 1
	}
	return ""
}

@(test)
viewport_clip_sync_sends_overflow_then_restores :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	clip_count = 0
	clip_fail = ""
	m.present = clip_record
	m.viewport_clip = true
	win := m.windows[1]
	view := m.spaces[0].view.scroll.viewport
	win.frame = {1200, 0, 400, 400}
	e.viewport_clip_sync(&m, m.spaces[0])
	testing.expect_value(t, clip_count, 1)
	expect_x, expect_y, expect_w, expect_h, partial := layout.viewport_clip(win.frame, view)
	testing.expect(t, partial && expect_w > 0 && expect_h > 0)
	testing.expect_value(t, clip_seen[0].window, win.id)
	testing.expect_value(t, clip_seen[0].mask, dock.PRESENT_CLIP | dock.PRESENT_EVENT)
	testing.expect_value(t, clip_seen[0].event_kind, u8(1))
	testing.expect_value(t, clip_seen[0].x, expect_x)
	testing.expect_value(t, clip_seen[0].y, expect_y)
	testing.expect_value(t, clip_seen[0].w, expect_w)
	testing.expect_value(t, clip_seen[0].h, expect_h)
	testing.expect(t, win.viewport_clipped)
	e.viewport_clip_sync(&m, m.spaces[0])
	testing.expect_value(t, clip_count, 1)
	win.frame = {16, 16, 200, 200}
	e.viewport_clip_sync(&m, m.spaces[0])
	testing.expect_value(t, clip_count, 2)
	testing.expect_value(t, clip_seen[1].event_kind, u8(1))
	testing.expect_value(t, clip_seen[1].x, i32(0))
	testing.expect_value(t, clip_seen[1].y, i32(0))
	testing.expect_value(t, clip_seen[1].w, i32(200))
	testing.expect_value(t, clip_seen[1].h, i32(200))
	testing.expect(t, !win.viewport_clipped)
	win.frame = {-2000, 0, 100, 100}
	e.viewport_clip_sync(&m, m.spaces[0])
	testing.expect_value(t, clip_count, 3)
	testing.expect_value(t, clip_seen[2].event_kind, u8(0))
	testing.expect_value(t, clip_seen[2].w, i32(0))
	testing.expect(t, win.viewport_clipped)
}

@(test)
viewport_clip_off_repairs_each_window_once :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder
	niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	clip_count = 0
	clip_fail = ""
	m.present = clip_record
	win := m.windows[m.focused]
	e.viewport_clip_sync(&m, m.spaces[0])
	testing.expect_value(t, clip_count, 2)
	testing.expect_value(t, clip_seen[0].window, win.id)
	testing.expect_value(t, clip_seen[0].mask, dock.PRESENT_CLIP)
	testing.expect_value(t, clip_seen[0].event_kind, u8(1))
	testing.expect_value(t, clip_seen[0].w, i32(65536))
	testing.expect_value(t, clip_seen[1].mask, dock.PRESENT_EVENT)
	testing.expect_value(t, clip_seen[1].x, i32(0))
	testing.expect_value(t, clip_seen[1].y, i32(0))
	testing.expect_value(t, clip_seen[1].w, i32(math.round(win.frame.w)))
	testing.expect_value(t, clip_seen[1].h, i32(math.round(win.frame.h)))
	e.viewport_clip_sync(&m, m.spaces[0])
	testing.expect_value(t, clip_count, 2)
}
