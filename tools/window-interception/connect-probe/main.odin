package main

// Disposable outbound-socket experiment; no hooks or production protocol.
import "base:runtime"
import "core:sys/posix"
import target "../../../src/experimental/window_server"

Unix_Address :: struct {length, family: u8, path: [104]u8}
foreign import system "system:System"
@(default_calling_convention = "c")
foreign system {
	proc_pidpath :: proc(pid: i32, buffer: [^]u8, size: u32) -> i32 ---
	socket :: proc(domain, kind, protocol: i32) -> i32 ---
	connect :: proc(fd: i32, addr: ^Unix_Address, size: u32) -> i32 ---
	send :: proc(fd: i32, data: rawptr, size: uint, flags: i32) -> int ---
	setsockopt :: proc(fd, level, option: i32, value: rawptr, size: u32) -> i32 ---
	close :: proc(fd: i32) -> i32 ---
}

probe_start :: proc "c" () {
	context = runtime.default_context()
	path: [4096]u8
	if proc_pidpath(i32(posix.getpid()), &path[0], u32(len(path))) <= 0 {return}
	if !target.valid_path(string(cstring(&path[0]))) {return}
	addr := Unix_Address{length = u8(size_of(Unix_Address)), family = 1}
	copy(addr.path[:], string("/private/tmp/shoji-ws-connect-probe.sock"))
	fd := socket(1, 1, 0)
	if fd < 0 {return}
	defer close(fd)
	flags := posix.fcntl(posix.FD(fd), .GETFL)
	if flags < 0 || posix.fcntl(posix.FD(fd), .SETFL, flags | posix.O_NONBLOCK) != 0 {return}
	one: i32 = 1
	if setsockopt(fd, 0xffff, 0x1022, &one, size_of(one)) != 0 {return}
	if connect(fd, &addr, size_of(addr)) != 0 {return}
	message := "shoji-ws-connect-probe-1\n"
	send(fd, raw_data(message), uint(len(message)), 0)
}

@(link_section = "__DATA,__mod_init_func", linkage = "strong", require)
probe_init: proc "c" () = probe_start
