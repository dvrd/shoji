package ipc

// Client side of the daemon command socket.

import "../native"
import "core:fmt"
import "core:strings"
import posix "core:sys/posix"
import "core:time"

socket_path :: proc() -> string {
	return fmt.tprintf("/tmp/shoji_%d.socket", posix.getuid())
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
	fd := native.connect_socket(socket_path())
	if fd < 0 {
		return false, "cannot connect to daemon"
	}
	defer native.close(fd)
	if !native.write_all(fd, data) {
		return false, "failed to send message"
	}
	native.shutdown(fd, 1)
	return client_receive_response(fd, out)
}

client_receive_response :: proc(fd: i32, out: ^strings.Builder) -> (failed: bool, err: string) {
	// Native desktop actions can exceed the transport's two-second idle limit.
	// Bound the entire reply instead of resetting a timeout for each fragment.
	deadline := time.time_add(time.now(), 15 * time.Second)
	first := true
	buffer: [8192]u8
	for {
		if !native.wait_socket(fd, 1, deadline) {
			return false, "cannot read daemon response before deadline"
		}
		n := native.recv(fd, &buffer[0], len(buffer), 0x80) // MSG_DONTWAIT
		if n < 0 && (posix.errno() == .EINTR || posix.errno() == .EAGAIN) {
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
