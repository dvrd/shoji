package tests

import mac "../src"
import "core:encoding/json"
import "core:testing"
import layout "../src/layout"

@(test)
unmatched_and_appearance_rules_preserve_existing_splits_and_stacks :: proc(t: ^testing.T) {
	m: mac.Manager;r: Recorder;fixture(&m, &r)
	defer mac.manager_destroy(&m);defer delete(r.actions)
	s := mac.space_by_id(&m, 100);s.view.root.ratio = 0.7
	mac.flush(&m, s)
	root := s.view.root;first := layout.find(root, 1);second := layout.find(root, 2)
	testing.expect(
		t,
		!mac.execute(&m, []string{"rule", "--apply", "app=^NoMatch$", "manage=off"}).failed,
	)
	testing.expect_value(t, s.view.root.ratio, f64(0.7))
	testing.expect(t, layout.find(root, 1) == first && layout.find(root, 2) == second)
	testing.expect(
		t,
		!mac.execute(&m, []string{"rule", "--apply", "app=^Terminal$", "opacity=0.5"}).failed,
	)
	testing.expect_value(t, s.view.root.ratio, f64(0.7))
	testing.expect(t, layout.find(root, 1) == first && layout.find(root, 2) == second)
	mac.execute(&m, []string{"window", "1", "--stack", "2"})
	stack := s.view.root;order := stack.order;windows := stack.windows
	testing.expect(
		t,
		!mac.execute(&m, []string{"rule", "--apply", "app=^NoMatch$", "manage=off"}).failed,
	)
	testing.expect_value(t, s.view.root.count, 2)
	testing.expect_value(t, s.view.root.order, order)
	testing.expect_value(t, s.view.root.windows, windows)
}

@(test)
creation_rule_failure_does_not_prevent_later_management_effect :: proc(t: ^testing.T) {
	m: mac.Manager;r: Recorder;fixture(&m, &r)
	defer mac.manager_destroy(&m);defer delete(r.actions)
	mac.execute(&m, []string{"rule", "--add", "app=^Terminal$", "space=99"})
	mac.execute(&m, []string{"rule", "--add", "app=^Terminal$", "manage=off"})
	w := mac.add_window(
		&m,
		mac.Window {
			id = 3,
			app = "Terminal",
			role = "AXWindow",
			subrole = "AXStandardWindow",
			space = 100,
			display = 10,
		},
	)
	testing.expect(t, w.floating)
	testing.expect(t, layout.find(mac.space_by_id(&m, 100).view.root, 3) == nil)
}

@(test)
full_stack_warp_fails_before_moving_or_removing_source :: proc(t: ^testing.T) {
	m: mac.Manager;r: Recorder;fixture(&m, &r)
	defer mac.manager_destroy(&m);defer delete(r.actions)
	target := mac.add_space(&m, 200, 10, 2, {0, 0, 1000, 800});mac.set_layout(&m, target, .Stack)
	for id in 10 ..< 42 {mac.add_window(&m, mac.Window{id = u32(id), role = "AXWindow", subrole = "AXStandardWindow", space = 200, display = 10})}
	clear(&r.actions)
	testing.expect(t, mac.execute(&m, []string{"window", "1", "--warp", "10"}).failed)
	testing.expect_value(t, len(r.actions), 0)
	testing.expect_value(t, m.windows[1].space, u64(100))
	testing.expect(t, layout.find(mac.space_by_id(&m, 100).view.root, 1) != nil)
	testing.expect_value(t, target.view.root.count, layout.MAX_STACK)
	testing.expect(t, mac.execute(&m, []string{"window", "1", "--space", "2"}).failed)
	testing.expect_value(t, len(r.actions), 0)
	m.windows[10].frame = {0, 0, 1000, 800}
	testing.expect(t, mac.mouse_drop(&m, {window = 1, action = .Move}, 10, {990, 400}) != "")
	testing.expect_value(t, m.windows[1].space, u64(100))
}

@(test)
sticky_toggle_updates_membership_and_inactive_space_visibility :: proc(t: ^testing.T) {
	m: mac.Manager;r: Recorder;fixture(&m, &r)
	defer mac.manager_destroy(&m);defer delete(r.actions)
	s := mac.space_by_id(&m, 100)
	testing.expect(t, !mac.execute(&m, []string{"window", "1", "--toggle", "sticky"}).failed)
	testing.expect(t, !mac.managed(m.windows[1]))
	testing.expect(t, layout.find(s.view.root, 1) == nil)
	s.visible = false
	testing.expect(t, mac.window_json(&m, m.windows[1]).is_visible)
	m.windows[1].hidden = true
	testing.expect(t, !mac.window_json(&m, m.windows[1]).is_visible)
	m.windows[1].hidden = false
	testing.expect(t, !mac.execute(&m, []string{"window", "1", "--toggle", "sticky"}).failed)
	testing.expect(t, layout.find(s.view.root, 1) != nil)
	testing.expect(t, !mac.window_json(&m, m.windows[1]).is_visible)
}

@(test)
window_operation_operands_select_the_requested_window :: proc(t: ^testing.T) {
	m: mac.Manager;r: Recorder;fixture(&m, &r)
	defer mac.manager_destroy(&m);defer delete(r.actions)
	for op in ([]string{"--close", "--minimize", "--deminimize"}) {
		response := mac.execute(&m, []string{"window", op, "2"})
		if !testing.expect(t, !response.failed, response.text) {continue}
		testing.expect_value(t, r.actions[len(r.actions) - 1].window, u32(2))
	}
	testing.expect(t, mac.execute(&m, []string{"window", "--close", "999"}).failed)
	testing.expect(t, mac.execute(&m, []string{"window", "--minimize", "2", "1"}).failed)
}

