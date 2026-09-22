package tests

import e "../src/engine"
import "core:encoding/json"
import "core:testing"

Recorder :: struct {
	actions: [dynamic]e.Action,
	fail: bool,
}

record :: proc(user: rawptr, a: e.Action) -> string {
	r := (^Recorder)(user)
	if r.fail {
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
	testing.expect(t, e.find(s.view.root, 1) != nil && e.find(s.view.root, 2) != nil)
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
	m: e.Manager; r: Recorder; fixture(&m, &r); defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect(t, !e.window_command(&m, []string{"1", "--raise", "2"}).failed)
	a := r.actions[len(r.actions) - 1]
	testing.expect_value(t, a.kind, e.Action_Kind.Order)
	testing.expect_value(t, a.relative, u32(2)); testing.expect_value(t, a.value, f64(1))
	testing.expect(t, !e.window_command(&m, []string{"1", "--lower"}).failed)
	a = r.actions[len(r.actions) - 1]
	testing.expect_value(t, a.relative, u32(0)); testing.expect_value(t, a.value, f64(-1))
	testing.expect(t, e.window_command(&m, []string{"1", "--raise", "1"}).failed)
	s := e.space_by_id(&m, 100); s.view.padding = {10, 20, 30, 40}
	testing.expect(t, !e.window_command(&m, []string{"1", "--toggle", "pip"}).failed)
	a = r.actions[len(r.actions) - 1]
	testing.expect_value(t, a.kind, e.Action_Kind.Scale)
	testing.expect_value(t, a.frame, e.Rect{30, 10, 930, 770})
}
@(test)
window_appearance_toggles_commit_only_after_backend_success :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; fixture(&m, &r); defer e.manager_destroy(&m); defer delete(r.actions)
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
	m: e.Manager; r: Recorder; fixture(&m, &r); defer e.manager_destroy(&m); defer delete(r.actions)
	s := e.space_by_id(&m, 100); e.flush(&m, s)
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
	w.floating = false; e.add(&s.view, 3, 2); e.flush(&m, s)
	testing.expect(t, e.select_window(&m, "sibling", 1) == nil)
	testing.expect_value(t, e.select_window(&m, "first_nephew", 1).id, u32(2))
	testing.expect_value(t, e.select_window(&m, "second_nephew", 1).id, u32(3))
	testing.expect_value(t, e.select_window(&m, "uncle", 3).id, u32(1))
	testing.expect_value(t, e.select_window(&m, "largest").id, u32(1))
	testing.expect_value(t, e.select_window(&m, "smallest").id, u32(3))
	m.focused = 0
	testing.expect_value(t, e.select_window(&m, "largest").id, u32(1))
}
