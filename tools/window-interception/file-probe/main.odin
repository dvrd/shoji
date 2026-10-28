package main

// VM-only sandbox probe. It never hooks server code or accepts commands.
import "core:sys/posix"
import target "../../../src/addition/windowserver/target"
import "base:runtime"

foreign import system "system:System"
@(default_calling_convention = "c")
foreign system {
	proc_pidpath :: proc(pid: i32, buffer: [^]u8, size: u32) -> i32 ---
}

probe_start :: proc "c" () {
	context = runtime.default_context()
	path: [4096]u8
	if proc_pidpath(i32(posix.getpid()), &path[0], u32(len(path))) <= 0 {return}
	if !target.valid_path(string(cstring(&path[0]))) {return}
	// O_CREAT | O_EXCL prevents replacing or following an existing endpoint.
	fd := posix.open("/private/tmp/shoji-ws-file-probe-27-0-1", {.WRONLY, .CREAT, .EXCL}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if fd < 0 {return}
	message := "shoji-ws-file-probe-1\n"
	posix.write(fd, raw_data(message), uint(len(message)))
	posix.close(fd)
}

@(link_section = "__DATA,__mod_init_func", linkage = "strong", require)
probe_init: proc "c" () = probe_start
