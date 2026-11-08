package tests

import e "../src"
import "core:testing"

dialog_batch :: proc(_: rawptr, _: []e.Layout_Move) -> bool {return true}

@(test)
dialog_follow_shifts_an_unmanaged_child :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	parent := m.windows[1]
	e.add_window(&m, e.Window {
		id = 9,
		pid = 49,
		role = "AXWindow",
		subrole = "AXStandardWindow",
		space = parent.space,
		display = parent.display,
		floating = true,
		parent = parent.id,
		frame = {100, 80, 200, 120},
	})
	child := m.windows[9]
	testing.expect(t, child != nil && !e.managed(child))
	before := make(map[u32]e.Rect)
	defer delete(before)
	before[parent.id] = parent.frame
	parent.frame.x += 0.2
	e.dialog_follow(&m, m.spaces[0], before)
	testing.expect_value(t, child.frame.x, f64(100))
	parent.frame.x += 39.8
	parent.frame.y += 15
	resize(&r.actions, 0)
	e.dialog_follow(&m, m.spaces[0], before)
	testing.expect_value(t, child.frame.x, f64(140))
	testing.expect_value(t, child.frame.y, f64(95))
	testing.expect_value(t, child.frame.w, f64(200))
	found := false
	for a in r.actions {
		if a.kind == .Frame && a.window == 9 && a.direct {
			found = true
			testing.expect_value(t, a.frame.x, f64(140))
			testing.expect_value(t, a.frame.y, f64(95))
		}
	}
	testing.expect(t, found)
}

@(test)
dialog_follow_joins_a_held_camera_frame :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	parent := m.windows[1]
	e.add_window(&m, e.Window {
		id = 9,
		pid = 49,
		role = "AXWindow",
		subrole = "AXStandardWindow",
		space = parent.space,
		display = parent.display,
		floating = true,
		parent = parent.id,
		frame = {40, 40, 80, 60},
	})
	before := make(map[u32]e.Rect)
	defer delete(before)
	before[parent.id] = parent.frame
	parent.frame.x += 24
	m.camera_hold = true
	m.layout_batch = dialog_batch
	resize(&r.actions, 0)
	e.dialog_follow(&m, m.spaces[0], before)
	child := m.windows[9]
	testing.expect_value(t, child.frame.x, f64(64))
	testing.expect(t, child.server_placed && child.ax_stale)
	testing.expect_value(t, m.camera_held, 1)
	testing.expect_value(t, m.camera_moves[0].window, u32(9))
	testing.expect_value(t, m.camera_moves[0].x, f64(64))
	for a in r.actions {testing.expect(t, a.kind != .Frame || a.window != 9)}
}
