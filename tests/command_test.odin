package tests

import e "../src"
import "core:encoding/json"
import "core:testing"
import layout "../src/layout"

Recorder :: struct {
	actions: [dynamic]e.Action,
	fail:    bool,
	fail_at: int,
	calls:   int,
}

@(test)
chained_float_and_grid_matches_the_hammerspoon_binding :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	response := e.execute(&m, []string{"window", "--toggle", "float", "--grid", "4:4:1:1:2:2"})
	testing.expect(t, !response.failed)
	testing.expect(t, m.windows[1].floating)
	testing.expect_value(t, m.windows[1].frame, e.Rect{250, 200, 500, 400})
	testing.expect(t, !m.windows[2].floating)
}

@(test)
chained_window_operations_stop_after_backend_failure :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	r.fail = true
	testing.expect(t, e.execute(&m, []string{"window", "1", "--focus", "--close"}).failed)
	testing.expect_value(t, r.calls, 1)
}

@(test)
cross_space_swap_rolls_back_failed_second_move :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	s := e.add_space(&m, 200, 10, 2, {0, 0, 1000, 800})
	e.add_window(
		&m,
		e.Window {
			id = 3,
			role = "AXWindow",
			subrole = "AXStandardWindow",
			space = 200,
			display = 10,
		},
	)
	r.fail_at = 2
	testing.expect(t, e.execute(&m, []string{"window", "1", "--swap", "3"}).failed)
	testing.expect_value(t, m.windows[1].space, u64(100))
	testing.expect_value(t, m.windows[3].space, u64(200))
	testing.expect(t, layout.find(s.view.root, 3) != nil && layout.find(s.view.root, 1) == nil)
	testing.expect_value(t, r.actions[len(r.actions) - 1].space, u64(100))
}

record :: proc(user: rawptr, a: e.Action) -> string {
	r := (^Recorder)(user)
	r.calls += 1
	if r.fail || (r.fail_at > 0 && r.calls == r.fail_at) {
		return "injected backend error"
	}
	append(&r.actions, a)
	return ""
}

fixture :: proc(m: ^e.Manager, recorder: ^Recorder) {
	e.manager_init(m, record, recorder)
	m.default_layout = .BSP
	append(
		&m.displays,
		e.Display {
			id = 10,
			index = 1,
			frame = {0, 0, 1000, 800},
			usable = {0, 0, 1000, 800},
			active_space = 100,
		},
	)
	s := e.add_space(m, 100, 10, 1, {0, 0, 1000, 800})
	s.visible = true
	m.active_space = 100
	e.add_window(
		m,
		e.Window {
			id = 1,
			pid = 42,
			app = "Terminal",
			title = "one",
			role = "AXWindow",
			subrole = "AXStandardWindow",
			space = 100,
			display = 10,
		},
	)
	e.add_window(
		m,
		e.Window {
			id = 2,
			pid = 43,
			app = "Editor",
			title = "quote \"and\"\nnewline",
			role = "AXWindow",
			subrole = "AXStandardWindow",
			space = 100,
			display = 10,
		},
	)
	e.focus_window(m, 1)
}
@(test)
config_and_layout_transitions :: proc(t: ^testing.T) {
	m: e.Manager
	r: Recorder
	fixture(&m, &r)
	defer e.manager_destroy(&m)
	defer delete(r.actions)
	testing.expect(t, !e.execute(&m, []string{"config", "window_gap", "20"}).failed)
	testing.expect_value(t, e.execute(&m, []string{"config", "window_gap"}).text, "20")
	testing.expect(t, e.execute(&m, []string{"config", "split_ratio", "NaN"}).failed)
	testing.expect(t, e.execute(&m, []string{"config", "split_ratio", "1.2"}).failed)
	testing.expect(t, e.execute(&m, []string{"config", "typo", "on"}).failed)
	testing.expect(t, !e.execute(&m, []string{"space", "--layout", "stack"}).failed)
	s := e.space_by_id(&m, 100)
	testing.expect_value(t, s.view.root.count, 2)
	testing.expect(t, !e.execute(&m, []string{"space", "--layout", "float"}).failed)
	testing.expect_value(t, s.view.root.count, 0)
	testing.expect(t, !e.execute(&m, []string{"space", "--layout", "bsp"}).failed)
	testing.expect(t, layout.find(s.view.root, 1) != nil && layout.find(s.view.root, 2) != nil)
}

