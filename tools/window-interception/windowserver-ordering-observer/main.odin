package main

// Disposable exact-build WindowServer ordering observer. The callback records a
// bounded in-memory snapshot and forwards immediately; all file I/O runs on a
// separate control thread after installation. There is no live unhook path.
import "base:intrinsics"
import "base:runtime"
import "core:sys/posix"
import mach "core:sys/darwin"
import loader "../../../src/dock"
import hook "../../../src/experimental/window_server"

foreign import system "system:System"

Image_Info :: struct {
	path: cstring,
	base: rawptr,
	symbol: cstring,
	address: rawptr,
}
Region_Info :: struct {
	protection, max_protection: i32,
	share_mode: u8,
}
Ordering_Callback :: proc "c" (connection: rawptr, ids: [^]u32, operations: [^]i32, relative: [^]u32, count: u32, flag: u32) -> i32
Mach_Protect :: proc "c" (task: u32, address, size: u64, maximum, protection: i32) -> i32

OBSERVER_EVENTS :: 256
Observer_Event :: struct {
	sequence, connection: u64,
	count, flag: u32,
	result: i32,
	captured: u32,
	ids: [4]u32,
	operations: [4]i32,
	relative: [4]u32,
}
Observer_Response :: struct {
	magic: [8]u8,
	version, calls: u64,
	entry, branch_word: u64,
	events: [OBSERVER_EVENTS]Observer_Event,
}
Install_Result :: struct {
	magic: [8]u8,
	version, status: u64,
	uuid: [16]u8,
	slide, candidate, trampoline, relay: u64,
	privatize_code, execute_code, install_code: i64,
	barrier_leave_code, thread_create_code: i64,
	initial_current, initial_max, final_current, final_max: i64,
	setup_code, allocation_code, search_count: i64,
	first_candidate: u64,
	threads: u64,
}

STATUS_PATH :: "/private/tmp/shoji-ws-observer-status-26A434.bin"
REQUEST_PATH :: "/private/tmp/shoji-ws-observer-request"
RESPONSE_PATH :: "/private/tmp/shoji-ws-observer-response-26A434.bin"

@(default_calling_convention = "c")
foreign system {
	dladdr :: proc(address: rawptr, info: ^Image_Info) -> i32 ---
	proc_pidpath :: proc(pid: i32, buffer: [^]u8, size: u32) -> i32 ---
	@(link_name = "write") write_fd :: proc "c" (fd: i32, data: rawptr, size: uint) -> int ---
	@(link_name = "close") close_fd :: proc "c" (fd: i32) -> i32 ---
	usleep :: proc(microseconds: u32) -> i32 ---
	mach_vm_region_recurse :: proc(task: u32, address, size: ^u64, depth: ^u32, info: ^u32, count: ^u32) -> i32 ---
}

observer_original: Ordering_Callback
observer_calls: u64
observer_entry: u64
observer_branch: u32
observer_events: [OBSERVER_EVENTS]Observer_Event

