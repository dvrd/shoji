package tests

import e "../src/engine"
import "core:testing"

@(test)
discovering_a_new_window_does_not_change_the_committed_layout :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	s := e.space_by_id(&m, 100)
	e.flush(&m, s);clear(&r.actions)
	a, b := m.windows[1].frame, m.windows[2].frame
	w := e.discover_window(&m, {id = 30, pid = 42, app = "Mail", role = "AXWindow", subrole = "AXStandardWindow", space = 100, display = 10, frame = {100, 100, 700, 600}})
	testing.expect_value(t, w.opening.phase, e.Opening_Phase.Pending)
	testing.expect(t, !w.floating)
	testing.expect(t, e.find(s.view.root, w.id) == nil)
	e.reconcile_window_memberships(&m)
	e.flush(&m, s)
	testing.expect_value(t, len(r.actions), 0)
	testing.expect_value(t, m.windows[1].frame, a)
	testing.expect_value(t, m.windows[2].frame, b)
	testing.expect(t, e.discover_window(&m, w^) == w)
	testing.expect_value(t, w.opening.phase, e.Opening_Phase.Pending)
}

@(test)
late_completion_preserves_later_focus_and_closed_pending_windows_stay_gone :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	w := e.discover_window(&m, {id = 30, app = "Mail", role = "AXWindow", subrole = "AXStandardWindow", space = 100, frame = {10, 10, 700, 600}})
	e.focus_window(&m, 2)
	e.remove_window(&m, 1)
	admitted, err := e.admit_window(&m, w)
	testing.expect(t, admitted);testing.expect_value(t, err, "")
	testing.expect(t, w.opening.focus_superseded)
	clear(&r.actions)
	testing.expect_value(t, e.finish_opening(&m, w), "")
	testing.expect_value(t, m.focused, u32(2))
	testing.expect_value(t, len(r.actions), 0)
	pending := e.discover_window(&m, {id = 31, app = "Ghostty", role = "AXWindow", subrole = "AXStandardWindow"})
	e.remove_window(&m, pending.id)
	e.reconcile_window_memberships(&m)
	testing.expect(t, m.windows[31] == nil)
	testing.expect(t, e.find(e.space_by_id(&m, 100).view.root, 31) == nil)
}

@(test)
bsp_admission_respects_minimums_and_waits_for_room_without_reflow :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	e.remove_window(&m, 2)
	s := e.space_by_id(&m, 100);s.view.split = .Vertical
	m.windows[1].min_width = 400;e.flush(&m, s);clear(&r.actions)
	w := e.discover_window(&m, {id = 30, app = "Mail", role = "AXWindow", subrole = "AXStandardWindow", space = 100, frame = {10, 10, 800, 600}, min_width = 700})
	admitted, err := e.admit_window(&m, w)
	testing.expect(t, !admitted);testing.expect_value(t, err, "")
	testing.expect_value(t, w.opening.wait, e.Opening_Wait.Space)
	testing.expect(t, !w.floating && e.find(s.view.root, w.id) == nil)
	testing.expect_value(t, m.windows[1].frame, e.Rect{0, 0, 1000, 800})
	for a in r.actions {testing.expect(t, a.kind != .Frame)}
	m.windows[1].min_width = 300
	admitted, err = e.admit_window(&m, w)
	testing.expect(t, admitted);testing.expect_value(t, err, "")
	testing.expect_value(t, m.windows[1].frame, e.Rect{0, 0, 300, 800})
	testing.expect_value(t, w.frame, e.Rect{300, 0, 700, 800})
	testing.expect_value(t, s.view.root.split, e.Split.Vertical)
	testing.expect_value(t, s.view.root.ratio, f64(0.5))
}

@(test)
ready_windows_are_admitted_once_without_waiting_for_earlier_discoveries :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder;fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	s := e.space_by_id(&m, 100);e.flush(&m, s);clear(&r.actions)
	a := e.discover_window(&m, {id = 30, app = "Mail", role = "AXWindow", subrole = "AXStandardWindow", frame = {10, 10, 700, 600}})
	b := e.discover_window(&m, {id = 31, app = "Chrome", role = "AXWindow", subrole = "AXStandardWindow", space = 100, frame = {10, 10, 700, 600}})
	admitted, err := e.admit_window(&m, b)
	testing.expect_value(t, err, "");testing.expect(t, admitted)
	testing.expect(t, e.find(s.view.root, b.id) != nil && e.find(s.view.root, a.id) == nil)
	testing.expect_value(t, a.opening.phase, e.Opening_Phase.Pending)
	testing.expect_value(t, b.opening.phase, e.Opening_Phase.Opening)
	clear(&r.actions)
	admitted, err = e.admit_window(&m, b)
	testing.expect(t, !admitted);testing.expect_value(t, err, "")
	testing.expect_value(t, len(r.actions), 0)
	a.space = 100
	admitted, err = e.admit_window(&m, a)
	testing.expect(t, admitted);testing.expect_value(t, err, "")
}

