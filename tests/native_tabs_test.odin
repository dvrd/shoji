package tests

import e "../src/engine"
import mac "../src/macos"
import "core:testing"

Tab_Probe :: struct {
	observations: map[u32]mac.Window_Observation,
}
tab_probe :: proc(user: rawptr, state: ^mac.State, window: ^e.Window) -> mac.Window_Observation {
	return (^Tab_Probe)(user).observations[window.id]
}
@(test)
ordered_out_tab_is_untiled_invisible_and_not_draggable :: proc(t: ^testing.T) {
	m: e.Manager;rec: Recorder;fixture(&m, &rec)
	defer e.manager_destroy(&m);defer delete(rec.actions)
	w := m.windows[1];w.ordered_in = false;w.manage_override = true
	testing.expect(t, !e.managed(w))
	testing.expect(t, !e.window_json(&m, w).is_visible)
	testing.expect_value(t, e.mouse_begin(&m, 1, .Move, {0, 0}).window, u32(0))
	testing.expect_value(t, e.reconcile_window_memberships(&m), "")
	testing.expect(t, e.find(e.space_by_id(&m, 100).view.root, 1) == nil)
	w.ordered_in = true
	testing.expect_value(t, e.reconcile_window_memberships(&m), "")
	testing.expect(t, e.find(e.space_by_id(&m, 100).view.root, 1) != nil)
	testing.expect(t, !w.minimized && !w.hidden)
}
@(test)
tab_switch_frees_full_stack_before_inserting_active_tab :: proc(t: ^testing.T) {
	m: e.Manager;rec: Recorder;fixture(&m, &rec)
	defer e.manager_destroy(&m);defer delete(rec.actions)
	testing.expect(t, !e.execute(&m, []string{"config", "layout", "stack"}).failed)
	for id in u32(3) ..= 32 {
		e.add_window(
			&m,
			{
				id = id,
				pid = 44,
				role = "AXWindow",
				subrole = "AXStandardWindow",
				space = 100,
				display = 10,
			},
		)
	}
	incoming := e.add_window(
		&m,
		{
			id = 33,
			pid = 44,
			role = "AXWindow",
			subrole = "AXStandardWindow",
			space = 100,
			display = 10,
			ordered_in = false,
		},
	)
	m.windows[1].ordered_in = false;incoming.ordered_in = true
	testing.expect_value(t, e.reconcile_window_memberships(&m), "")
	view := &e.space_by_id(&m, 100).view
	testing.expect_value(t, view.root.count, 32)
	testing.expect(t, e.find(view.root, 1) == nil && e.find(view.root, 33) != nil)
}
@(test)
unchanged_tab_reconciliation_preserves_bsp_nodes_and_ratios :: proc(t: ^testing.T) {
	m: e.Manager;rec: Recorder;fixture(&m, &rec)
	defer e.manager_destroy(&m);defer delete(rec.actions)
	root := e.space_by_id(&m, 100).view.root;root.ratio = 0.72
	left, right := root.left, root.right
	for _ in 0 ..< 3 {testing.expect_value(t, e.reconcile_window_memberships(&m), "")}
	testing.expect(
		t,
		e.space_by_id(&m, 100).view.root == root && root.left == left && root.right == right,
	)
	testing.expect_value(t, root.ratio, f64(0.72))
}
@(test)
inactive_tabs_missing_from_ax_list_retain_identity_and_rule_state :: proc(t: ^testing.T) {
	state: mac.State;rec: Recorder;fixture(&state.manager, &rec)
	defer e.manager_destroy(&state.manager);defer delete(rec.actions)
	state.windows = make(map[u32]mac.Ref);defer delete(state.windows)
	state.windows[1] = rawptr(uintptr(1));state.windows[2] = rawptr(uintptr(2))
	probe := Tab_Probe {
		observations = make(map[u32]mac.Window_Observation),
	}
	defer delete(probe.observations)
	state.window_probe = {tab_probe, &probe}
	seen := make(map[u32]bool);defer delete(seen)
	apps := make(map[i32]bool);defer delete(apps)
	w := state.manager.windows[1];apps[w.pid] = true
	probe.observations[1] = {
		presence   = .Present,
		ordered_in = false,
	}
	probe.observations[2] = {
		presence = .Missing,
	}
	w.rules_pending = true;w.grabbed = true
	mac.retain_unlisted_windows(&state, &seen, apps)
	testing.expect(t, seen[1] && !seen[2])
	testing.expect(t, state.manager.windows[1] == w && w.rules_pending && w.grabbed)
	testing.expect(t, !(w.ordered_in.? or_else true))
	probe.observations[1] = {
		presence = .Unknown,
	}
	delete_key(&seen, 1)
	mac.retain_unlisted_windows(&state, &seen, apps)
	testing.expect(t, seen[1])
	probe.observations[1] = {
		presence = .Reused,
	}
	delete_key(&seen, 1)
	mac.retain_unlisted_windows(&state, &seen, apps)
	testing.expect(t, !seen[1])
	probe.observations[1] = {
		presence   = .Present,
		ordered_in = true,
	}
	delete_key(&apps, w.pid)
	mac.retain_unlisted_windows(&state, &seen, apps)
	testing.expect(t, !seen[1])
}
@(test)
scratchpad_recovery_does_not_order_in_inactive_native_tabs :: proc(t: ^testing.T) {
	m: e.Manager;rec: Recorder;fixture(&m, &rec)
	defer e.manager_destroy(&m);defer delete(rec.actions)
	testing.expect_value(t, e.scratchpad_assign(&m, m.windows[1], "term"), "")
	m.windows[1].ordered_in = false;m.windows[1].scratchpad_hidden = true
	m.windows[2].ordered_in = false
	clear(&rec.actions)
	testing.expect_value(t, e.scratchpad_recover(&m), "")
	testing.expect_value(t, len(rec.actions), 1)
	testing.expect_value(t, rec.actions[0].window, u32(1))
	testing.expect(t, m.windows[1].ordered_in.? or_else false)
	testing.expect(t, !(m.windows[2].ordered_in.? or_else true))
}
@(test)
tab_reference_rebinds_without_duplicate_retains :: proc(t: ^testing.T) {
	state: mac.State
	state.windows = make(map[u32]mac.Ref);defer delete(state.windows)
	old := mac.cf_string("old AX reference");defer mac.CFRelease(old)
	current := mac.cf_string("new AX reference");defer mac.CFRelease(current)
	mac.window_reference_update(&state, 1, old, nil)
	testing.expect(t, state.windows[1] == old)
	mac.window_reference_update(&state, 1, old, nil)
	mac.window_reference_update(&state, 1, current, nil)
	testing.expect(t, state.windows[1] == current)
	mac.window_reference_remove(&state, 1, nil)
	testing.expect(t, 1 not_in state.windows)
}
@(test)
read_only_tab_retention_does_not_mutate_tiling_or_emit_commands :: proc(t: ^testing.T) {
	state: mac.State;rec: Recorder;fixture(&state.manager, &rec)
	defer e.manager_destroy(&state.manager);defer delete(rec.actions)
	state.read_only = true
	state.windows = make(map[u32]mac.Ref);defer delete(state.windows)
	state.windows[1] = rawptr(uintptr(1))
	probe := Tab_Probe {
		observations = make(map[u32]mac.Window_Observation),
	};defer delete(probe.observations)
	state.window_probe = {tab_probe, &probe}
	probe.observations[1] = {
		presence   = .Present,
		ordered_in = false,
	}
	seen := make(map[u32]bool);defer delete(seen)
	apps := make(map[i32]bool);defer delete(apps);apps[42] = true
	root := e.space_by_id(&state.manager, 100).view.root
	mac.retain_unlisted_windows(&state, &seen, apps)
	testing.expect(t, seen[1] && e.find(root, 1) != nil)
	testing.expect_value(t, len(rec.actions), 0)
}
@(test)
flush_never_resizes_an_ordered_out_tab_before_reconciliation :: proc(t: ^testing.T) {
	m: e.Manager;rec: Recorder;fixture(&m, &rec)
	defer e.manager_destroy(&m);defer delete(rec.actions)
	m.windows[1].ordered_in = false
	testing.expect_value(t, e.flush(&m, e.space_by_id(&m, 100)), "")
	for action in rec.actions {testing.expect(t, action.window != 1)}
}