@(test)
global_configuration_preserves_explicit_space_settings :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	testing.expect(
		t,
		!e.execute(&m, []string{"config", "--space", "1", "window_gap", "12"}).failed,
	)
	testing.expect(t, !e.execute(&m, []string{"config", "window_gap", "24"}).failed)
	testing.expect_value(t, e.space_by_id(&m, 100).view.gap, f64(12))
	s := e.add_space(&m, 200, 10, 2, {0, 0, 1000, 800})
	testing.expect_value(t, s.view.gap, f64(24))
	testing.expect(t, !e.execute(&m, []string{"space", "1", "--layout", "stack"}).failed)
	testing.expect(t, !e.execute(&m, []string{"config", "layout", "float"}).failed)
	testing.expect_value(t, e.space_by_id(&m, 100).view.layout, layout.Layout.Stack)
	testing.expect_value(t, s.view.layout, layout.Layout.Float)
	bad := e.execute(&m, []string{"config", "--space", "1", "split_ratio", "NaN"})
	testing.expect(t, bad.failed)
	testing.expect(t, !e.space_by_id(&m, 100).overrides["split_ratio"])
}
@(test)
window_opacity_configuration_updates_focus_states :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r);defer e.manager_destroy(&m);defer delete(r.actions)
	testing.expect(t, !e.execute(&m, []string{"config", "normal_window_opacity", "0.7"}).failed)
	testing.expect(t, !e.execute(&m, []string{"config", "window_opacity", "on"}).failed)
	testing.expect_value(t, m.windows[1].opacity, f64(1))
	testing.expect_value(t, m.windows[2].opacity, f64(0.7))
	testing.expect(t, !e.execute(&m, []string{"window", "--focus", "2"}).failed)
	testing.expect_value(t, m.windows[1].opacity, f64(0.7))
	testing.expect_value(t, m.windows[2].opacity, f64(1))
	testing.expect(t, !e.execute(&m, []string{"config", "window_opacity", "off"}).failed)
	testing.expect_value(t, m.windows[1].opacity, f64(1))
	testing.expect_value(t, m.windows[2].opacity, f64(1))
	testing.expect(t, e.execute(&m, []string{"config", "active_window_opacity", "2"}).failed)
}
@(test)
commands_propagate_backend_failures :: proc(t: ^testing.T) {
	m: e.Manager
	r: Recorder
	fixture(&m, &r)
	defer e.manager_destroy(&m)
	defer delete(r.actions)
	r.fail = true
	response := e.execute(&m, []string{"window", "--focus", "2"})
	testing.expect(t, response.failed)
	testing.expect_value(t, response.text, "injected backend error")
	testing.expect_value(t, m.focused, u32(1))
	r.fail = false
	testing.expect(t, !e.execute(&m, []string{"window", "--focus", "2"}).failed)
	testing.expect_value(t, m.focused, u32(2))
	testing.expect_value(t, m.last_focused, u32(1))
}
@(test)
query_json_escapes_text_and_filters :: proc(t: ^testing.T) {
	m: e.Manager
	r: Recorder
	fixture(&m, &r)
	defer e.manager_destroy(&m)
	defer delete(r.actions)
	response := e.execute(&m, []string{"query", "--windows", "--window", "2"})
	testing.expect(t, !response.failed)
	decoded: e.Window_JSON
	err := json.unmarshal(
		transmute([]u8)response.text,
		&decoded,
		allocator = context.temp_allocator,
	)
	testing.expect(t, err == nil)
	testing.expect_value(t, decoded.id, u32(2))
	testing.expect_value(t, decoded.title, m.windows[2].title)
	testing.expect(t, e.execute(&m, []string{"query", "--windows", "--window", "999"}).failed)
	testing.expect(t, e.execute(&m, []string{"query", "--windows", "bogus"}).failed)
}

@(test)
query_projection_validates_fields_and_retains_array_shape :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	response := e.execute(&m, []string{"query", "--windows", "id,title", "--window", "2"})
	testing.expect(t, !response.failed)
	value, err := json.parse(response.text, allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	object := value.(json.Object)
	testing.expect_value(t, len(object), 2)
	testing.expect_value(t, object["title"].(string), m.windows[2].title)
	response = e.execute(&m, []string{"query", "--windows", "id"})
	value, err = json.parse(response.text, allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, len(value.(json.Array)), 2)
	testing.expect(t, e.execute(&m, []string{"query", "--windows", "no-such-property"}).failed)
}

