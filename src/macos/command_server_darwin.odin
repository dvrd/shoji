package macos

import e "../engine"
import "core:fmt"
import posix "core:sys/posix"
import "core:time"

MAX_COMMAND_CLIENTS :: 32
COMMAND_BYTE_BUDGET :: 64 * 1024
Pending_Command :: struct {
	fd:       i32,
	header:   [4]u8,
	data:     []u8,
	received: int,
	output:   string,
	sent:     int,
	deadline: time.Time,
}
Command_Server :: struct {
	clients: [dynamic]Pending_Command,
}

command_accept :: proc(
	server: ^Command_Server,
	fd: i32,
	timeout: time.Duration = 2 * time.Second,
) -> bool {
	prepare_socket(fd)
	uid, gid: u32
	if len(server.clients) >= MAX_COMMAND_CLIENTS ||
	   getpeereid(fd, &uid, &gid) != 0 ||
	   uid != getuid() {
		close(fd);return false
	}
	flags := posix.fcntl(posix.FD(fd), .GETFL)
	if flags < 0 || posix.fcntl(posix.FD(fd), .SETFL, flags | posix.O_NONBLOCK) != 0 {
		close(fd);return false
	}
	append(
		&server.clients,
		Pending_Command{fd = fd, deadline = time.time_add(time.now(), timeout)},
	)
	return true
}

command_close :: proc(client: ^Pending_Command) {
	close(client.fd);delete(client.data);delete(client.output)
}
command_server_stop :: proc(server: ^Command_Server) {
	for &client in server.clients {command_close(&client)}
	delete(server.clients);server^ = {}
}

command_reply :: proc(client: ^Pending_Command, response: e.Response, now: time.Time) {
	// Query/error text can borrow the tick arena; responses must own their bytes
	// until a slow reader has drained them or its fixed deadline expires.
	client.output = fmt.aprintf("%s%s\n", response.failed ? "\a" : "", response.text)
	client.deadline = time.time_add(now, 2 * time.Second)
}

command_tick :: proc(client: ^Pending_Command, manager: ^e.Manager, now: time.Time) -> bool {
	if time.diff(now, client.deadline) <= 0 {return true}
	budget := COMMAND_BYTE_BUDGET
	for client.output == "" && budget > 0 {
		buffer: []u8
		if client.received < 4 {buffer = client.header[client.received:]} else {
			buffer = client.data[client.received:]
		}
		buffer = buffer[:min(len(buffer), budget)]
		n := recv(client.fd, raw_data(buffer), uint(len(buffer)), 0x80) // MSG_DONTWAIT
		if n < 0 && (__error()^ == 35 || __error()^ == 4) {return false}
		if n <= 0 {return true}
		client.received += n;budget -= n
		if client.received == 4 && client.data == nil {
			h := client.header
			count := u32(h[0]) | u32(h[1]) << 8 | u32(h[2]) << 16 | u32(h[3]) << 24
			if count < 2 || count > e.MAX_MESSAGE {
				command_reply(client, e.failure("invalid message length"), now)
				break
			}
			client.data = make([]u8, int(count) + 4)
			copy(client.data, h[:])
		}
		if client.data != nil && client.received == len(client.data) {
			args, valid := e.decode_message(client.data)
			defer delete(args)
			// Discovery or another client can block after the loop was sampled.
			// Start this action now, otherwise its first animation frame may
			// already be past the settling deadline.
			if valid {
				manager.scroll_time = time.duration_seconds(time.diff(time.Time{}, time.now()))
				e.motion_trace_record(&manager.motion_trace, {kind = "command"})
			}
			response := valid ? e.execute(manager, args[:]) : e.failure("malformed message")
			command_reply(client, response, time.now())
		}
	}
	if client.output != "" {
		buffer := transmute([]u8)client.output[client.sent:]
		buffer = buffer[:min(len(buffer), COMMAND_BYTE_BUDGET)]
		n := send(client.fd, raw_data(buffer), uint(len(buffer)), 0x80)
		if n < 0 && (__error()^ == 35 || __error()^ == 4) {return false}
		if n <= 0 {return true}
		client.sent += n
		return client.sent == len(client.output)
	}
	return false
}

command_server_tick :: proc(server: ^Command_Server, manager: ^e.Manager, now: time.Time = {}) {
	now := now
	if (now == time.Time{}) {now = time.now()}
	for i := 0; i < len(server.clients); {
		if command_tick(&server.clients[i], manager, now) {
			command_close(&server.clients[i]);ordered_remove(&server.clients, i)
		} else {i += 1}
	}
}
