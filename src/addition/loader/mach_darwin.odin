package loader

foreign import sys "system:System"
Mach_Header :: struct {
	magic, cpu, subtype, filetype, ncmds, sizeofcmds, flags, reserved: u32,
}
ARM_State :: struct {
	x:              [29]u64,
	fp, lr, sp, pc: u64,
	cpsr, flags:    u32,
}
X86_State :: struct {
	rax, rbx, rcx, rdx, rdi, rsi, rbp, rsp, r8, r9, r10, r11, r12, r13, r14, r15, rip, rflags, cs, fs, gs: u64,
}
@(default_calling_convention = "c")
foreign sys {
	mach_task_self :: proc() -> u32 ---
	task_for_pid :: proc(self: u32, pid: i32, task: ^u32) -> i32 ---
	mach_port_deallocate :: proc(task, port: u32) -> i32 ---


	mach_vm_write :: proc(task: u32, address: u64, data: uintptr, count: u32) -> i32 ---
	mach_vm_read_overwrite :: proc(task: u32, address, size: u64, data: uintptr, actual: ^u64) -> i32 ---
	mach_vm_protect :: proc(task: u32, address, size: u64, maximum, protection: i32) -> i32 ---
	thread_create :: proc(task: u32, thread: ^u32) -> i32 ---
	thread_create_running :: proc(task: u32, flavor: i32, state: rawptr, count: u32, thread: ^u32) -> i32 ---
	thread_set_state :: proc(thread: u32, flavor: i32, state: rawptr, count: u32) -> i32 ---
	thread_resume :: proc(thread: u32) -> i32 ---
	thread_terminate :: proc(thread: u32) -> i32 ---
	_dyld_get_image_header :: proc(index: u32) -> ^Mach_Header ---
	getsectiondata :: proc(header: ^Mach_Header, segment, section: cstring, size: ^uint) -> [^]u8 ---
	dlopen :: proc(path: cstring, mode: i32) -> rawptr ---
	dlsym :: proc(handle: rawptr, name: cstring) -> rawptr ---
	dlclose :: proc(handle: rawptr) -> i32 ---
}
