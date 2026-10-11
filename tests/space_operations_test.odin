package tests

import e "../src/engine"
import "core:testing"

@(test)
space_moves_and_swaps_resolve_position_not_insert_after :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	e.add_space(&m, 200, 10, 2, {0, 0, 1000, 800})
	e.add_space(&m, 300, 10, 3, {0, 0, 1000, 800})
	e.add_space(&m, 400, 10, 4, {0, 0, 1000, 800})
	testing.expect(t, !e.space_command(&m, []string{"4", "--move", "1"}).failed)
	testing.expect_value(t, m.spaces[0].id, u64(400))
	testing.expect_value(t, m.spaces[1].id, u64(100))
	testing.expect(t, !e.space_command(&m, []string{"1", "--swap", "4"}).failed)
	testing.expect_value(t, m.spaces[0].id, u64(300))
	testing.expect_value(t, m.spaces[3].id, u64(400))
	testing.expect(t, !e.space_command(&m, []string{"1", "--swap", "2"}).failed)
	testing.expect_value(t, m.spaces[0].id, u64(100))
	testing.expect_value(t, m.spaces[1].id, u64(300))
	r.fail = true
	testing.expect(t, e.space_command(&m, []string{"1", "--move", "4"}).failed)
	testing.expect_value(t, m.spaces[0].id, u64(100))
}

@(test)
cross_display_space_swaps_move_windows_and_compensate_failure :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	append(&m.displays, e.Display{id = 20, index = 2, active_space = 200})
	s := e.add_space(&m, 200, 20, 2, {1000, 0, 1000, 800})
	e.add_window(
		&m,
		e.Window {
			id = 3,
			space = 200,
			display = 20,
			role = "AXWindow",
			subrole = "AXStandardWindow",
		},
	)
	r.fail_at = 2
	testing.expect(t, e.space_command(&m, []string{"1", "--swap", "2"}).failed)
	testing.expect_value(t, m.windows[1].space, u64(100))
	testing.expect_value(t, m.windows[3].space, u64(200))
	r.fail_at = 0
	testing.expect(t, !e.space_command(&m, []string{"1", "--swap", "2"}).failed)
	testing.expect_value(t, m.windows[1].space, u64(200))
	testing.expect_value(t, m.windows[2].space, u64(200))
	testing.expect_value(t, m.windows[3].space, u64(100))
	testing.expect(t, e.find(s.view.root, 1) != nil && e.find(s.view.root, 3) == nil)
	testing.expect(t, e.space_command(&m, []string{"1", "--move", "2"}).failed)
	testing.expect(t, !e.space_command(&m, []string{"1", "--display", "2"}).failed)
	testing.expect(t, !e.space_command(&m, []string{"--create", "2"}).failed)
	testing.expect_value(t, r.actions[len(r.actions) - 1].space, u64(200))
}