preparation_wait :: proc(m: ^e.Manager, w: ^e.Window, seed: e.Rect) -> (e.Rect, bool, string) {
	return seed, false, ""
}

@(test)
preparing_windows_stay_outside_layout_rebuilds :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	s := e.space_by_id(&m, 100);e.flush(&m, s)
	before := m.windows[1].frame
	w := e.discover_window(&m, {id = 30, role = "AXWindow", subrole = "AXStandardWindow", space = 100, frame = {20, 20, 700, 600}})
	clear(&r.actions)
	admitted, err := e.admit_window(&m, w, {prepare = preparation_wait})
	testing.expect(t, !admitted);testing.expect_value(t, err, "")
	testing.expect_value(t, m.windows[1].frame, before)
	for a in r.actions {testing.expect(t, a.kind != .Frame)}
	e.set_layout(&m, s, .Scroll)
	testing.expect(t, e.find(s.view.root, w.id) == nil)
	e.set_layout(&m, s, .BSP)
	testing.expect(t, e.find(s.view.root, w.id) == nil)
	admitted, err = e.admit_window(&m, w)
	testing.expect(t, admitted);testing.expect_value(t, err, "")
	testing.expect(t, e.find(s.view.root, w.id) != nil)
}

@(test)
scroll_admission_grows_from_prepared_geometry_without_redistributing_columns :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	s := e.space_by_id(&m, 100);e.set_layout(&m, s, .Scroll)
	m.scroll_animate = true;m.animation_duration = 0.5
	e.flush(&m, s)
	width := e.find(s.view.root, 1).column_width
	w := e.discover_window(&m, {id = 30, role = "AXWindow", subrole = "AXStandardWindow", space = 100, frame = {20, 20, 700, 600}})
	admitted, err := e.admit_window(&m, w)
	testing.expect(t, admitted);testing.expect_value(t, err, "")
	testing.expect_value(t, e.find(s.view.root, 1).column_width, width)
	testing.expect(t, w.scroll_frame.current.w < w.scroll_frame.target.w)
	testing.expect_value(t, w.scroll_frame.current.w, w.opening.seed.w)
	testing.expect(t, s.view.scroll.geometry_active)
}

@(test)
returning_to_original_focus_is_deliberate_and_exclusion_restores_layer :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	w := e.discover_window(&m, {id = 30, role = "AXWindow", subrole = "AXStandardWindow", space = 100, frame = {20, 20, 700, 600}, layer = "normal"})
	e.admit_window(&m, w, {prepare = preparation_wait})
	e.opening_note_focus(&m, m.focused, true)
	testing.expect(t, w.opening.focus_superseded)
	testing.expect_value(t, w.opening.focus_replacement, m.focused)
	w.floating = true
	clear(&r.actions)
	admitted, err := e.admit_window(&m, w)
	testing.expect(t, !admitted);testing.expect_value(t, err, "")
	testing.expect_value(t, w.opening.phase, e.Opening_Phase.Excluded)
	testing.expect_value(t, w.layer, "normal")
	testing.expect_value(t, len(r.actions), 1)
	testing.expect_value(t, r.actions[0].kind, e.Action_Kind.Layer)
	testing.expect_value(t, r.actions[0].value, f64(0))
}

@(test)
explicit_tiled_layout_adopts_existing_windows_without_admitting_pending_ones :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	s := e.space_by_id(&m, 100);e.set_layout(&m, s, .Float)
	w := e.discover_window(&m, {id = 30, role = "AXWindow", subrole = "AXStandardWindow", space = 100, frame = {20, 20, 700, 600}})
	e.admit_window(&m, w)
	testing.expect_value(t, w.opening.phase, e.Opening_Phase.Excluded)
	pending := e.discover_window(&m, {id = 31, role = "AXWindow", subrole = "AXStandardWindow", space = 100, frame = {20, 20, 700, 600}})
	e.set_layout(&m, s, .BSP)
	testing.expect(t, e.find(s.view.root, w.id) != nil)
	testing.expect(t, e.find(s.view.root, pending.id) == nil)
}
