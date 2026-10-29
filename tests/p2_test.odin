package tests

import mac "../src"
import "base:runtime"
import "core:encoding/json"
import "core:mem"
import "core:strings"
import posix "core:sys/posix"
import "core:testing"
import "core:time"

@(test)
unmatched_and_appearance_rules_preserve_existing_splits_and_stacks :: proc(t: ^testing.T) {
	m: mac.Manager;r: Recorder;fixture(&m, &r)
	defer mac.manager_destroy(&m);defer delete(r.actions)
	s := mac.space_by_id(&m, 100);s.view.root.ratio = 0.7
	mac.flush(&m, s)
	root := s.view.root;first := mac.find(root, 1);second := mac.find(root, 2)
	testing.expect(
		t,
		!mac.execute(&m, []string{"rule", "--apply", "app=^NoMatch$", "manage=off"}).failed,
	)
	testing.expect_value(t, s.view.root.ratio, f64(0.7))
	testing.expect(t, mac.find(root, 1) == first && mac.find(root, 2) == second)
	testing.expect(
		t,
		!mac.execute(&m, []string{"rule", "--apply", "app=^Terminal$", "opacity=0.5"}).failed,
	)
	testing.expect_value(t, s.view.root.ratio, f64(0.7))
	testing.expect(t, mac.find(root, 1) == first && mac.find(root, 2) == second)
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
	testing.expect(t, mac.find(mac.space_by_id(&m, 100).view.root, 3) == nil)
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
	testing.expect(t, mac.find(mac.space_by_id(&m, 100).view.root, 1) != nil)
	testing.expect_value(t, target.view.root.count, mac.MAX_STACK)
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
	testing.expect(t, mac.find(s.view.root, 1) == nil)
	s.visible = false
	testing.expect(t, mac.window_json(&m, m.windows[1]).is_visible)
	m.windows[1].hidden = true
	testing.expect(t, !mac.window_json(&m, m.windows[1]).is_visible)
	m.windows[1].hidden = false
	testing.expect(t, !mac.execute(&m, []string{"window", "1", "--toggle", "sticky"}).failed)
	testing.expect(t, mac.find(s.view.root, 1) != nil)
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
	testing.expect(t, mac.find(mac.space_by_id(&m, 100).view.root, w.id) == nil)
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
	testing.expect(t, mac.find(s.view.root, 1) == nil && mac.find(s.view.root, 2) != nil)
	testing.expect(
		t,
		!mac.execute(&m, []string{"rule", "--apply", "app=^Terminal$", "sticky=off"}).failed,
	)
	testing.expect(t, mac.find(s.view.root, 1) != nil && mac.find(s.view.root, 2) != nil)
	r.fail = true
	testing.expect(t, mac.execute(&m, []string{"window", "1", "--toggle", "sticky"}).failed)
	testing.expect(t, !m.windows[1].sticky && mac.find(s.view.root, 1) != nil)
}

@(test)
command_server_services_complete_client_while_other_client_trickles_header :: proc(t: ^testing.T) {
	server: mac.Command_Server;m: mac.Manager;mac.manager_init(&m)
	defer mac.manager_destroy(&m);defer mac.command_server_stop(&server)
	slow, fast: [2]i32
	if !testing.expect_value(t, socketpair(1, 1, 0, &slow), i32(0)) {return}
	defer mac.close(slow[0])
	if !testing.expect_value(t, socketpair(1, 1, 0, &fast), i32(0)) {mac.close(slow[1]);return}
	defer mac.close(fast[0])
	testing.expect(t, mac.command_accept(&server, slow[1]))
	testing.expect(t, mac.command_accept(&server, fast[1]))
	deadline := server.clients[0].deadline
	data, _ := mac.encode_message([]string{"query", "--windows"});defer delete(data)
	byte := []u8{0}
	testing.expect(t, mac.write_all(slow[0], byte))
	testing.expect(t, mac.write_all(fast[0], data))
	mac.command_server_tick(&server, &m)
	testing.expect_value(t, len(server.clients), 1)
	response: [32]u8
	n := mac.recv(fast[0], &response[0], len(response), 0x80)
	if testing.expect(t, n > 0) {testing.expect_value(t, string(response[:n]), "[]\n")}
	testing.expect(t, mac.write_all(slow[0], byte))
	mac.command_server_tick(&server, &m, time.time_add(deadline, -time.Second))
	testing.expect_value(t, len(server.clients), 1)
	testing.expect_value(t, server.clients[0].deadline, deadline)
	mac.command_server_tick(&server, &m, time.time_add(deadline, time.Millisecond))
	testing.expect_value(t, len(server.clients), 0)
}