write_file :: proc(path: cstring, data: rawptr, size: int) {
	fd := posix.open(path, {.WRONLY, .CREAT, .TRUNC}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if fd < 0 {return}
	bytes := ([^]u8)(data)
	written := 0
	for written < size {
		code := write_fd(i32(fd), &bytes[written], uint(size - written))
		if code <= 0 {break}
		written += code
	}
	close_fd(i32(fd))
}

region_info :: proc(page, page_size: u64) -> (info: Region_Info, ok: bool) {
	depth: u32
	for _ in 0 ..< 16 {
		address := page
		size: u64
		words: [19]u32
		count := u32(len(words))
		code := mach_vm_region_recurse(loader.mach_task_self(), &address, &size, &depth, &words[0], &count)
		if code != 0 || count < 13 || address > page || page - address > size ||
		   page_size > size - (page - address) {return {}, false}
		if words[12] == 0 {return {i32(words[0]), i32(words[1]), u8(words[11] >> 24)}, true}
		depth += 1
	}
	return {}, false
}

running_in_windowserver :: proc() -> bool {
	buffer: [4096]u8
	if proc_pidpath(i32(posix.getpid()), &buffer[0], u32(len(buffer))) <= 0 {return false}
	return hook.valid_path(string(cstring(&buffer[0])))
}

ordering_observer :: proc "c" (connection: rawptr, ids: [^]u32, operations: [^]i32, relative: [^]u32, count: u32, flag: u32) -> i32 {
	result := observer_original(connection, ids, operations, relative, count, flag)
	sequence := intrinsics.atomic_add_explicit(&observer_calls, 1, .Relaxed)
	event := &observer_events[sequence % OBSERVER_EVENTS]
	event^ = {}
	event.connection = u64(uintptr(connection))
	event.count = count
	event.flag = flag
	event.result = result
	if ids != nil && operations != nil && relative != nil {
		captured := min(count, 4)
		event.captured = captured
		for index in 0 ..< captured {
			event.ids[index] = ids[index]
			event.operations[index] = operations[index]
			event.relative[index] = relative[index]
		}
	}
	intrinsics.atomic_store_explicit(&event.sequence, sequence + 1, .Release)
	return result
}

control_thread :: proc "c" (_: rawptr) -> rawptr {
	context = runtime.default_context()
	for {
		fd := posix.open(REQUEST_PATH, {.NOFOLLOW, .NONBLOCK})
		if fd >= 0 {
			info: posix.stat_t
			request: [8]u8
			valid := posix.fstat(fd, &info) == nil && posix.S_ISREG(info.st_mode) &&
				info.st_uid == 501 && info.st_size == 5
			if valid {
				n := posix.read(fd, &request[0], len(request))
				valid = n == 5 && string(request[:5]) == "dump\n"
			}
			posix.close(fd)
			if valid {
				response: Observer_Response
				response.magic = {'W', 'S', 'O', 'B', 'S', 'E', 'R', 'V'}
				response.version = 1
				response.calls = intrinsics.atomic_load_explicit(&observer_calls, .Acquire)
				response.entry = observer_entry
				response.branch_word = u64(observer_branch)
				response.events = observer_events
				write_file(RESPONSE_PATH, &response, size_of(response))
			}
		}
		usleep(50_000)
	}
}

install_observer :: proc() {
	result := Install_Result {
		magic = {'W', 'S', 'O', 'B', 'I', 'N', 'S', 'T'},
		version = 1,
		status = 1,
	}
	defer write_file(STATUS_PATH, &result, size_of(result))
	if !running_in_windowserver() {return}
	handle := loader.dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", 2)
	if handle == nil {result.status = 2; return}
	server := loader.raw_symbol(handle, "SLXServer")
	info: Image_Info
	if server == nil || dladdr(server, &info) == 0 {result.status = 2; return}
	location, image_ok := hook.inspect_ordering_image(info.base)
	if !image_ok {result.status = 2; return}
	entry := location.candidate
	bytes := ([^]u8)(uintptr(entry))
	if !hook.matches_ordering_entry(location, bytes[:16]) {result.status = 2; return}
	result.uuid = location.uuid
	result.slide = location.slide
	result.candidate = entry
	page_size := mach.vm_page_size
	if page_size == 0 || page_size & (page_size - 1) != 0 {result.status = 3; return}
	page := entry & ~(page_size - 1)
	initial, region_ok := region_info(page, page_size)
	if !region_ok || initial.protection != 5 || initial.max_protection != 5 {result.status = 3; return}
	result.initial_current = i64(initial.protection)
	result.initial_max = i64(initial.max_protection)

	kernel := loader.dlopen("/usr/lib/system/libsystem_kernel.dylib", 2)
	if kernel == nil {result.status = 3; return}
	allocate := cast(proc "c" (_: u32, _: ^u64, _: u64, _: i32) -> i32)loader.raw_symbol(kernel, "mach_vm_allocate")
	deallocate := cast(hook.Deallocate)loader.raw_symbol(kernel, "mach_vm_deallocate")
	protect := cast(Mach_Protect)loader.raw_symbol(kernel, "mach_vm_protect")
	if allocate == nil || deallocate == nil || protect == nil {result.status = 3; return}

	task := loader.mach_task_self()
	entry_words := ([^]u32)(uintptr(entry))
	expected: [4]u32
	for index in 0 ..< 4 {expected[index] = entry_words[index]}
	trampoline: u64
	allocate_code := allocate(task, &trampoline, page_size, 1)
	result.allocation_code = i64(allocate_code)
	if allocate_code != 0 {
		result.setup_code = 1
		result.status = 4
		return
	}
	replacement := loader.strip_function(u64(uintptr(rawptr(ordering_observer))))
	plan, plan_ok := hook.plan_inline(entry, trampoline, replacement, expected)
	if !plan_ok {
		deallocate(task, trampoline, page_size)
		result.setup_code = 2
		result.status = 4
		return
	}
	trampoline_code := ([^]u32)(uintptr(trampoline))
	for index in 0 ..< 4 {
		trampoline_code[index] = plan.displaced[index]
		trampoline_code[4 + index] = plan.resume_jump[index]
	}
	hook.hook_sys_icache_invalidate(rawptr(uintptr(trampoline)), uint(page_size))
	region_protect_code := protect(task, trampoline, page_size, 0, 1 | 4)
	result.allocation_code = i64(region_protect_code)
	if region_protect_code != 0 {
		deallocate(task, trampoline, page_size)
		result.setup_code = 3
		result.status = 4
		return
	}
	result.trampoline = trampoline
	result.relay = 0
	observer_entry = entry
	observer_branch = plan.entry_jump[0]
	observer_original = transmute(Ordering_Callback)uintptr(trampoline)

	barrier: hook.Execution_Barrier
	state: hook.Inline_State
	parked := false
	for _ in 0 ..< 64 {
		if !hook.enter_execution_barrier(&barrier, deallocate) {
			result.status = 5
			result.threads = u64(barrier.count)
			return
		}
		result.threads = u64(barrier.count)
		result.privatize_code = i64(protect(task, page, page_size, 0, 1 | 2 | 16))
		if result.privatize_code != 0 {
			result.status = 6
			if !hook.leave_execution_barrier(&barrier) {result.barrier_leave_code = 1}
			return
		}
		for index in 0 ..< 4 {intrinsics.volatile_store(&entry_words[index], expected[index])}
		result.execute_code = i64(protect(task, page, page_size, 0, initial.protection))
		if result.execute_code != 0 {
			// Never resume the server into a page that could not be made executable.
			result.status = 7
			write_file(STATUS_PATH, &result, size_of(result))
			for {intrinsics.cpu_relax()}
		}
		if !hook.write_inline_loop_via_alias(entry, expected, deallocate) {
			result.install_code = 1
			if !hook.leave_execution_barrier(&barrier) {result.barrier_leave_code = 1}
			result.status = 8
			return
		}
		if !hook.leave_execution_barrier(&barrier) {
			result.barrier_leave_code = 1
			write_file(STATUS_PATH, &result, size_of(result))
			for {intrinsics.cpu_relax()}
		}
		for _ in 0 ..< 100_000 {intrinsics.cpu_relax()}
		if !hook.enter_execution_barrier(&barrier, deallocate) {
			if !hook.restore_inline_loop_via_alias(entry, expected, deallocate) {
				write_file(STATUS_PATH, &result, size_of(result))
				for {intrinsics.cpu_relax()}
			}
			result.status = 5
			return
		}
		inside, checked := hook.barrier_has_pc_in_range(&barrier, entry + 4, hook.INLINE_PATCH_BYTES - 4)
		if checked && !inside {
			parked = true
			break
		}
		if !hook.restore_inline_loop_via_alias(entry, expected, deallocate) {
			write_file(STATUS_PATH, &result, size_of(result))
			for {intrinsics.cpu_relax()}
		}
		if !hook.leave_execution_barrier(&barrier) {
			result.barrier_leave_code = 1
			write_file(STATUS_PATH, &result, size_of(result))
			for {intrinsics.cpu_relax()}
		}
	}
	if !parked {
		result.install_code = 2
		result.status = 8
		return
	}
	if hook.install_inline_after_loop(&state, entry, replacement, expected, deallocate) {
		result.install_code = 0
	} else {
		result.install_code = 3
		hook.teardown_inline_quiescent(&state)
		if !hook.restore_inline_loop_via_alias(entry, expected, deallocate) {
			write_file(STATUS_PATH, &result, size_of(result))
			for {intrinsics.cpu_relax()}
		}
	}
	final, final_ok := region_info(page, page_size)
	if final_ok {
		result.final_current = i64(final.protection)
		result.final_max = i64(final.max_protection)
	}
	if !hook.leave_execution_barrier(&barrier) {result.barrier_leave_code = 1}
	if barrier.active {
		write_file(STATUS_PATH, &result, size_of(result))
		for {intrinsics.cpu_relax()}
	}
	if result.install_code != 0 {result.status = 8; return}
	if result.barrier_leave_code != 0 || !final_ok || final.protection != 5 {
		result.status = 9
		return
	}
	thread: posix.pthread_t
	thread_result := posix.pthread_create(&thread, nil, control_thread, nil)
	result.thread_create_code = i64(thread_result)
	if thread_result != nil {
		result.status = 10
		return
	}
	result.status = 0
}

observer_start :: proc "c" () {
	context = runtime.default_context()
	install_observer()
}

@(link_section = "__DATA,__mod_init_func", linkage = "strong", require)
observer_init: proc "c" () = observer_start
