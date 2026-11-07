package tests

import mac "../src"
import "core:testing"
import "core:time"
import layout "../src/layout"

@(test)
closing_focused_scroll_window_focuses_the_surviving_visible_window :: proc(t: ^testing.T) {
	state: mac.State; r: Recorder; niri_fixture(&state.manager, &r)
	m := &state.manager
	defer mac.manager_destroy(m); defer delete(r.actions)
	niri_open(m, 2); niri_open(m, 3)
	mac.remove_observed_window(&state, 3)
	mac.flush(m, m.spaces[0]); clear(&r.actions)
	mac.close_focus_tick(&state, time.time_add(time.now(), 200 * time.Millisecond))
	testing.expect_value(t, m.focused, u32(2))
	focused := false
	for action in r.actions { if action.kind == .Focus && action.window == 2 { focused = true } }
	testing.expect(t, focused)
}

@(test)
closing_multiple_windows_recovers_to_a_window_that_still_exists :: proc(t: ^testing.T) {
	state: mac.State; r: Recorder; niri_fixture(&state.manager, &r)
	m := &state.manager
	defer mac.manager_destroy(m); defer delete(r.actions)
	niri_open(m, 2); niri_open(m, 3)
	mac.remove_observed_window(&state, 3); mac.remove_observed_window(&state, 2)
	mac.flush(m, m.spaces[0])
	mac.close_focus_tick(&state, time.time_add(time.now(), 200 * time.Millisecond))
	testing.expect_value(t, m.focused, u32(1))
}

@(test)
close_focus_preserves_intervening_focus_and_space_changes :: proc(t: ^testing.T) {
	for switch_space in ([2]bool{false, true}) {
		state: mac.State; r: Recorder; niri_fixture(&state.manager, &r)
		m := &state.manager
		niri_open(m, 2); niri_open(m, 3)
		mac.remove_observed_window(&state, 3); mac.flush(m, m.spaces[0])
		clear(&r.actions)
		if switch_space { m.active_space = 200 } else { mac.focus_window(m, 1) }
		mac.close_focus_tick(&state, time.time_add(time.now(), 200 * time.Millisecond))
		testing.expect_value(t, m.focused, switch_space ? u32(0) : u32(1))
		for action in r.actions { testing.expect(t, action.kind != .Focus) }
		testing.expect_value(t, state.close_focus.space, u64(0))
		mac.manager_destroy(m); delete(r.actions)
	}
}

@(test)
close_focus_retries_transient_backend_failure_and_has_a_deadline :: proc(t: ^testing.T) {
	state: mac.State; r: Recorder; niri_fixture(&state.manager, &r)
	m := &state.manager
	defer mac.manager_destroy(m); defer delete(r.actions)
	niri_open(m, 2)
	mac.remove_observed_window(&state, 2); mac.flush(m, m.spaces[0])
	now := time.now(); r.fail = true
	mac.close_focus_tick(&state, time.time_add(now, 200 * time.Millisecond))
	testing.expect_value(t, m.focused, u32(0))
	r.fail = false
	mac.close_focus_tick(&state, time.time_add(now, 400 * time.Millisecond))
	testing.expect_value(t, m.focused, u32(1))
	niri_open(m, 2)
	mac.remove_observed_window(&state, 2); mac.flush(m, m.spaces[0])
	clear(&r.actions)
	mac.close_focus_tick(&state, time.time_add(time.now(), 3 * time.Second))
	testing.expect_value(t, m.focused, u32(0))
	testing.expect_value(t, state.close_focus.space, u64(0))
	for action in r.actions { testing.expect(t, action.kind != .Focus) }
}

@(test)
close_focus_ignores_offscreen_columns_and_unfocused_window_closes :: proc(t: ^testing.T) {
	state: mac.State; r: Recorder; niri_fixture(&state.manager, &r)
	m := &state.manager
	defer mac.manager_destroy(m); defer delete(r.actions)
	niri_open(m, 2); niri_open(m, 3)
	s := m.spaces[0]
	s.view.scroll.anchor = 0; s.view.scroll.offset = -16
	layout.scroll_update(&s.view)
	candidate := mac.close_focus_candidate(m, s)
	testing.expect(t, candidate == 1 || candidate == 2)
	mac.remove_observed_window(&state, 2)
	testing.expect_value(t, state.close_focus.space, u64(0))
}