@(test)
rule_effects_apply_and_invalid_values_are_rejected :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	testing.expect(
		t,
		!e.execute(&m, []string{"rule", "--apply", "app=^Terminal$", "manage=off", "opacity=0.5", "sticky=on", "sub-layer=above", "grid=1:2:0:0:1:1", "scratchpad=terminal", "mouse_follows_focus=on"}).failed,
	)
	w := m.windows[1]
	testing.expect_value(t, w.opacity, f64(0.5))
	testing.expect(t, w.sticky && w.floating)
	testing.expect_value(t, w.scratchpad, "terminal")
	testing.expect_value(t, w.frame, e.Rect{0, 0, 500, 800})
	testing.expect_value(t, w.layer, "above")
	testing.expect(t, e.execute(&m, []string{"rule", "--add", "opacity=NaN"}).failed)
	testing.expect(t, e.execute(&m, []string{"rule", "--add", "grid=1:0:0:0:1:1"}).failed)
	// Rule effects propagate transport errors to the command client.
	r.fail = true
	testing.expect(t, e.execute(&m, []string{"rule", "--apply", "sticky=off"}).failed)
}

@(test)
directional_auto_balance_and_opacity_duration_are_configurable :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	testing.expect(t, !e.execute(&m, []string{"config", "auto_balance", "x-axis"}).failed)
	testing.expect_value(t, e.config(&m, []string{"auto_balance"}).text, "x-axis")
	testing.expect_value(t, e.space_by_id(&m, 100).view.balance_axis, layout.Split.Horizontal)
	testing.expect(t, !e.execute(&m, []string{"config", "window_opacity_duration", "0.25"}).failed)
	testing.expect(t, !e.execute(&m, []string{"config", "window_opacity", "on"}).failed)
	fades := 0
	for action in r.actions {
		if action.kind == .Opacity {fades += 1;testing.expect_value(t, action.duration, f64(0.25))}
	}
	testing.expect_value(t, fades, 2)
}

@(test)
insert_toggle_and_stack_direction_follow_command_contract :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	s := e.space_by_id(&m, 100)
	testing.expect(t, !e.execute(&m, []string{"window", "1", "--insert", "west"}).failed)
	testing.expect_value(t, s.view.insertion, u32(1))
	testing.expect(t, !e.execute(&m, []string{"window", "1", "--insert", "west"}).failed)
	testing.expect_value(t, s.view.insertion, u32(0))
	testing.expect(t, !e.execute(&m, []string{"window", "1", "--stack", "2"}).failed)
	n := layout.find(s.view.root, 1)
	testing.expect_value(t, n.windows[0], u32(1))
	testing.expect_value(t, n.windows[1], u32(2))
}

