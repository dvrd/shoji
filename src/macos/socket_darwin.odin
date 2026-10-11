package macos

import e "../engine"
import "core:fmt"
import posix "core:sys/posix"
foreign import libc "system:c"

Unix_Address :: struct {
	length, family: u8,
	path:           [104]u8,
}

Timeval :: struct {
	seconds:      i64,
	microseconds: i32,
}

Poll_FD :: struct {
	fd:              i32,
	events, revents: i16,
}
@(default_calling_convention = "c")
foreign libc {
	socket :: proc(domain, type, protocol: i32) -> i32 ---
	bind :: proc(fd: i32, address: ^Unix_Address, length: u32) -> i32 ---
	connect :: proc(fd: i32, address: ^Unix_Address, length: u32) -> i32 ---
	listen :: proc(fd, backlog: i32) -> i32 ---
	accept :: proc(fd: i32, address, length: rawptr) -> i32 ---
	close :: proc(fd: i32) -> i32 ---
	shutdown :: proc(fd, how: i32) -> i32 ---
	recv :: proc(fd: i32, buffer: rawptr, length: uint, flags: i32) -> int ---
	send :: proc(fd: i32, buffer: rawptr, length: uint, flags: i32) -> int ---
	setsockopt :: proc(fd, level, option: i32, value: rawptr, length: u32) -> i32 ---
	chmod :: proc(path: cstring, mode: u16) -> i32 ---
	unlink :: proc(path: cstring) -> i32 ---
	mkdir :: proc(path: cstring, mode: u16) -> i32 ---
	flock :: proc(fd, operation: i32) -> i32 ---
	poll :: proc(fds: ^Poll_FD, count: u32, timeout: i32) -> i32 ---
	getpeereid :: proc(fd: i32, uid, gid: ^u32) -> i32 ---
}

socket_path :: proc() -> string {
	return fmt.tprintf("/tmp/shoji_%d.socket", getuid())
}

address :: proc(path: string) -> (addr: Unix_Address, ok: bool) {
	if len(path) >= len(addr.path) {
		return
	}
	addr.length = u8(size_of(addr))
	addr.family = 1
	copy(addr.path[:], transmute([]u8)path)
	ok = true
	return
}

prepare_socket :: proc(fd: i32) {
	timeout := Timeval {
		seconds = 2,
	}
	one: i32 = 1
	setsockopt(fd, 0xffff, 0x1006, &timeout, size_of(timeout))
	setsockopt(fd, 0xffff, 0x1005, &timeout, size_of(timeout))
	setsockopt(fd, 0xffff, 0x1022, &one, size_of(one)) // SO_NOSIGPIPE
	posix.fcntl(posix.FD(fd), .SETFD, i32(1)) // FD_CLOEXEC
}

connect_socket :: proc(path: string) -> i32 {
	addr, ok := address(path)
	if !ok {
		return -1
	}
	fd := socket(1, 1, 0)
	if fd < 0 {
		return -1
	}
	prepare_socket(fd)
	if connect(fd, &addr, size_of(addr)) != 0 {
		close(fd)
		return -1
	}
	return fd
}

read_exact :: proc(fd: i32, buffer: []u8) -> bool {
	offset := 0
	for offset < len(buffer) {
		n := recv(fd, raw_data(buffer[offset:]), uint(len(buffer)) - uint(offset), 0)
		if n < 0 && __error()^ == 4 {
			continue
		}
		if n <= 0 {
			return false
		}
		offset += n
	}
	return true
}

write_all :: proc(fd: i32, buffer: []u8) -> bool {
	offset := 0
	for offset < len(buffer) {
		n := send(fd, raw_data(buffer[offset:]), uint(len(buffer)) - uint(offset), 0)
		if n < 0 && __error()^ == 4 {
			continue
		}
		if n <= 0 {
			return false
		}
		offset += n
	}
	return true
}

client :: proc(args: []string) -> int {
	data, ok := e.encode_message(args)
	if !ok {
		fmt.eprintln("shoji: invalid or oversized message")
		return 1
	}
	defer delete(data)
	fd := connect_socket(socket_path())
	if fd < 0 {
		fmt.eprintln("shoji: cannot connect to daemon")
		return 1
	}
	defer close(fd)
	if !write_all(fd, data) {
		fmt.eprintln("shoji: failed to send message")
		return 1
	}
	shutdown(fd, 1)
	first := true
	failed := false
	buffer: [8192]u8
	for {
		n := recv(fd, &buffer[0], len(buffer), 0)
		if n < 0 && __error()^ == 4 {
			continue
		}
		if n < 0 {
			fmt.eprintln("shoji: response read failed")
			return 1
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
		if failed {
			fmt.eprint(string(buffer[offset:n]))
		} else {
			fmt.print(string(buffer[offset:n]))
		}
	}
	if first {
		fmt.eprintln("shoji: daemon returned no response")
		return 1
	}
	return failed ? 1 : 0
}

serve_message :: proc(fd: i32, manager: ^e.Manager) {
	defer close(fd)
	prepare_socket(fd)
	uid, gid: u32
	if getpeereid(fd, &uid, &gid) != 0 || uid != getuid() {
		return
	}
	header: [4]u8
	if !read_exact(fd, header[:]) {
		return
	}
	count := u32(header[0]) | u32(header[1]) << 8 | u32(header[2]) << 16 | u32(header[3]) << 24
	response: e.Response
	if count < 2 || count > e.MAX_MESSAGE {
		response = e.failure("invalid message length")
	} else {
		data := make([]u8, int(count) + 4)
		defer delete(data)
		copy(data, header[:])
		if !read_exact(fd, data[4:]) {
			return
		}
		args, ok := e.decode_message(data)
		defer delete(args)
		if !ok {
			response = e.failure("malformed message")
		} else {
			response = e.execute(manager, args[:])
		}
	}
	output := fmt.tprintf("%s%s\n", response.failed ? "\a" : "", response.text)
	write_all(fd, transmute([]u8)output)
}