@(test)
display_label_removal_and_space_switch_syntax :: proc(t: ^testing.T) {
	m: mac.Manager;r: Recorder;fixture(&m, &r)
	defer mac.manager_destroy(&m);defer delete(r.actions)
	mac.execute(&m, []string{"display", "--label", "main"})
	testing.expect(t, !mac.execute(&m, []string{"display", "--label"}).failed)
	testing.expect_value(t, m.displays[0].label, "")
	mac.add_space(&m, 200, 10, 2, {0, 0, 1000, 800})
	response := mac.execute(&m, []string{"display", "--space", "2"})
	if testing.expect(t, !response.failed, response.text) {
		testing.expect_value(t, r.actions[len(r.actions) - 1].kind, mac.Action_Kind.Space_Focus)
		testing.expect_value(t, r.actions[len(r.actions) - 1].space, u64(200))
	}
	append(&m.displays, mac.Display{id = 20, index = 2, active_space = 300})
	mac.add_space(&m, 300, 20, 3, {1000, 0, 1000, 800})
	testing.expect(t, mac.execute(&m, []string{"display", "1", "--space", "3"}).failed)
}

@(test)
query_supports_root_window_and_grabbed_properties :: proc(t: ^testing.T) {
	m: mac.Manager;r: Recorder;fixture(&m, &r)
	defer mac.manager_destroy(&m);defer delete(r.actions)
	response := mac.execute(
		&m,
		[]string{"query", "--windows", "root-window,is-grabbed", "--window", "1"},
	)
	if !testing.expect(t, !response.failed, response.text) {return}
	value, err := json.parse(response.text, allocator = context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	object := value.(json.Object)
	testing.expect_value(t, object["root-window"].(bool), true)
	testing.expect_value(t, object["is-grabbed"].(bool), false)
	m.windows[1].root_window = false;m.windows[1].grabbed = true
	testing.expect(t, !mac.window_json(&m, m.windows[1]).root_window)
	testing.expect(t, mac.window_json(&m, m.windows[1]).is_grabbed)
}

@(test)
failed_creation_rules_retry_and_reserve_one_shot_for_original_window :: proc(t: ^testing.T) {
	m: mac.Manager;r: Recorder;fixture(&m, &r)
	defer mac.manager_destroy(&m);defer delete(r.actions)
	mac.execute(&m, []string{"rule", "--add", "app=^Retry$", "one-shot=on", "opacity=0.4"})
	mac.execute(&m, []string{"rule", "--add", "app=^Retry$", "manage=off"})
	r.fail = true
	w := mac.add_window(
		&m,
		mac.Window {
			id = 3,
			app = "Retry",
			role = "AXWindow",
			subrole = "AXStandardWindow",
			space = 100,
			display = 10,
		},
	)
	testing.expect(t, w.rules_pending && w.rule_error != "" && w.floating)
	testing.expect_value(t, len(m.rules), 2)
	testing.expect_value(t, m.rules[0].pending_window, u32(3))
	r.fail = false
	other := mac.add_window(
		&m,
		mac.Window {
			id = 4,
			app = "Retry",
			role = "AXWindow",
			subrole = "AXStandardWindow",
			space = 100,
			display = 10,
		},
	)
	testing.expect_value(t, other.opacity, f64(0))
	testing.expect(t, !mac.execute(&m, []string{"rule", "--apply"}).failed)
	testing.expect(t, w.rules_pending)
	testing.expect_value(t, len(m.rules), 2)
	testing.expect_value(t, mac.apply_rules(&m, w), "")
	testing.expect(t, !w.rules_pending && w.rule_error == "")
	testing.expect_value(t, w.opacity, f64(0.4))
	testing.expect_value(t, len(m.rules), 1)
	testing.expect(t, layout.find(mac.space_by_id(&m, 100).view.root, w.id) == nil)
}

@(test)
rule_effect_precedence_skips_superseded_failing_destinations :: proc(t: ^testing.T) {
	m: mac.Manager;r: Recorder;fixture(&m, &r)
	defer mac.manager_destroy(&m);defer delete(r.actions)
	mac.execute(&m, []string{"rule", "--add", "app=^Terminal$", "space=99", "manage=on"})
	mac.execute(&m, []string{"rule", "--add", "app=^Terminal$", "space=1", "manage=off"})
	w := mac.add_window(
		&m,
		mac.Window {
			id = 3,
			app = "Terminal",
			role = "AXWindow",
			subrole = "AXStandardWindow",
			space = 100,
			display = 10,
		},
	)
	testing.expect(t, !w.rules_pending && w.floating && w.space == 100)
}

@(test)
sticky_rules_remove_and_reinsert_only_the_matched_window :: proc(t: ^testing.T) {
	m: mac.Manager;r: Recorder;fixture(&m, &r)
	defer mac.manager_destroy(&m);defer delete(r.actions)
	s := mac.space_by_id(&m, 100)
	testing.expect(
		t,
		!mac.execute(&m, []string{"rule", "--apply", "app=^Terminal$", "sticky=on"}).failed,
	)
	testing.expect(t, layout.find(s.view.root, 1) == nil && layout.find(s.view.root, 2) != nil)
	testing.expect(
		t,
		!mac.execute(&m, []string{"rule", "--apply", "app=^Terminal$", "sticky=off"}).failed,
	)
	testing.expect(t, layout.find(s.view.root, 1) != nil && layout.find(s.view.root, 2) != nil)
	r.fail = true
	testing.expect(t, mac.execute(&m, []string{"window", "1", "--toggle", "sticky"}).failed)
	testing.expect(t, !m.windows[1].sticky && layout.find(s.view.root, 1) != nil)
}