@(test)
rule_reapply_ignores_one_shots_and_supports_inline_properties :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	testing.expect(
		t,
		!e.execute(&m, []string{"rule", "--add", "one-shot=on", "manage=off"}).failed,
	)
	testing.expect(t, !e.execute(&m, []string{"rule", "--apply"}).failed)
	testing.expect(t, !m.windows[1].floating)
	testing.expect_value(t, len(m.rules), 1)
	testing.expect(
		t,
		!e.execute(&m, []string{"rule", "--apply", "app=^Terminal$", "manage=off"}).failed,
	)
	testing.expect(t, m.windows[1].floating)
	testing.expect(t, !m.windows[2].floating)
	testing.expect_value(t, len(m.rules), 1)
}
@(test)
rule_exclusion_and_one_shot :: proc(t: ^testing.T) {
	m: e.Manager
	r: Recorder
	fixture(&m, &r)
	defer e.manager_destroy(&m)
	defer delete(r.actions)
	response := e.execute(
		&m,
		[]string {
			"rule",
			"--add",
			"label=editors",
			"app=^Editor$",
			"title!=^private",
			"manage=off",
			"one-shot=on",
		},
	)
	testing.expect(t, !response.failed)
	e.apply_rules(&m, m.windows[1])
	testing.expect(t, !m.windows[1].floating)
	e.apply_rules(&m, m.windows[2])
	testing.expect(t, m.windows[2].floating)
	testing.expect_value(t, len(m.rules), 0)
	testing.expect(t, e.execute(&m, []string{"rule", "--add", "app=[", "manage=on"}).failed)
	testing.expect(
		t,
		!e.execute(&m, []string{"signal", "--add", "event=window_created", "action=echo ready", "label=test"}).failed,
	)
	testing.expect(t, !e.execute(&m, []string{"signal", "--remove", "test"}).failed)
	testing.expect_value(t, len(m.signals), 0)
}
@(test)
rule_apply_can_target_one_rule :: proc(t: ^testing.T) {
	m: e.Manager
	r: Recorder
	fixture(&m, &r)
	defer e.manager_destroy(&m)
	defer delete(r.actions)
	testing.expect(
		t,
		!e.execute(&m, []string{"rule", "--add", "label=editor", "app=^Editor$", "manage=off"}).failed,
	)
	testing.expect(t, !e.execute(&m, []string{"rule", "--apply", "editor"}).failed)
	testing.expect(t, !m.windows[1].floating)
	testing.expect(t, m.windows[2].floating)
	s := e.space_by_id(&m, 100)
	testing.expect(t, layout.find(s.view.root, 1) != nil)
	testing.expect(t, layout.find(s.view.root, 2) == nil)
	testing.expect(t, e.execute(&m, []string{"rule", "--apply", "999"}).failed)
	testing.expect(t, e.execute(&m, []string{"rule", "--apply", "1", "2"}).failed)
}
@(test)
invalid_commands_do_not_panic :: proc(t: ^testing.T) {
	m: e.Manager
	r: Recorder
	fixture(&m, &r)
	defer e.manager_destroy(&m)
	defer delete(r.actions)
	cases := [][]string {
		{},
		{"window"},
		{"window", "--ratio", "abs:nan"},
		{"space", "--rotate", "42"},
		{"signal", "--add"},
		{"rule", "--remove"},
		{"display"},
		{"nonsense"},
	}
	for args in cases {
		testing.expect(t, e.execute(&m, args).failed)
	}
}
@(test)
stack_swap_warp_keep_unique_ids :: proc(t: ^testing.T) {
	m: e.Manager
	r: Recorder
	fixture(&m, &r)
	defer e.manager_destroy(&m)
	defer delete(r.actions)
	testing.expect(t, !e.execute(&m, []string{"window", "--swap", "2"}).failed)
	testing.expect(t, !e.execute(&m, []string{"window", "--stack", "2"}).failed)
	s := e.space_by_id(&m, 100)
	testing.expect_value(t, s.view.root.count, 2)
	testing.expect(t, e.execute(&m, []string{"window", "--stack", "2"}).failed)
	testing.expect(t, !e.execute(&m, []string{"window", "--warp", "2"}).failed)
	seen := make(map[u32]bool)
	defer delete(seen)
	testing.expect_value(t, assert_tree(t, s.view.root, nil, &seen), 2)
}

@(test)
cross_space_swap_and_warp_update_both_views :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r);defer e.manager_destroy(&m);defer delete(r.actions)
	append(
		&m.displays,
		e.Display {
			id = 20,
			index = 2,
			frame = {1000, 0, 1000, 800},
			usable = {1000, 0, 1000, 800},
			active_space = 200,
		},
	)
	e.add_space(&m, 200, 20, 2, {1000, 0, 1000, 800})
	e.add_window(
		&m,
		e.Window {
			id = 3,
			app = "Browser",
			role = "AXWindow",
			subrole = "AXStandardWindow",
			space = 200,
			display = 20,
		},
	)
	testing.expect(t, !e.execute(&m, []string{"window", "1", "--swap", "3"}).failed)
	testing.expect_value(t, m.windows[1].space, u64(200))
	testing.expect_value(t, m.windows[3].space, u64(100))
	testing.expect(t, layout.find(e.space_by_id(&m, 100).view.root, 3) != nil)
	testing.expect(t, layout.find(e.space_by_id(&m, 200).view.root, 1) != nil)
	testing.expect(t, !e.execute(&m, []string{"window", "1", "--warp", "3"}).failed)
	testing.expect_value(t, m.windows[1].space, u64(100))
	testing.expect(t, layout.find(e.space_by_id(&m, 100).view.root, 3) != nil)
	testing.expect(t, layout.find(e.space_by_id(&m, 200).view.root, 1) == nil)
	// Two actions for a swap and one for a warp are sent through the payload backend.
	// Frame actions from flushing the affected BSP views are intentionally separate.
	space_actions := 0
	for action in r.actions {
		if action.kind == .Space {space_actions += 1}
	}
	testing.expect_value(t, space_actions, 3)
}

