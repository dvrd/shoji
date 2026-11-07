package tests

import e "../src"
import "core:strings"
import "core:testing"
import layout "../src/layout"

fail_reorder_and_compensation :: proc(user: rawptr, action: e.Action) -> string {
	r := (^Recorder)(user)
	if r.calls >= 1 {r.fail = true}
	return record(user, action)
}

@(test)
space_reorder_reports_failed_compensation_and_keeps_observed_moves :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	for i in 2 ..= 4 {e.add_space(&m, u64(i * 100), 10, u32(i), {0, 0, 1000, 800})}
	m.backend = fail_reorder_and_compensation
	response := e.space_command(&m, []string{"4", "--move", "1"})
	testing.expect(t, response.failed && strings.contains(response.text, "rollback failed"))
	for space, i in m.spaces {
		testing.expect_value(t, space.index, u32(i + 1))
		testing.expect_value(t, m.displays[0].spaces[i], space.id)
	}
	testing.expect_value(t, m.spaces[0].id, u64(100))
	testing.expect_value(t, m.spaces[1].id, u64(400))
}

@(test)
space_reorder_failures_preserve_every_original_position :: proc(t: ^testing.T) {
	for operation in ([]string{"--move", "--swap"}) {
		for source in ([]string{"1", "2", "3", "4"}) {
			for target in ([]string{"1", "2", "3", "4"}) {
				for fail_at in 1 ..= 2 {
					m: e.Manager;r: Recorder;fixture(&m, &r)
					for i in 2 ..= 4 {e.add_space(&m, u64(i * 100), 10, u32(i), {0, 0, 1000, 800})}
					r.fail_at = fail_at
					response := e.space_command(&m, []string{source, operation, target})
					if response.failed {
						for space, i in m.spaces {
							testing.expect_value(t, space.id, u64((i + 1) * 100))
							testing.expect_value(t, space.index, u32(i + 1))
						}
					}
					e.manager_destroy(&m);delete(r.actions)
				}
			}
		}
	}
}

@(test)
space_reorder_second_failure_restores_original_order :: proc(t: ^testing.T) {
	for operation in ([]string{"--move", "--swap"}) {
		m: e.Manager;r: Recorder;fixture(&m, &r)
		e.add_space(&m, 200, 10, 2, {0, 0, 1000, 800})
		e.add_space(&m, 300, 10, 3, {0, 0, 1000, 800})
		e.add_space(&m, 400, 10, 4, {0, 0, 1000, 800})
		r.fail_at = 2
		testing.expect(t, e.space_command(&m, []string{"4", operation, "1"}).failed)
		for space, i in m.spaces {
			testing.expect_value(t, space.id, u64((i + 1) * 100))
			testing.expect_value(t, space.index, u32(i + 1))
			testing.expect_value(t, m.displays[0].spaces[i], space.id)
		}
		e.manager_destroy(&m);delete(r.actions)
	}
}

@(test)
cross_display_swap_preserves_views_and_space_settings :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	append(&m.displays, e.Display{id = 20, index = 2, active_space = 200, frame = {1000,0,1200,900}, usable = {1000,0,1200,900}})
	a := e.space_by_id(&m, 100)
	b := e.add_space(&m, 200, 20, 2, {1000, 0, 1200, 900})
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
	a.view.root.ratio = 0.7
	a.view.root.left.zoom = a.view.root
	a.view.insertion = 2
	a.view.gap = 17
	a.overrides["window_gap"] = true
	a_root, b_root := a.view.root, b.view.root
	a_frame, b_frame := a.view.frame, b.view.frame
	testing.expect(t, !e.space_command(&m, []string{"1", "--swap", "2"}).failed)
	testing.expect_value(t, b.view.root, a_root)
	testing.expect_value(t, a.view.root, b_root)
	testing.expect_value(t, b.view.root.ratio, f64(0.7))
	testing.expect_value(t, b.view.root.left.zoom, a_root)
	testing.expect_value(t, b.view.insertion, u32(2))
	testing.expect_value(t, b.view.gap, f64(17))
	testing.expect(t, b.overrides["window_gap"] && !a.overrides["window_gap"])
	testing.expect_value(t, a.view.frame, a_frame)
	testing.expect_value(t, b.view.frame, b_frame)
}

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
	testing.expect(t, layout.find(s.view.root, 1) != nil && layout.find(s.view.root, 3) == nil)
	testing.expect(t, e.space_command(&m, []string{"1", "--move", "2"}).failed)
	testing.expect(t, !e.space_command(&m, []string{"1", "--display", "2"}).failed)
	testing.expect(t, !e.space_command(&m, []string{"--create", "2"}).failed)
	testing.expect_value(t, r.actions[len(r.actions) - 1].space, u64(200))
}
