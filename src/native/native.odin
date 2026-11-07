package native

import "base:intrinsics"
import CF "core:sys/darwin/CoreFoundation"
import objc "core:sys/darwin/Foundation"
import posix "core:sys/posix"
import "core:time"

Rect :: struct {x, y, w, h: f64}

foreign import libc "system:c"
foreign import cf "system:CoreFoundation.framework"
foreign import sls "system:SkyLight.framework"

Ref :: rawptr
Point :: struct {x, y: f64}
@(default_calling_convention = "c")
foreign cf {
 CFRelease :: proc(ref: Ref) ---
 CFGetTypeID :: proc(ref: Ref) -> uint ---
 CFStringGetTypeID :: proc() -> uint ---
 CFStringGetLength :: proc(ref: Ref) -> int ---
 CFNumberCreate :: proc(allocator: Ref, type: i32, value: rawptr) -> Ref ---
}
@(default_calling_convention = "c")
foreign sls {
 SLSMainConnectionID :: proc() -> i32 ---
 SLSManagedDisplayGetCurrentSpace :: proc(connection: i32, display: Ref) -> u64 ---
 SLSGetWindowBounds :: proc(connection: i32, window: u32, frame: ^Rect) -> i32 ---
 SLSGetWindowAlpha :: proc(connection: i32, window: u32, alpha: ^f32) -> i32 ---
}
@(default_calling_convention = "c")
foreign libc {
 getuid :: proc() -> u32 ---
 __error :: proc() -> ^i32 ---
}

text :: proc(ref: Ref) -> string {
	if ref == nil || CFGetTypeID(ref) != CFStringGetTypeID() {
		return ""
	}
	size :=
		CF.StringGetMaximumSizeForEncoding(
			CF.Index(CFStringGetLength(ref)),
			0x08000100,
		) +
		1
	buffer := make([]u8, int(size), context.temp_allocator)
	if !CF.StringGetCString(
		CF.String(ref),
		raw_data(buffer),
		size,
		0x08000100,
	) {
		return ""
	}
	return string(cstring(raw_data(buffer)))
}

pool_push :: proc() -> ^objc.Object {
	pool := intrinsics.objc_send(^objc.Object, objc.AutoreleasePool, "alloc")
	return intrinsics.objc_send(^objc.Object, pool, "init")
}

pool_pop :: proc(pool: ^objc.Object) {
	intrinsics.objc_send(nil, pool, "drain")
}

Unix_Address :: struct {
	length, family: u8,
	path: [104]u8,
}

Timeval :: struct {
	seconds: i64,
	microseconds: i32,
}

Poll_FD :: struct {
	fd: i32,
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
	flock :: proc(fd, operation: i32) -> i32 ---
	poll :: proc(fds: ^Poll_FD, count: u32, timeout: i32) -> i32 ---
	getpeereid :: proc(fd: i32, uid, gid: ^u32) -> i32 ---
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

wait_socket :: proc(fd: i32, events: i16, deadline: time.Time) -> bool {
	for {
		remaining := time.diff(time.now(), deadline)
		if remaining <= 0 {
			return false
		}
		ready := Poll_FD {
			fd     = fd,
			events = events,
		}
		if result := poll(
			&ready,
			1,
			i32(max(1, remaining / time.Millisecond)),
		); result > 0 {
			return true
		} else if result < 0 && __error()^ != 4 {
			return false
		}
	}
}

read_exact :: proc(fd: i32, buffer: []u8, deadline: time.Time = {}) -> bool {
	flags := posix.fcntl(posix.FD(fd), .GETFL)
	if flags < 0 ||
	   posix.fcntl(posix.FD(fd), .SETFL, flags | posix.O_NONBLOCK) != 0 {
		return false
	}
	defer posix.fcntl(posix.FD(fd), .SETFL, flags)
	deadline := deadline
	if (deadline == time.Time{}) {
		deadline = time.time_add(time.now(), 2 * time.Second)
	}
	offset := 0
	for offset < len(buffer) {
		if !wait_socket(fd, 1, deadline) {
			return false
		}
		n := recv(
			fd,
			raw_data(buffer[offset:]),
			uint(len(buffer)) - uint(offset),
			0x80,
		)
		if n < 0 && (__error()^ == 4 || __error()^ == 35) {
			continue
		}
		if n <= 0 {
			return false
		}
		offset += n
	}
	return true
}

write_all :: proc(fd: i32, buffer: []u8, deadline: time.Time = {}) -> bool {
	flags := posix.fcntl(posix.FD(fd), .GETFL)
	if flags < 0 ||
	   posix.fcntl(posix.FD(fd), .SETFL, flags | posix.O_NONBLOCK) != 0 {
		return false
	}
	defer posix.fcntl(posix.FD(fd), .SETFL, flags)
	deadline := deadline
	if (deadline == time.Time{}) {
		deadline = time.time_add(time.now(), 2 * time.Second)
	}
	offset := 0
	for offset < len(buffer) {
		if !wait_socket(fd, 4, deadline) {
			return false
		}
		n := send(
			fd,
			raw_data(buffer[offset:]),
			uint(len(buffer)) - uint(offset),
			0x80,
		)
		if n < 0 && (__error()^ == 4 || __error()^ == 35) {
			continue
		}
		if n <= 0 {
			return false
		}
		offset += n
	}
	return true
}
