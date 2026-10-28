package tests

import e "../src/engine"
import mac "../src/macos"
import "core:testing"

@(test)
opening_notice_follows_the_blocked_app_across_focus_and_space_changes :: proc(
	t: ^testing.T,
) {
	m: e.Manager
	r: Recorder
	fixture(&m, &r)
	defer e.manager_destroy(&m)
	defer delete(r.actions)
	w := m.windows[1]
	w.pid = 42 // Motion Lab is waiting while Chrome (43) can use the same Space.
	w.opening.phase = .Pending
	w.opening.wait = .Space
	s := e.space_by_id(&m, w.space)
	s.visible = true

	testing.expect(t, mac.opening_notice_space(&m, 42) == s)
	testing.expect(t, mac.opening_notice_space(&m, 43) == nil)
	testing.expect(t, mac.opening_notice_space(&m, 0) == nil)
	testing.expect(t, mac.opening_notice_space(&m, 42) == s)
	s.visible = false
	testing.expect(t, mac.opening_notice_space(&m, 42) == nil)
	s.visible = true
	w.opening.phase = .Admitted
	testing.expect(t, mac.opening_notice_space(&m, 42) == nil)
}

notice_query_count :: proc() -> i32 { return 42 }
notice_unexpected_query :: proc() -> i32 {
	panic("idle notice queried native foreground state")
}
@(test)
opening_notice_skips_native_queries_until_work_or_a_surface_exists :: proc(
	t: ^testing.T,
) {
	state: mac.State; r: Recorder; fixture(&state.manager, &r)
	defer e.manager_destroy(&state.manager); defer delete(r.actions)
	mac.opening_notice_tick(&state, notice_unexpected_query)
	w := state.manager.windows[1]; w.pid = 42
	w.opening.phase = .Pending; w.opening.wait = .Space
	state.opening_windows = make(map[u32]bool)
	defer delete(state.opening_windows)
	state.opening_windows[1] = true
	// Connection zero prevents native surface creation, while exercising the
	// pending foreground/background decision instead of the idle fast path.
	mac.opening_notice_tick(&state, notice_query_count)
	testing.expect(t, mac.opening_notice_space(&state.manager, 42) != nil)
	clear(&state.opening_windows)
	state.opening_notice.id = 1
	mac.opening_notice_tick(&state, notice_query_count)
	testing.expect_value(t, state.opening_notice.id, u32(1))
	state.opening_notice = {}
	mac.opening_notice_tick(&state, notice_unexpected_query)
}
