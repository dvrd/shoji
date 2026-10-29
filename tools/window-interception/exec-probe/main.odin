package main

// Disposable WindowServer memory-protection probe; never modifies existing code.
import "base:runtime"
import "core:sys/posix"
import target "../../../src/experimental/window_server"

foreign import system "system:System"
@(default_calling_convention = "c")
foreign system {
	proc_pidpath :: proc(pid: i32, buffer: [^]u8, size: u32) -> i32 ---
	mach_task_self :: proc() -> u32 ---
	mach_vm_allocate :: proc(task: u32, address: ^u64, size: u64, flags: i32) -> i32 ---
	mach_vm_protect :: proc(task: u32, address, size: u64, max: i32, protection: i32) -> i32 ---
	mach_vm_deallocate :: proc(task: u32, address, size: u64) -> i32 ---
	vm_page_size: u64
}

probe_start :: proc "c" () {
	context = runtime.default_context()
	path: [4096]u8
	if proc_pidpath(i32(posix.getpid()), &path[0], u32(len(path))) <= 0 {return}
	if !target.valid_path(string(cstring(&path[0]))) {return}
	fd := posix.open("/private/tmp/shoji-ws-exec-probe-26A434", {.WRONLY, .CREAT, .EXCL}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if fd < 0 {return}
	defer posix.close(fd)
	page := vm_page_size
	if page == 0 || page & (page - 1) != 0 {return}
	self := mach_task_self()
	address: u64
	result := mach_vm_allocate(self, &address, page, 1)
	if result != 0 {
		message := "allocation-denied\n"
		posix.write(fd, raw_data(message), uint(len(message)))
		return
	}
	defer mach_vm_deallocate(self, address, page)
	result = mach_vm_protect(self, address, page, 0, 1 | 4)
	message := result == 0 ? "execute-permitted\n" : "execute-denied\n"
	posix.write(fd, raw_data(message), uint(len(message)))
}

@(link_section = "__DATA,__mod_init_func", linkage = "strong", require)
probe_init: proc "c" () = probe_start