@(test)
directional_display_selection_focuses_the_matching_active_space :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r);defer e.manager_destroy(&m);defer delete(r.actions)
	append(
		&m.displays,
		e.Display {
			id = 20,
			index = 2,
			frame = {1000, 0, 1000, 800},
			usable = {1000, 0, 1000, 800},
			active_space = 200,
		},
	)
	e.add_space(&m, 200, 20, 2, {1000, 0, 1000, 800})
	append(
		&m.displays,
		e.Display {
			id = 30,
			index = 3,
			frame = {0, -800, 1000, 800},
			usable = {0, -800, 1000, 800},
			active_space = 300,
		},
	)
	e.add_space(&m, 300, 30, 3, {0, -800, 1000, 800})
	testing.expect(t, !e.execute(&m, []string{"display", "--focus", "east"}).failed)
	testing.expect_value(t, r.actions[len(r.actions) - 1].kind, e.Action_Kind.Display_Focus)
	testing.expect_value(t, r.actions[len(r.actions) - 1].display, u32(20))
	testing.expect_value(t, r.actions[len(r.actions) - 1].space, u64(200))
	testing.expect(t, !e.execute(&m, []string{"display", "--focus", "north"}).failed)
	testing.expect_value(t, r.actions[len(r.actions) - 1].space, u64(300))
}

@(test)
unchanged_layout_does_not_repeat_accessibility_writes :: proc(t: ^testing.T) {
	m: e.Manager
	r: Recorder
	fixture(&m, &r)
	defer e.manager_destroy(&m)
	defer delete(r.actions)
	s := e.space_by_id(&m, 100)
	testing.expect_value(t, e.flush(&m, s), "")
	count := len(r.actions)
	testing.expect_value(t, e.flush(&m, s), "")
	testing.expect_value(t, len(r.actions), count)
}

@(test)
rules_use_posix_character_classes :: proc(t: ^testing.T) {
	filter: e.Filter
	defer e.filter_destroy(&filter)
	testing.expect(t, e.filter_set(&filter, "^[[:alpha:]]+[[:digit:]]{2}$", false))
	testing.expect(t, e.filter_matches(filter, "Editor42"))
	testing.expect(t, !e.filter_matches(filter, "Editor4"))
	testing.expect(t, !e.filter_set(&filter, "[", false))
	testing.expect(t, e.filter_matches(filter, "Editor42"))
}

@(test)
window_order_and_pip_dispatch_correct_payload_arguments :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r);defer e.manager_destroy(&m);defer delete(r.actions)
	testing.expect(t, !e.window_command(&m, []string{"1", "--raise", "2"}).failed)
	a := r.actions[len(r.actions) - 1]
	testing.expect_value(t, a.kind, e.Action_Kind.Order)
	testing.expect_value(t, a.relative, u32(2));testing.expect_value(t, a.value, f64(1))
	testing.expect(t, !e.window_command(&m, []string{"1", "--lower"}).failed)
	a = r.actions[len(r.actions) - 1]
	testing.expect_value(t, a.relative, u32(0));testing.expect_value(t, a.value, f64(-1))
	testing.expect(t, e.window_command(&m, []string{"1", "--raise", "1"}).failed)
	s := e.space_by_id(&m, 100);s.view.padding = {10, 20, 30, 40}
	testing.expect(t, !e.window_command(&m, []string{"1", "--toggle", "pip"}).failed)
	a = r.actions[len(r.actions) - 1]
	testing.expect_value(t, a.kind, e.Action_Kind.Scale)
	testing.expect_value(t, a.frame, e.Rect{30, 10, 930, 770})
}
@(test)
window_appearance_toggles_commit_only_after_backend_success :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r);defer e.manager_destroy(&m);defer delete(r.actions)
	w := m.windows[1]
	testing.expect(t, !e.window_command(&m, []string{"1", "--toggle", "sticky"}).failed)
	testing.expect(t, w.sticky)
	testing.expect(t, !e.window_command(&m, []string{"1", "--toggle", "sticky"}).failed)
	testing.expect(t, !w.sticky)
	testing.expect(t, !e.window_command(&m, []string{"1", "--toggle", "shadow"}).failed)
	testing.expect(t, w.shadow)
	testing.expect(t, !e.window_command(&m, []string{"1", "--opacity", "0.5"}).failed)
	testing.expect_value(t, w.opacity, f64(0.5))
	testing.expect(t, !e.window_command(&m, []string{"1", "--sub-layer", "above"}).failed)
	testing.expect_value(t, w.layer, "above")
	r.fail = true
	testing.expect(t, e.window_command(&m, []string{"1", "--toggle", "shadow"}).failed)
	testing.expect(t, w.shadow)
	testing.expect(t, e.window_command(&m, []string{"1", "--opacity", "1"}).failed)
	testing.expect_value(t, w.opacity, f64(0.5))
}

