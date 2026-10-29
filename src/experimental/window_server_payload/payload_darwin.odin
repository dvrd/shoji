package payload

import "core:sys/posix"
import bridge "../../dock"
import ws "../window_server"
import "base:runtime"
import "core:fmt"
import "core:strings"

foreign import system "system:System"
foreign import configuration "system:SystemConfiguration.framework"
foreign import foundation "system:CoreFoundation.framework"

// Native system declarations
// ------------------------------------------------------------------------

Unix_Address :: struct {
	length, family: u8,
	path: [104]u8,
}

Timeval :: struct {
	seconds: i64,
	microseconds: i32,
}

@(default_calling_convention = "c")
foreign system {
	socket :: proc(domain, type, protocol: i32) -> i32 ---
	bind :: proc(fd: i32, address: ^Unix_Address, length: u32) -> i32 ---
	connect :: proc(fd: i32, address: ^Unix_Address, length: u32) -> i32 ---
	listen :: proc(fd, backlog: i32) -> i32 ---
	accept :: proc(fd: i32, address, length: rawptr) -> i32 ---
	close :: proc(fd: i32) -> i32 ---
	recv :: proc(fd: i32, buffer: rawptr, length: uint, flags: i32) -> int ---
	send :: proc(fd: i32, buffer: rawptr, length: uint, flags: i32) -> int ---
	setsockopt :: proc(fd, level, option: i32, value: rawptr, length: u32) -> i32 ---
	chmod :: proc(path: cstring, mode: u16) -> i32 ---
	unlink :: proc(path: cstring) -> i32 ---
	getpeereid :: proc(fd: i32, uid, gid: ^u32) -> i32 ---
	proc_pidpath :: proc(pid: i32, buffer: [^]u8, size: u32) -> i32 ---
	__error :: proc() -> ^i32 ---
}

@(default_calling_convention = "c")
foreign configuration {
	SCDynamicStoreCopyConsoleUser :: proc(store: rawptr, uid, gid: ^u32) -> rawptr ---
}

foreign foundation {
	CFRelease :: proc "c" (ref: rawptr) ---
}

address :: proc(path: string) -> (addr: Unix_Address, ok: bool) {
	if len(path) >= len(addr.path) {
		return
	}
	addr.length = u8(size_of(addr))
	addr.family = 1
	copy(addr.path[:], transmute([]u8)path)
	return addr, true
}

prepare_socket :: proc(fd: i32) {
	timeout := Timeval {
		seconds = 2,
	}
	one: i32 = 1
	setsockopt(fd, 0xffff, 0x1006, &timeout, size_of(timeout))
	setsockopt(fd, 0xffff, 0x1005, &timeout, size_of(timeout))
	setsockopt(fd, 0xffff, 0x1022, &one, size_of(one))
	posix.fcntl(posix.FD(fd), .SETFD, i32(1))
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

console_user :: proc() -> (uid: u32, ok: bool) {
	gid: u32
	name := SCDynamicStoreCopyConsoleUser(nil, &uid, &gid)
	if name == nil {
		return 0, false
	}
	CFRelease(name)
	return uid, uid > 0
}

running_in_windowserver :: proc() -> bool {
	buffer: [4096]u8
	if proc_pidpath(i32(posix.getpid()), &buffer[0], u32(len(buffer))) <= 0 {
		return false
	}
	return ws.valid_path(string(cstring(&buffer[0])))
}

// Payload server
// ------------------------------------------------------------------------

allowed_uid: u32
listen_fd: i32 = -1

serve_one :: proc(fd: i32) {
	defer close(fd)
	prepare_socket(fd)
	uid, gid: u32
	if getpeereid(fd, &uid, &gid) != 0 || uid != allowed_uid {
		return
	}

	header: [2]u8
	if !read_exact(fd, header[:]) {
		return
	}
	count := int(header[0]) | int(header[1]) << 8
	if count < 1 || count > ws.MAX_PACKET - 2 {
		response := [1]u8{u8(ws.Status.Invalid_Message)}
		write_all(fd, response[:])
		return
	}
	buffer: [ws.MAX_PACKET]u8
	if !read_exact(fd, buffer[:count]) {
		return
	}
	op := ws.Opcode(buffer[0])
	if !ws.validate(op, buffer[1:count]) {
		response := [1]u8{u8(ws.Status.Invalid_Message)}
		write_all(fd, response[:])
		return
	}

	response := [1]u8{u8(ws.Status.OK)}
	if !write_all(fd, response[:]) {
		return
	}
	p: ws.Packet
	ws.encode_handshake(&p, {.Load_Probe})
	write_all(fd, p.data[:p.count])
}

serve :: proc "c" (unused: rawptr) -> rawptr {
	context = runtime.default_context()
	for {
		fd := accept(listen_fd, nil, nil)
		if fd >= 0 {
			serve_one(fd)
		}
	}
}

load_payload :: proc "c" () {
	context = runtime.default_context()
	if !running_in_windowserver() {
		return
	}
	uid, ok := console_user()
	if !ok {
		return
	}
	allowed_uid = uid

	path := fmt.tprintf("/tmp/shoji-ws_%d.socket", allowed_uid)
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	existing := connect_socket(path)
	if existing >= 0 {
		peer, gid: u32
		loaded :=
			getpeereid(existing, &peer, &gid) == 0 &&
			peer == u32(posix.getuid())
		close(existing)
		if loaded {
			return
		}
	}

	fd := socket(1, 1, 0)
	if fd < 0 {
		return
	}
	prepare_socket(fd)
	addr, valid := address(path)
	if !valid || bind(fd, &addr, size_of(addr)) != 0 {
		close(fd)
		return
	}
	if chmod(cpath, 0o666) != 0 || listen(fd, 16) != 0 {
		close(fd)
		unlink(cpath)
		return
	}
	listen_fd = fd
	thread: posix.pthread_t
	if posix.pthread_create(&thread, nil, sign_c(serve), nil) != nil {
		close(fd)
		unlink(cpath)
		listen_fd = -1
		return
	}
	posix.pthread_detach(thread)
}

@(export)
shoji_ws_start :: proc "c" () {
	load_payload()
}

@(link_section = "__DATA,__mod_init_func", linkage = "strong", require)
shoji_ws_init: proc "c" () = shoji_ws_start

sign_c :: proc(p: $P) -> P {
	return(
		transmute(P)uintptr(
			bridge.sign_function(u64(uintptr(transmute(rawptr)p))),
		) \
	)
}
