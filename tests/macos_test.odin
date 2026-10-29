package tests

import mac "../src"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"

foreign import libc "system:c"
foreign libc {
	socketpair :: proc(domain, type, protocol: i32, fds: ^[2]i32) -> i32 ---
}

@(test)
objc_and_corefoundation_round_trip :: proc(t: ^testing.T) {
	pool := mac.pool_push()
	defer mac.pool_pop(pool)
	value := mac.cf_string("Odin → macOS 日本語")
	defer mac.CFRelease(value)
	testing.expect_value(t, mac.text(value), "Odin → macOS 日本語")
}

@(test)
unix_socket_protocol_survives_fragmented_writes :: proc(t: ^testing.T) {
	fds: [2]i32
	if !testing.expect_value(t, socketpair(1, 1, 0, &fds), i32(0)) {
		return
	}
	defer mac.close(fds[0])
	defer mac.close(fds[1])
	mac.prepare_socket(fds[0])
	mac.prepare_socket(fds[1])
	data, ok := mac.encode_message([]string{"query", "--windows"})
	testing.expect(t, ok)
	defer delete(data)
	for i in 0 ..< len(data) {
		testing.expect(t, mac.write_all(fds[0], data[i:i + 1]))
	}
	received := make([]u8, len(data))
	defer delete(received)
	testing.expect(t, mac.read_exact(fds[1], received))
	testing.expect_value(t, string(received), string(data))
	mac.shutdown(fds[0], 1)
	buffer: [1]u8
	testing.expect(t, !mac.read_exact(fds[1], buffer[:]))
}

@(test)
socket_path_is_user_scoped_and_bounded :: proc(t: ^testing.T) {
	addr, ok := mac.address(mac.socket_path())
	testing.expect(t, ok)
	testing.expect_value(t, addr.family, u8(1))
	long: [105]u8
	for &c in long {
		c = 'x'
	}
	_, accepted := mac.address(string(long[:]))
	testing.expect(t, !accepted)
}

@(test)
server_returns_failure_marker_for_invalid_command :: proc(t: ^testing.T) {
	fds: [2]i32
	if !testing.expect_value(t, socketpair(1, 1, 0, &fds), i32(0)) {
		return
	}
	defer mac.close(fds[0])
	mac.prepare_socket(fds[0])
	data, ok := mac.encode_message([]string{"not-a-domain"})
	testing.expect(t, ok)
	defer delete(data)
	testing.expect(t, mac.write_all(fds[0], data))
	mac.shutdown(fds[0], 1)
	manager: mac.Manager
	mac.manager_init(&manager)
	defer mac.manager_destroy(&manager)
	server: mac.Command_Server
	defer mac.command_server_stop(&server)
	if !testing.expect(t, mac.command_accept(&server, fds[1])) {
		return
	}
	mac.command_server_tick(&server, &manager)
	testing.expect_value(t, len(server.clients), 0)
	response: [256]u8
	size := mac.recv(fds[0], &response[0], len(response), 0)
	testing.expect(t, size > 1)
	testing.expect_value(t, response[0], u8(7))
}

@(test)
server_returns_query_response_over_socket :: proc(t: ^testing.T) {
	fds: [2]i32
	if !testing.expect_value(t, socketpair(1, 1, 0, &fds), i32(0)) {
		return
	}
	defer mac.close(fds[0])
	mac.prepare_socket(fds[0])
	data, ok := mac.encode_message([]string{"query", "--windows"})
	testing.expect(t, ok)
	defer delete(data)
	testing.expect(t, mac.write_all(fds[0], data))
	mac.shutdown(fds[0], 1)
	manager: mac.Manager
	mac.manager_init(&manager)
	defer mac.manager_destroy(&manager)
	server: mac.Command_Server
	defer mac.command_server_stop(&server)
	if !testing.expect(t, mac.command_accept(&server, fds[1])) {
		return
	}
	mac.command_server_tick(&server, &manager)
	testing.expect_value(t, len(server.clients), 0)
	response: [256]u8
	size := mac.recv(fds[0], &response[0], len(response), 0)
	testing.expect(t, size > 0)
	if size > 0 {
		testing.expect_value(t, string(response[:size]), "[]\n")
	}
}

@(test)
socket_readiness_wakes_the_current_loop_and_rearms_without_owning_fd :: proc(
	t: ^testing.T,
) {
	fds: [2]i32
	if !testing.expect_value(t, socketpair(1, 1, 0, &fds), i32(0)) {
		return
	}
	defer mac.close(fds[0]); defer mac.close(fds[1])
	watch: mac.Socket_Watch; defer mac.socket_watch_stop(&watch)
	if !testing.expect(t, mac.socket_watch_start(&watch, fds[1], 1)) {
		return
	}
	for _ in 0 ..< 3 {
		testing.expect(t, mac.write_all(fds[0], []u8{42}))
		testing.expect_value(
			t,
			mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, .25, true),
			i32(4),
		)
		byte: u8
		testing.expect_value(t, mac.recv(fds[1], &byte, 1, 0x80), 1)
		testing.expect_value(t, byte, u8(42))
		mac.socket_watch_arm(&watch, 1)
	}
	mac.socket_watch_stop(&watch)
	testing.expect(t, mac.write_all(fds[0], []u8{7}))
	byte: u8; testing.expect_value(t, mac.recv(fds[1], &byte, 1, 0x80), 1)
}