Slow_Writer :: struct {
	fd: i32,
}
write_slow_bytes :: proc "c" (user: rawptr) -> rawptr {
	context = runtime.default_context()
	fd := (^Slow_Writer)(user).fd;byte: u8 = 0
	for _ in 0 ..< 8 {if mac.send(fd, &byte, 1, 0) <= 0 {break};time.sleep(50 * time.Millisecond)}
	return nil
}
@(test)
read_exact_deadline_is_not_reset_by_each_received_byte :: proc(t: ^testing.T) {
	fds: [2]i32
	if !testing.expect_value(t, socketpair(1, 1, 0, &fds), i32(0)) {return}
	defer mac.close(fds[0]);defer mac.close(fds[1])
	mac.prepare_socket(fds[0]);mac.prepare_socket(fds[1])
	writer := Slow_Writer{fds[0]};thread: posix.pthread_t
	if !testing.expect(
		t,
		posix.pthread_create(&thread, nil, write_slow_bytes, &writer) == nil,
	) {return}
	defer posix.pthread_join(thread)
	buffer: [8]u8
	testing.expect(
		t,
		!mac.read_exact(fds[1], buffer[:], time.time_add(time.now(), 120 * time.Millisecond)),
	)
}

@(test)
command_response_owns_data_across_tick_arena_and_backpressure :: proc(t: ^testing.T) {
	server: mac.Command_Server;m: mac.Manager;r: Recorder;fixture(&m, &r)
	defer mac.manager_destroy(&m);defer delete(r.actions);defer mac.command_server_stop(&server)
	delete(m.windows[1].title)
	m.windows[1].title = strings.clone(strings.repeat("x", 512 * 1024, context.temp_allocator))
	expected := strings.concatenate({mac.query(&m, []string{"--windows"}).text, "\n"})
	defer delete(expected)
	fds: [2]i32
	if !testing.expect_value(t, socketpair(1, 1, 0, &fds), i32(0)) {return}
	defer mac.close(fds[0])
	testing.expect(t, mac.command_accept(&server, fds[1]))
	data, _ := mac.encode_message([]string{"query", "--windows"});defer delete(data)
	testing.expect(t, mac.write_all(fds[0], data))
	scratch: mem.Dynamic_Arena;mem.dynamic_arena_init(&scratch)
	{
		context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
		mac.command_server_tick(&server, &m)
	}
	mem.dynamic_arena_destroy(&scratch)
	testing.expect_value(t, len(server.clients), 1)
	output := make([dynamic]u8);defer delete(output)
	buffer: [65536]u8
	for _ in 0 ..< 100 {
		n := mac.recv(fds[0], &buffer[0], len(buffer), 0x80)
		if n > 0 {append(&output, ..buffer[:n])}
		if n == 0 {break}
		mac.command_server_tick(&server, &m)
	}
	testing.expect_value(t, len(server.clients), 0)
	testing.expect_value(t, len(output), len(expected))
	testing.expect(t, string(output[:]) == expected, "response bytes changed across ticks")
}

@(test)
command_server_executes_only_after_complete_fragmented_message :: proc(t: ^testing.T) {
	server: mac.Command_Server;m: mac.Manager;mac.manager_init(&m)
	defer mac.manager_destroy(&m);defer mac.command_server_stop(&server)
	fds: [2]i32
	if !testing.expect_value(t, socketpair(1, 1, 0, &fds), i32(0)) {return}
	defer mac.close(fds[0])
	testing.expect(t, mac.command_accept(&server, fds[1]))
	data, _ := mac.encode_message([]string{"config", "window_gap", "12"});defer delete(data)
	for i in 0 ..< len(data) {
		testing.expect(t, mac.write_all(fds[0], data[i:i + 1]))
		mac.command_server_tick(&server, &m)
		if i < len(data) - 1 {testing.expect_value(t, m.gap, f64(0))}
	}
	testing.expect_value(t, m.gap, f64(12))
	testing.expect_value(t, len(server.clients), 0)
	buffer: [16]u8
	n := mac.recv(fds[0], &buffer[0], len(buffer), 0x80)
	if testing.expect(t, n > 0) {testing.expect_value(t, string(buffer[:n]), "\n")}
}

@(test)
command_server_rejects_oversized_length_and_limits_pending_clients :: proc(t: ^testing.T) {
	server: mac.Command_Server;m: mac.Manager;mac.manager_init(&m)
	defer mac.manager_destroy(&m);defer mac.command_server_stop(&server)
	fds: [2]i32
	if !testing.expect_value(t, socketpair(1, 1, 0, &fds), i32(0)) {return}
	defer mac.close(fds[0])
	testing.expect(t, mac.command_accept(&server, fds[1]))
	testing.expect(t, mac.write_all(fds[0], []u8{255, 255, 255, 255}))
	mac.command_server_tick(&server, &m)
	testing.expect_value(t, len(server.clients), 0)
	buffer: [128]u8
	n := mac.recv(fds[0], &buffer[0], len(buffer), 0x80)
	if testing.expect(t, n > 0) {testing.expect_value(t, buffer[0], u8(7))}
	senders := make([dynamic]i32);defer delete(senders)
	defer {for fd in senders {mac.close(fd)}}
	for i in 0 ..= mac.MAX_COMMAND_CLIENTS {
		pair: [2]i32
		if !testing.expect_value(t, socketpair(1, 1, 0, &pair), i32(0)) {return}
		append(&senders, pair[0])
		testing.expect_value(t, mac.command_accept(&server, pair[1]), i < mac.MAX_COMMAND_CLIENTS)
	}
	testing.expect_value(t, len(server.clients), mac.MAX_COMMAND_CLIENTS)
}
