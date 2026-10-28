package tests

import mac "../src/macos"
import e "../src/engine"
import "core:strings"
import "core:testing"

Focus_Check_Record :: struct { calls: int, pid: i32, window: u32, matched: bool }
focus_check_fake :: proc(user: rawptr, pid: i32, window: u32) -> bool {
	r := (^Focus_Check_Record)(user)
	r.calls += 1; r.pid = pid; r.window = window
	return r.matched
}

focus_error_backend :: proc(user: rawptr, action: e.Action) -> string {
	if action.kind != .Focus {return ""}
	return mac.focus_raise_result(-25205, 43, action.window, user, focus_check_fake)
}

@(test)
scroll_keyboard_focus_tracks_a_verified_raise_error :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect(t, !e.execute(&m, {"space", "--layout", "scroll"}).failed)
	check := Focus_Check_Record{matched = true}
	m.backend, m.backend_user = focus_error_backend, &check
	testing.expect(t, !e.execute(&m, {"window", "--focus", "east"}).failed)
	testing.expect_value(t, m.focused, u32(2))
	testing.expect_value(t, check.window, u32(2))
	check.matched = false
	testing.expect(t, e.execute(&m, {"window", "--focus", "west"}).failed)
	testing.expect_value(t, m.focused, u32(2))
}

@(test)
focus_raise_error_is_only_accepted_after_independent_focus_verification :: proc(t: ^testing.T) {
	r: Focus_Check_Record
	testing.expect_value(t, mac.focus_raise_result(0, 42, 99, &r, focus_check_fake), "")
	testing.expect_value(t, r.calls, 0)
	r.matched = true
	testing.expect_value(t, mac.focus_raise_result(-25205, 42, 99, &r, focus_check_fake), "")
	testing.expect_value(t, r.calls, 1)
	testing.expect_value(t, r.pid, i32(42))
	testing.expect_value(t, r.window, u32(99))
	r.matched = false
	err := mac.focus_raise_result(-25205, 42, 99, &r, focus_check_fake)
	testing.expect(t, strings.contains(err, "-25205"))
	testing.expect_value(t, r.calls, 2)
}