@(test)
event_driven_listener_and_fragmented_client_wake_without_executing_callbacks :: proc(
	t: ^testing.T,
) {
	path := fmt.tprintf(
		"/tmp/shoji-readiness-%d-%d",
		mac.getpid(),
		time.tick_now()._nsec,
	)
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	defer mac.unlink(cpath)
	fd := mac.socket(1, 1, 0)
	if !testing.expect(t, fd >= 0) {
		return
	}
	defer mac.close(fd)
	address, valid := mac.address(path)
	if !testing.expect(t, valid) {
		return
	}
	if code := mac.bind(fd, &address, size_of(address));
	   !testing.expect_value(t, code, i32(0)) {
		fmt.eprintln("bind error", mac.__error()^, path); return
	}
	if !testing.expect_value(t, mac.listen(fd, 8), i32(0)) {
		return
	}
	state: mac.State; mac.manager_init(&state.manager)
	defer mac.manager_destroy(&state.manager)
	server: mac.Command_Server; defer mac.command_server_stop(&server)
	if !testing.expect_value(t, mac.command_server_start(&server, fd), "") {
		return
	}
	peer := mac.connect_socket(path)
	if !testing.expect(t, peer >= 0) {
		return
	}
	defer mac.close(peer)
	data, ok := mac.encode_message({"config", "window_gap", "37"})
	testing.expect(t, ok); defer delete(data)
	testing.expect(t, mac.write_all(peer, data[:2]))
	testing.expect_value(
		t,
		mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, .25, true),
		i32(4),
	)
	testing.expect_value(t, state.manager.gap, f64(0))
	mac.command_server_tick(&server, &state.manager)
	if !testing.expect_value(t, len(server.clients), 1) {
		return
	}
	deadline := server.clients[0].deadline
	testing.expect_value(t, server.clients[0].received, 2)
	testing.expect(t, mac.write_all(peer, data[2:]))
	testing.expect_value(
		t,
		mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, .25, true),
		i32(4),
	)
	testing.expect_value(t, state.manager.gap, f64(0))
	testing.expect_value(t, server.clients[0].deadline, deadline)
	last := time.now()
	mac.desktop_commands_tick(&server, &state, &last, last)
	testing.expect_value(t, state.manager.gap, f64(37))
	testing.expect_value(t, len(server.clients), 0)
	byte: u8; testing.expect_value(t, mac.recv(peer, &byte, 1, 0x80), 1)
	testing.expect_value(t, byte, u8('\n'))
}

refresh_command_space :: proc(state: ^mac.State) {
	state.manager.active_space = 200
	state.dirty = false
}
@(test)
commands_use_reconciled_space_state_before_presentation :: proc(
	t: ^testing.T,
) {
	state: mac.State; r: Recorder; fixture(&state.manager, &r)
	defer mac.manager_destroy(&state.manager); defer delete(r.actions)
	mac.add_space(&state.manager, 200, 10, 2, {0, 0, 1000, 800})
	state.dirty = true
	fds: [2]i32
	if !testing.expect_value(t, socketpair(1, 1, 0, &fds), i32(0)) {
		return
	}
	defer mac.close(fds[0])
	server: mac.Command_Server; defer mac.command_server_stop(&server)
	testing.expect(t, mac.command_accept(&server, fds[1]))
	data, valid := mac.encode_message({"space", "--label", "fresh"})
	testing.expect(t, valid); defer delete(data)
	testing.expect(t, mac.write_all(fds[0], data))
	now := time.now(); last := now
	mac.desktop_commands_tick(
		&server,
		&state,
		&last,
		now,
		refresh_command_space,
	)
	testing.expect_value(t, mac.space_by_id(&state.manager, 200).label, "fresh")
	testing.expect_value(t, mac.space_by_id(&state.manager, 100).label, "")
}

@(test)
blocked_command_replies_rearm_write_readiness_until_they_drain :: proc(
	t: ^testing.T,
) {
	manager: mac.Manager; mac.manager_init(&manager)
	defer mac.manager_destroy(&manager)
	mac.add_window(
		&manager,
		mac.Window {
			id = 1,
			title = strings.repeat("x", 256 * 1024, context.temp_allocator),
		},
	)
	expected := strings.concatenate(
		{mac.query(&manager, {"--windows"}).text, "\n"},
	); defer delete(expected)
	fds: [2]i32
	if !testing.expect_value(t, socketpair(1, 1, 0, &fds), i32(0)) {
		return
	}
	defer mac.close(fds[0])
	server: mac.Command_Server; defer mac.command_server_stop(&server)
	if !testing.expect(t, mac.command_accept(&server, fds[1])) {
		return
	}
	if !testing.expect(
		t,
		mac.socket_watch_start(&server.clients[0].watch, fds[1], 1),
	) {
		return
	}
	data, valid := mac.encode_message({"query", "--windows"})
	testing.expect(t, valid); defer delete(data)
	testing.expect(t, mac.write_all(fds[0], data))
	if !testing.expect_value(
		t,
		mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, .25, true),
		i32(4),
	) {
		return
	}
	mac.command_server_tick(&server, &manager)
	testing.expect_value(t, len(server.clients), 1)
	received: [dynamic]u8; defer delete(received)
	for _ in 0 ..< 64 {
		buffer: [8192]u8
		for {
			n := mac.recv(fds[0], raw_data(buffer[:]), uint(len(buffer)), 0x80)
			if n <= 0 {
				break
			}
			append(&received, ..buffer[:n])
		}
		if len(server.clients) == 0 {
			break
		}
		if !testing.expect_value(
			t,
			mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, .25, true),
			i32(4),
		) {
			return
		}
		mac.command_server_tick(&server, &manager)
	}
	testing.expect_value(t, len(server.clients), 0)
	testing.expect_value(t, string(received[:]), expected)
}
