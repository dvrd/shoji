package shoji

import n "native"
import "core:fmt"
import "core:strings"
import posix "core:sys/posix"
import "core:time"

// Socket transport
// ------------------------------------------------------------------------

Unix_Address :: n.Unix_Address
Timeval :: n.Timeval
Poll_FD :: n.Poll_FD
socket :: n.socket
bind :: n.bind
connect :: n.connect
listen :: n.listen
accept :: n.accept
close :: n.close
shutdown :: n.shutdown
recv :: n.recv
send :: n.send
setsockopt :: n.setsockopt
chmod :: n.chmod
unlink :: n.unlink
flock :: n.flock
poll :: n.poll
getpeereid :: n.getpeereid
address :: n.address
prepare_socket :: n.prepare_socket
connect_socket :: n.connect_socket
wait_socket :: n.wait_socket
read_exact :: n.read_exact
write_all :: n.write_all

socket_path :: proc() -> string {
	return fmt.tprintf("/tmp/shoji_%d.socket", getuid())
}

client :: proc(args: []string) -> int {
	out := strings.builder_make(context.temp_allocator)
	failed, err := client_exchange(args, &out)
	if err != "" {
		fmt.eprintln("shoji:", err)
		return 1
	}
	if failed {
		fmt.eprint(strings.to_string(out))
		return 1
	}
	fmt.print(strings.to_string(out))
	return 0
}

// Sends one command and collects the daemon's reply into `out`. `failed` is
// the daemon's verdict; `err` is a transport error (no reply was received).
client_exchange :: proc(args: []string, out: ^strings.Builder) -> (failed: bool, err: string) {
	data, ok := encode_message(args)
	if !ok {
		return false, "invalid or oversized message"
	}
	defer delete(data)
	fd := connect_socket(socket_path())
	if fd < 0 {
		return false, "cannot connect to daemon"
	}
	defer close(fd)
	if !write_all(fd, data) {
		return false, "failed to send message"
	}
	shutdown(fd, 1)
	return client_receive_response(fd, out)
}

client_receive_response :: proc(fd: i32, out: ^strings.Builder) -> (failed: bool, err: string) {
	// Native desktop actions can exceed the transport's two-second idle limit.
	// Bound the entire reply instead of resetting a timeout for each fragment.
	deadline := time.time_add(time.now(), 15 * time.Second)
	first := true
	buffer: [8192]u8
	for {
		if !wait_socket(fd, 1, deadline) {
			return false, "cannot read daemon response before deadline"
		}
		n := recv(fd, &buffer[0], len(buffer), 0x80) // MSG_DONTWAIT
		if n < 0 && (__error()^ == 4 || __error()^ == 35) {
			continue
		}
		if n < 0 {
			return false, "response read failed"
		}
		if n == 0 {
			break
		}
		offset := 0
		if first && buffer[0] == 7 {
			failed = true
			offset = 1
		}
		first = false
		strings.write_string(out, string(buffer[offset:n]))
	}
	if first {
		return false, "daemon returned no response"
	}
	return failed, ""
}

// Nonblocking command server
// ------------------------------------------------------------------------

MAX_COMMAND_CLIENTS :: 32
COMMAND_BYTE_BUDGET :: 64 * 1024
Pending_Command :: struct {
	watch: Socket_Watch,
	fd: i32,
	header: [4]u8,
	data: []u8,
	received: int,
	output: string,
	sent: int,
	deadline: time.Time,
}
Command_Server :: struct {
	listener: Socket_Watch,
	listener_fd, listener_flags: i32,
	event_driven: bool,
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
		close(fd); return false
	}
	flags := posix.fcntl(posix.FD(fd), .GETFL)
	if flags < 0 ||
	   posix.fcntl(posix.FD(fd), .SETFL, flags | posix.O_NONBLOCK) != 0 {
		close(fd); return false
	}
	client := Pending_Command {
		fd       = fd,
		deadline = time.time_add(time.now(), timeout),
	}
	if server.event_driven && !socket_watch_start(&client.watch, fd, 1) {
		close(fd); return false
	}
	append(&server.clients, client)

	return true
}

