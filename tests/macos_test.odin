package tests

import e "../src/engine"
import mac "../src/macos"
import "core:testing"

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
	data, ok := e.encode_message([]string{"query", "--windows"})
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
	if !testing.expect_value(t, socketpair(1, 1, 0, &fds), i32(0)) {return}
	defer mac.close(fds[0])
	mac.prepare_socket(fds[0])
	data, ok := e.encode_message([]string{"not-a-domain"})
	testing.expect(t, ok)
	defer delete(data)
	testing.expect(t, mac.write_all(fds[0], data))
	mac.shutdown(fds[0], 1)
	manager: e.Manager
	e.manager_init(&manager)
	defer e.manager_destroy(&manager)
	mac.serve_message(fds[1], &manager)
	response: [256]u8
	size := mac.recv(fds[0], &response[0], len(response), 0)
	testing.expect(t, size > 1)
	testing.expect_value(t, response[0], u8(7))
}

@(test)
server_returns_query_response_over_socket :: proc(t: ^testing.T) {
	fds: [2]i32
	if !testing.expect_value(t, socketpair(1, 1, 0, &fds), i32(0)) {return}
	defer mac.close(fds[0])
	mac.prepare_socket(fds[0])
	data, ok := e.encode_message([]string{"query", "--windows"})
	testing.expect(t, ok)
	defer delete(data)
	testing.expect(t, mac.write_all(fds[0], data))
	mac.shutdown(fds[0], 1)
	manager: e.Manager
	e.manager_init(&manager)
	defer e.manager_destroy(&manager)
	mac.serve_message(fds[1], &manager)
	response: [256]u8
	size := mac.recv(fds[0], &response[0], len(response), 0)
	testing.expect(t, size > 0)
	if size > 0 {testing.expect_value(t, string(response[:size]), "[]\n")}
}