@(test)
window_family_and_area_selectors_follow_tree_structure :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r);defer e.manager_destroy(&m);defer delete(r.actions)
	s := e.space_by_id(&m, 100);e.flush(&m, s)
	testing.expect_value(t, e.select_window(&m, "sibling", 1).id, u32(2))
	testing.expect(t, e.select_window(&m, "uncle", 1) == nil)
	// Splitting the sibling makes it an internal node, so sibling must not
	// silently descend to its first leaf.
	w := e.add_window(
		&m,
		e.Window {
			id = 3,
			space = 100,
			role = "AXWindow",
			subrole = "AXStandardWindow",
			floating = true,
		},
	)
	w.floating = false;layout.add(&s.view, 3, 2);e.flush(&m, s)
	testing.expect(t, e.select_window(&m, "sibling", 1) == nil)
	testing.expect_value(t, e.select_window(&m, "first_nephew", 1).id, u32(2))
	testing.expect_value(t, e.select_window(&m, "second_nephew", 1).id, u32(3))
	testing.expect_value(t, e.select_window(&m, "uncle", 3).id, u32(1))
	testing.expect_value(t, e.select_window(&m, "largest").id, u32(1))
	testing.expect_value(t, e.select_window(&m, "smallest").id, u32(3))
	m.focused = 0
	testing.expect_value(t, e.select_window(&m, "largest").id, u32(1))
}

@(test)
window_space_move_carries_destination_tile_landing :: proc(t: ^testing.T) {
	m: e.Manager
	r: Recorder
	fixture(&m, &r)
	defer e.manager_destroy(&m)
	defer delete(r.actions)
	other := e.add_space(&m, 200, 10, 2, {0, 0, 1000, 800})
	other.view.layout = .BSP
	e.add_window(&m, e.Window{id = 3, pid = 44, app = "Notes", role = "AXWindow", subrole = "AXStandardWindow", space = 200, display = 10})
	clear(&r.actions)
	testing.expect(t, !e.execute(&m, []string{"window", "1", "--space", "2"}).failed)
	landing: e.Rect
	for a in r.actions {if a.kind == .Space && a.window == 1 {landing = a.frame}}
	testing.expect(t, landing.w > 0 && landing.h > 0)
	n := layout.find(other.view.root, 1)
	testing.expect(t, n != nil)
	if n != nil {testing.expect_value(t, layout.frame_for(n), landing)}
	testing.expect(t, layout.find(e.space_by_id(&m, 100).view.root, 1) == nil)
}

@(test)
window_space_move_failure_unstages_destination :: proc(t: ^testing.T) {
	m: e.Manager
	r: Recorder
	fixture(&m, &r)
	defer e.manager_destroy(&m)
	defer delete(r.actions)
	other := e.add_space(&m, 200, 10, 2, {0, 0, 1000, 800})
	other.view.layout = .BSP
	e.add_window(&m, e.Window{id = 3, pid = 44, app = "Notes", role = "AXWindow", subrole = "AXStandardWindow", space = 200, display = 10})
	r.fail = true
	testing.expect(t, e.execute(&m, []string{"window", "1", "--space", "2"}).failed)
	testing.expect(t, layout.find(other.view.root, 1) == nil)
	testing.expect(t, layout.find(e.space_by_id(&m, 100).view.root, 1) != nil)
	testing.expect_value(t, m.windows[1].space, 100)
}

