package tests

import mac "../src"
import "base:runtime"
import "core:mem"
import "core:strings"
import posix "core:sys/posix"
import "core:testing"
import "core:time"
import ipc "../src/ipc"

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
	data, _ := ipc.encode_message([]string{"query", "--windows"});defer delete(data)
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

Delayed_Command_Response :: struct {
	fd: i32,
	finished: bool,
}
write_delayed_command_response :: proc "c" (user: rawptr) -> rawptr {
	context = runtime.default_context()
	writer := (^Delayed_Command_Response)(user)
	mac.write_all(writer.fd, []u8{'[', ']'})
	time.sleep(2300 * time.Millisecond)
	writer.finished = mac.write_all(writer.fd, []u8{'\n'})
	mac.shutdown(writer.fd, 1)
	return nil
}

@(test)
command_client_waits_for_valid_delayed_reply_fragments :: proc(t: ^testing.T) {
	fds: [2]i32
	if !testing.expect_value(t, socketpair(1, 1, 0, &fds), i32(0)) { return }
	defer mac.close(fds[0]); defer mac.close(fds[1])
	mac.prepare_socket(fds[0]); mac.prepare_socket(fds[1])
	writer := Delayed_Command_Response{fd = fds[1]}
	thread: posix.pthread_t
	if !testing.expect(t, posix.pthread_create(&thread, nil, write_delayed_command_response, &writer) == nil) { return }
	reply := strings.builder_make(context.temp_allocator)
	failed, err := ipc.client_receive_response(fds[0], &reply)
	posix.pthread_join(thread)
	testing.expect_value(t, err, "")
	testing.expect(t, !failed)
	testing.expect_value(t, strings.to_string(reply), "[]\n")
	testing.expect(t, writer.finished)
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
	data, _ := ipc.encode_message([]string{"query", "--windows"});defer delete(data)
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
	data, _ := ipc.encode_message([]string{"config", "window_gap", "12"});defer delete(data)
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

// A reply larger than the socket buffer goes out over several ticks. The
// motion dump hit this: the client got the first 16 KB, then the deadline.
@(test)
command_server_sends_a_reply_larger_than_the_socket_buffer :: proc(t: ^testing.T) {
	server: mac.Command_Server;m: mac.Manager;mac.manager_init(&m)
	defer mac.manager_destroy(&m);defer mac.command_server_stop(&server)
	testing.expect(t, !mac.execute(&m, {"debug", "motion", "start"}).failed)
	for _ in 0 ..< 400 {
		mac.motion_trace_record(&m.motion_trace, {kind = "loop"})
	}
	pair: [2]i32
	if !testing.expect_value(t, socketpair(1, 1, 0, &pair), i32(0)) {return}
	defer mac.close(pair[0])
	testing.expect(t, mac.command_accept(&server, pair[1]))
	data, _ := ipc.encode_message([]string{"debug", "motion", "dump"});defer delete(data)
	testing.expect(t, mac.write_all(pair[0], data))
	mac.shutdown(pair[0], 1)
	reply: [dynamic]u8;defer delete(reply)
	buffer: [8192]u8
	closed := false
	for _ in 0 ..< 200 {
		mac.command_server_tick(&server, &m)
		for {
			n := mac.recv(pair[0], &buffer[0], len(buffer), 0x80)
			if n == 0 {closed = true;break}
			if n < 0 {break}
			append(&reply, ..buffer[:n])
		}
		if closed {break}
	}
	testing.expect(t, closed)
	testing.expect(t, len(reply) > 64 * 1024)
	testing.expect_value(t, reply[len(reply) - 1], u8('\n'))
}
