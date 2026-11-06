package tests

import mac "../src"
import "core:testing"

@(test)
qr_sheet_focus_uses_its_tiled_parent_for_keyboard_scroll_navigation :: proc(t: ^testing.T) {
	state: mac.State; r: Recorder; niri_fixture(&state.manager, &r)
	m := &state.manager
	defer mac.manager_destroy(m); defer delete(r.actions)
	niri_open(m, 2); niri_open(m, 3)
	// WhatsApp lists only its document in AXWindows. AXFocusedWindow is an
	// unlisted AXSheet whose AXParent is that document.
	owner := mac.focus_owner(m, m.windows[2].pid, {44939, 2, 0})
	mac.refresh_set_focus(&state, owner)
	testing.expect_value(t, m.focused, u32(2))
	testing.expect(t, !mac.execute(m, {"window", "--focus", "west"}).failed)
	testing.expect_value(t, m.focused, u32(1))
	mac.refresh_set_focus(&state, owner)
	testing.expect(t, !mac.execute(m, {"window", "--focus", "east"}).failed)
	testing.expect_value(t, m.focused, u32(3))
}

@(test)
focus_owner_keeps_independent_windows_and_rejects_foreign_app_ancestors :: proc(t: ^testing.T) {
	m: mac.Manager; r: Recorder; fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	testing.expect_value(t, mac.focus_owner(&m, m.windows[1].pid, {1, 0}), u32(1))
	testing.expect_value(t, mac.focus_owner(&m, 9999, {44939, 1, 0}), u32(44939))
	testing.expect_value(t, mac.focus_owner(&m, 9999, nil), u32(0))
	testing.expect_value(t, mac.focus_owner(&m, 9999, {44939, 0}), u32(44939))
	child := mac.add_window(&m, {id = 9, pid = m.windows[1].pid, role = "AXSheet", root_window = false})
	testing.expect_value(t, mac.focus_owner(&m, child.pid, {9, 1, 0}), u32(1))
	testing.expect_value(t, mac.focus_owner(&m, child.pid, {9, 0}), u32(9))
}
