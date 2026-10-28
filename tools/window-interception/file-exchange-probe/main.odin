package main

// One-shot VM experiment only; no hooks, daemon commands, or window state.
import "base:runtime"
import "core:sys/posix"
import target "../../../src/addition/windowserver/target"

foreign import system "system:System"
foreign system {
	proc_pidpath :: proc "c" (pid: i32, buffer: [^]u8, size: u32) -> i32 ---
}

probe_start :: proc "c" () {
	context = runtime.default_context()
	path: [4096]u8
	if proc_pidpath(i32(posix.getpid()), &path[0], u32(len(path))) <= 0 {return}
	if !target.valid_path(string(cstring(&path[0]))) {return}
	input := posix.open("/private/tmp/shoji-ws-exchange-probe/request", {.NOFOLLOW, .NONBLOCK})
	if input < 0 {return}
	info: posix.stat_t
	if posix.fstat(input, &info) != nil || !posix.S_ISREG(info.st_mode) || info.st_uid != 501 || info.st_size <= 0 || info.st_size >= 64 {
		posix.close(input)
		return
	}
	buffer: [64]u8
	n := posix.read(input, &buffer[0], len(buffer))
	posix.close(input)
	if n <= 0 || n >= len(buffer) {return}
	output := posix.open("/private/tmp/shoji-ws-exchange-probe-response", {.WRONLY, .CREAT, .EXCL}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if output < 0 {return}
	posix.write(output, &buffer[0], uint(n))
	posix.close(output)
}

@(link_section = "__DATA,__mod_init_func", linkage = "strong", require)
probe_init: proc "c" () = probe_start