command_close :: proc(client: ^Pending_Command) {
	socket_watch_stop(&client.watch)
	close(client.fd); delete(client.data); delete(client.output)
}
command_server_stop :: proc(server: ^Command_Server) {
	socket_watch_stop(&server.listener)
	if server.event_driven {
		posix.fcntl(
			posix.FD(server.listener_fd),
			.SETFL,
			server.listener_flags,
		)
	}
	for &client in server.clients { command_close(&client) }
	delete(server.clients); server^ = {}
}

command_reply :: proc(
	client: ^Pending_Command,
	response: Response,
	now: time.Time,
) {
	// Query/error text can borrow the tick arena; responses must own their bytes
	// until a slow reader has drained them or its fixed deadline expires.
	client.output = fmt.aprintf(
		"%s%s\n",
		response.failed ? "\a" : "",
		response.text,
	)
	client.deadline = time.time_add(now, 2 * time.Second)
}

command_tick :: proc(
	client: ^Pending_Command,
	manager: ^Manager,
	now: time.Time,
) -> bool {
	if time.diff(now, client.deadline) <= 0 {
		return true
	}
	budget := COMMAND_BYTE_BUDGET
	for client.output == "" && budget > 0 {
		buffer: []u8
		if client.received < 4 {
			buffer = client.header[client.received:]
		} else {
			buffer = client.data[client.received:]
		}
		buffer = buffer[:min(len(buffer), budget)]
		n := recv(client.fd, raw_data(buffer), uint(len(buffer)), 0x80) // MSG_DONTWAIT
		if n < 0 && (__error()^ == 35 || __error()^ == 4) {
			return false
		}
		if n <= 0 {
			return true
		}
		client.received += n; budget -= n
		if client.received == 4 && client.data == nil {
			h := client.header
			count :=
				u32(h[0]) | u32(h[1]) << 8 | u32(h[2]) << 16 | u32(h[3]) << 24
			if count < 2 || count > MAX_MESSAGE {
				command_reply(client, failure("invalid message length"), now)
				break
			}
			client.data = make([]u8, int(count) + 4)
			copy(client.data, h[:])
		}
		if client.data != nil && client.received == len(client.data) {
			args, valid := decode_message(client.data)
			defer delete(args)
			// Discovery or another client can block after the loop was sampled.
			// Start this action now, otherwise its first animation frame may
			// already be past the settling deadline.
			if valid {
				manager.scroll_time = time.duration_seconds(
					time.diff(time.Time{}, time.now()),
				)
				motion_trace_record(
					&manager.motion_trace,
					{kind = "command"},
				)
			}
			response :=
				valid \
					? execute(manager, args[:]) \
					: failure("malformed message")
			command_reply(client, response, time.now())
		}
	}
	if client.output != "" {
		buffer := transmute([]u8)client.output[client.sent:]
		buffer = buffer[:min(len(buffer), COMMAND_BYTE_BUDGET)]
		n := send(client.fd, raw_data(buffer), uint(len(buffer)), 0x80)
		if n < 0 && (__error()^ == 35 || __error()^ == 4) {
			return false
		}
		if n <= 0 {
			return true
		}
		client.sent += n
		return client.sent == len(client.output)
	}
	return false
}

command_server_tick :: proc(
	server: ^Command_Server,
	manager: ^Manager,
	now: time.Time = {},
) {
	now := now
	if (now == time.Time{}) {
		now = time.now()
	}
	if server.event_driven {
		// Nonblocking and bounded even if the backlog refills while it is drained.
		for _ in 0 ..< MAX_COMMAND_CLIENTS {
			fd := accept(server.listener_fd, nil, nil)
			if fd < 0 {
				break
			}
			command_accept(server, fd)
		}
		socket_watch_arm(&server.listener, 1)
	}
	for i := 0; i < len(server.clients); {
		if command_tick(&server.clients[i], manager, now) {
			command_close(&server.clients[i])
			ordered_remove(&server.clients, i)
		} else {
			socket_watch_arm(
				&server.clients[i].watch,
				server.clients[i].output == "" ? 1 : 2,
			)
			i += 1
		}
	}
}

