package tests

import e "../src/engine"
import "core:testing"

@(test)
scratchpad_labels_are_unique_and_toggle_without_focused_window :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	testing.expect(t, !e.execute(&m, []string{"window", "1", "--scratchpad", "terminal"}).failed)
	testing.expect(t, m.windows[1].floating)
	testing.expect(t, e.find(e.space_by_id(&m, 100).view.root, 1) == nil)
	testing.expect(t, e.execute(&m, []string{"window", "2", "--scratchpad", "terminal"}).failed)
	e.focus_window(&m, 0)
	testing.expect(t, !e.execute(&m, []string{"window", "--toggle", "terminal"}).failed)
	testing.expect(t, m.windows[1].scratchpad_hidden)
	r.fail = true
	testing.expect(t, e.execute(&m, []string{"window", "--toggle", "terminal"}).failed)
	testing.expect(t, m.windows[1].scratchpad_hidden)
	r.fail = false
	testing.expect(t, !e.execute(&m, []string{"window", "--toggle", "terminal"}).failed)
	testing.expect(t, !m.windows[1].scratchpad_hidden)
	testing.expect_value(t, m.focused, u32(1))
	testing.expect(t, !e.execute(&m, []string{"window", "1", "--scratchpad"}).failed)
	testing.expect_value(t, m.windows[1].scratchpad, "")
	testing.expect(t, e.find(e.space_by_id(&m, 100).view.root, 1) != nil)
}

@(test)
scratchpad_show_moves_to_active_space_and_recovery_orders_all_windows :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	testing.expect(t, !e.execute(&m, []string{"window", "1", "--scratchpad", "terminal"}).failed)
	e.add_space(&m, 200, 10, 2, {0, 0, 1000, 800})
	m.active_space = 200
	testing.expect(t, !e.execute(&m, []string{"window", "--toggle", "terminal"}).failed)
	testing.expect_value(t, m.windows[1].space, u64(200))
	testing.expect(t, !e.execute(&m, []string{"window", "--scratchpad", "recover"}).failed)
}

@(test)
explicit_opacity_survives_focus_and_can_reset_to_automatic :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	testing.expect(t, !e.execute(&m, []string{"window", "1", "--opacity", "0.4"}).failed)
	testing.expect(t, !e.execute(&m, []string{"config", "normal_window_opacity", "0.8"}).failed)
	testing.expect(t, !e.execute(&m, []string{"config", "window_opacity", "on"}).failed)
	testing.expect(t, !e.execute(&m, []string{"window", "--focus", "2"}).failed)
	testing.expect_value(t, m.windows[1].opacity, f64(0.4))
	testing.expect(t, !e.execute(&m, []string{"window", "1", "--opacity", "0.0"}).failed)
	testing.expect_value(t, m.windows[1].opacity, f64(0.8))
	testing.expect(t, !m.windows[1].opacity_override)
}