@(test)
window_space_move_to_float_space_has_no_landing :: proc(t: ^testing.T) {
	m: e.Manager
	r: Recorder
	fixture(&m, &r)
	defer e.manager_destroy(&m)
	defer delete(r.actions)
	other := e.add_space(&m, 200, 10, 2, {0, 0, 1000, 800})
	other.view.layout = .Float
	clear(&r.actions)
	testing.expect(t, !e.execute(&m, []string{"window", "1", "--space", "2"}).failed)
	for a in r.actions {if a.kind == .Space {testing.expect_value(t, a.frame, e.Rect{})}}
}

Batch_Recorder :: struct {
	calls: int,
	moves: [dynamic]e.Layout_Move,
	result: bool,
}
@(thread_local) batch_recorder: Batch_Recorder

record_batch :: proc(user: rawptr, moves: []e.Layout_Move) -> bool {
	batch_recorder.calls += 1
	for move in moves {append(&batch_recorder.moves, move)}
	return batch_recorder.result
}

batch_fixture :: proc(m: ^e.Manager, r: ^Recorder) {
	fixture(m, r)
	m.layout_batch = record_batch
	batch_recorder = {result = true}
	// Settle the initial tiles so the next change is a pure move.
	testing_flush_all(m)
	clear(&r.actions)
	batch_recorder.calls = 0
	clear(&batch_recorder.moves)
}

testing_flush_all :: proc(m: ^e.Manager) {
	for s in m.spaces {e.flush(m, s)}
}

@(test)
layout_batch_pre_applies_moves_then_resyncs_every_window :: proc(t: ^testing.T) {
	m: e.Manager
	r: Recorder
	batch_fixture(&m, &r)
	defer e.manager_destroy(&m)
	defer delete(r.actions)
	defer delete(batch_recorder.moves)
	testing.expect(t, !e.execute(&m, []string{"window", "1", "--swap", "2"}).failed)
	testing.expect_value(t, batch_recorder.calls, 1)
	testing.expect_value(t, len(batch_recorder.moves), 2)
	// Owning apps are not told about server-side moves; the per-window frame
	// writes must still follow the batch.
	frames := 0
	for a in r.actions {if a.kind == .Frame {frames += 1}}
	testing.expect_value(t, frames, 2)
	for move in batch_recorder.moves {
		testing.expect_value(t, m.windows[move.window].frame.x, move.x)
		testing.expect_value(t, m.windows[move.window].frame.y, move.y)
		// The resync write must not trust WindowServer's (already moved) bounds.
		testing.expect(t, m.windows[move.window].server_placed)
	}
}

@(test)
layout_batch_skips_resizes_and_animation :: proc(t: ^testing.T) {
	m: e.Manager
	r: Recorder
	batch_fixture(&m, &r)
	defer e.manager_destroy(&m)
	defer delete(r.actions)
	defer delete(batch_recorder.moves)
	// A third window resizes the existing tiles: not position-only.
	e.add_window(&m, e.Window{id = 3, pid = 44, app = "Notes", role = "AXWindow", subrole = "AXStandardWindow", space = 100, display = 10})
	testing_flush_all(&m)
	testing.expect_value(t, batch_recorder.calls, 0)
	// Animated moves keep today's animation path.
	m.animation_duration = 0.2
	clear(&r.actions)
	testing.expect(t, !e.execute(&m, []string{"window", "1", "--swap", "2"}).failed)
	testing.expect_value(t, batch_recorder.calls, 0)
}

@(test)
layout_batch_failure_still_applies_frames :: proc(t: ^testing.T) {
	m: e.Manager
	r: Recorder
	batch_fixture(&m, &r)
	defer e.manager_destroy(&m)
	defer delete(r.actions)
	defer delete(batch_recorder.moves)
	batch_recorder.result = false
	testing.expect(t, !e.execute(&m, []string{"window", "1", "--swap", "2"}).failed)
	testing.expect_value(t, batch_recorder.calls, 1)
	testing.expect(t, !m.windows[1].server_placed && !m.windows[2].server_placed)
	frames := 0
	for a in r.actions {if a.kind == .Frame {frames += 1}}
	testing.expect_value(t, frames, 2)
}