// Native callbacks carry no pointers into the movable client array. They only
// wake CFRunLoopRunInMode; command execution stays in the outer daemon tick.
Socket_Watch :: struct {
	descriptor, source, loop: Ref,
}
File_Descriptor_Context :: struct {
	version: int,
	info, retain, release, describe: rawptr,
}
foreign import ipc_cf "system:CoreFoundation.framework"
foreign ipc_cf {
	CFRunLoopGetCurrent :: proc "c" () -> Ref ---
	CFFileDescriptorCreate :: proc "c" (allocator: Ref, fd: i32, close_on_invalidate: bool, callback: proc "c" (_: Ref, _: uint, _: rawptr), info: ^File_Descriptor_Context) -> Ref ---
	CFFileDescriptorCreateRunLoopSource :: proc "c" (allocator, descriptor: Ref, order: int) -> Ref ---
	CFFileDescriptorEnableCallBacks :: proc "c" (descriptor: Ref, events: uint) ---
	CFFileDescriptorDisableCallBacks :: proc "c" (descriptor: Ref, events: uint) ---
	CFFileDescriptorInvalidate :: proc "c" (descriptor: Ref) ---
}
socket_ready :: proc "c" (_: Ref, _: uint, _: rawptr) {}
socket_watch_stop :: proc(watch: ^Socket_Watch) {
	if watch.source != nil {
		CFRunLoopRemoveSource(watch.loop, watch.source, kCFRunLoopDefaultMode)
		CFRelease(watch.source)
	}
	if watch.descriptor != nil {
		CFFileDescriptorInvalidate(watch.descriptor)
		CFRelease(watch.descriptor)
	}
	if watch.loop != nil {
		CFRelease(watch.loop)
	}
	watch^ = {}
}
socket_watch_arm :: proc(watch: ^Socket_Watch, events: uint) {
	if watch.descriptor == nil {
		return
	}
	CFFileDescriptorDisableCallBacks(watch.descriptor, 3)
	CFFileDescriptorEnableCallBacks(watch.descriptor, events)
}
socket_watch_start :: proc(
	watch: ^Socket_Watch,
	fd: i32,
	events: uint,
) -> bool {
	assert(watch.descriptor == nil)
	info: File_Descriptor_Context
	watch.descriptor = CFFileDescriptorCreate(
		nil,
		fd,
		false,
		socket_ready,
		&info,
	)
	if watch.descriptor == nil {
		return false
	}
	watch.source = CFFileDescriptorCreateRunLoopSource(
		nil,
		watch.descriptor,
		0,
	)
	if watch.source == nil {
		socket_watch_stop(watch); return false
	}
	watch.loop = CFRetain(CFRunLoopGetCurrent())
	CFRunLoopAddSource(watch.loop, watch.source, kCFRunLoopDefaultMode)
	socket_watch_arm(watch, events)
	return true
}
command_server_start :: proc(server: ^Command_Server, fd: i32) -> string {
	if server.event_driven || len(server.clients) != 0 {
		return "command event sources must start on an empty server"
	}
	flags := posix.fcntl(posix.FD(fd), .GETFL)
	if flags < 0 ||
	   posix.fcntl(posix.FD(fd), .SETFL, flags | posix.O_NONBLOCK) != 0 {
		return "cannot configure command listener"
	}
	if !socket_watch_start(&server.listener, fd, 1) {
		posix.fcntl(posix.FD(fd), .SETFL, flags)
		return "cannot register command listener with the run loop"
	}
	server.event_driven = true; server.listener_fd = fd
	server.listener_flags = flags
	return ""
}
