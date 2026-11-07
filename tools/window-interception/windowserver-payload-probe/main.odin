package wsprobe

import "base:intrinsics"
import "base:runtime"
import "core:sys/posix"
import mach "core:sys/darwin"
import gate "../../../src/windowserver/gate"
import inject "../../../src/inject"

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
Probe_Result :: struct {
	magic: [8]u8,
	version, status: u64,
	uuid: [16]u8,
	slide, candidate, page, page_size: u64,
	initial_current, initial_max, final_current, final_max: i64,
	privatize_code, execute_code, alias_remap_code, alias_protect_code: i64,
	alias_release_code, maximum_code, barrier_leave_code: i64,
	flags, threads: u64,
}

RESULT_PATH :: "/private/tmp/shoji-ws-permission-probe-" + gate.BUILD + ".bin"
FLAG_SIGNATURE :: u64(1)
FLAG_PAGE_UNCHANGED :: u64(2)
FLAG_BARRIER_ENTER :: u64(4)
FLAG_BARRIER_LEAVE :: u64(8)
FLAG_ALIAS_RELEASED :: u64(16)
FLAG_IMAGE :: u64(32)

@(default_calling_convention = "c")
foreign system {
	dladdr :: proc(address: rawptr, info: ^Image_Info) -> i32 ---
	proc_pidpath :: proc(pid: i32, buffer: [^]u8, size: u32) -> i32 ---
	write :: proc(fd: i32, data: rawptr, size: uint) -> int ---
	close :: proc(fd: i32) -> i32 ---
	mach_vm_region_recurse :: proc(task: u32, address, size: ^u64, depth: ^u32, info: ^u32, count: ^u32) -> i32 ---
}

write_result :: proc(result: ^Probe_Result) {
	fd := posix.open(RESULT_PATH, {.WRONLY, .CREAT, .TRUNC}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if fd < 0 {return}
	data := ([^]u8)(result)
	written := 0
	for written < size_of(Probe_Result) {
		code := write(i32(fd), &data[written], uint(size_of(Probe_Result) - written))
		if code <= 0 {break}
		written += code
	}
	close(i32(fd))
}

region_info :: proc(page, page_size: u64) -> (info: Region_Info, ok: bool) {
	depth: u32
	for _ in 0 ..< 16 {
		address := page
		size: u64
		words: [19]u32
		count := u32(len(words))
		code := mach_vm_region_recurse(inject.mach_task_self(), &address, &size, &depth, &words[0], &count)
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
	return gate.valid_path(string(cstring(&buffer[0])))
}

permission_probe :: proc() {
	result := Probe_Result {
		magic = {'W', 'S', '2', '6', 'A', '4', '3', '4'},
		version = 1,
		status = 1,
	}
	defer write_result(&result)
	if !running_in_windowserver() {return}
	handle := inject.dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", 2)
	if handle == nil {result.status = 2; return}
	// The payload and all probe storage remain resident; no dylib unload is attempted.
	server := inject.raw_symbol(handle, "SLXServer")
	info: Image_Info
	if server == nil || dladdr(server, &info) == 0 {result.status = 2; return}
	location, image_ok := gate.inspect_ordering_image(info.base)
	if !image_ok {result.status = 2; return}
	result.flags |= FLAG_IMAGE
	result.uuid = location.uuid
	result.slide = location.slide
	result.candidate = location.candidate
	bytes := ([^]u8)(uintptr(location.candidate))
	if !gate.matches_ordering_entry(location, bytes[:16]) {result.status = 2; return}
	result.flags |= FLAG_SIGNATURE
	page_size := mach.vm_page_size
	if page_size == 0 || page_size & (page_size - 1) != 0 {result.status = 3; return}
	result.page_size = page_size
	result.page = location.candidate & ~(page_size - 1)
	region, region_ok := region_info(result.page, page_size)
	if !region_ok || region.protection != 5 || region.max_protection != 5 {result.status = 3; return}
	result.initial_current = i64(region.protection)
	result.initial_max = i64(region.max_protection)
	baseline := make([]u8, int(page_size))
	defer delete(baseline)
	page_bytes := ([^]u8)(uintptr(result.page))
	copy(baseline, page_bytes[:int(page_size)])

	kernel := inject.dlopen("/usr/lib/system/libsystem_kernel.dylib", 2)
	if kernel == nil {result.status = 3; return}
	protect := cast(proc "c" (_: u32, _: u64, _: u64, _: i32, _: i32) -> i32)inject.raw_symbol(kernel, "mach_vm_protect")
	deallocate := cast(gate.Deallocate)inject.raw_symbol(kernel, "mach_vm_deallocate")
	if protect == nil || deallocate == nil {result.status = 3; return}
	result.status = 0

	barrier: gate.Execution_Barrier
	if !gate.enter_execution_barrier(&barrier, deallocate) {
		result.status = 4
		result.barrier_leave_code = 1
		if barrier.active && gate.leave_execution_barrier(&barrier) {result.barrier_leave_code = 0}
		if !barrier.active {
			result.flags |= FLAG_BARRIER_LEAVE
			result.barrier_leave_code = 0
		}
		result.threads = u64(barrier.count)
		if barrier.active {
			write_result(&result)
			for {intrinsics.cpu_relax()}
		}
		return
	}
	result.flags |= FLAG_BARRIER_ENTER
	result.threads = u64(barrier.count)
	task := inject.mach_task_self()
	alias: u64
	alias_current, alias_maximum: i32
	unrecoverable := false
	for once := true; once; once = false {
		// Revalidate after suspension before the same-value COW store.
		for index in 0 ..< int(page_size) {
			if baseline[index] != page_bytes[index] {result.status = 11; break}
		}
		if result.status != 0 {break}
		result.privatize_code = i64(protect(task, result.page, page_size, 0, 1 | 2 | 16))
		if result.privatize_code != 0 {result.status = 5; break}
		intrinsics.volatile_store((^u32)(uintptr(location.candidate)), gate.PACIBSP)
		result.execute_code = i64(protect(task, result.page, page_size, 0, region.protection))
		if result.execute_code != 0 {result.status = 6; unrecoverable = true; break}
		result.alias_remap_code = i64(gate.hook_mach_vm_remap(task, &alias, page_size, 0, 1,
			task, result.page, 0, &alias_current, &alias_maximum, 1))
		if result.alias_remap_code != 0 {result.status = 7; break}
		result.alias_protect_code = i64(protect(task, alias, page_size, 0, 1 | 2))
		if result.alias_protect_code != 0 {result.status = 8; break}
		alias_bytes := ([^]u8)(uintptr(alias))
		for index in 0 ..< 16 {
			if alias_bytes[location.candidate - result.page + u64(index)] != bytes[index] {
				result.status = 11
				break
			}
		}
	}
	if unrecoverable {
		// Do not resume WindowServer into a page whose execute restore failed.
		// Report through direct POSIX calls and wait for external VM recovery.
		write_result(&result)
		for {intrinsics.cpu_relax()}
	}
	if alias != 0 {
		result.alias_release_code = i64(deallocate(task, alias, page_size))
		if result.alias_release_code == 0 {
			alias = 0
			result.flags |= FLAG_ALIAS_RELEASED
		} else if result.status == 0 {result.status = 9}
	}
	result.maximum_code = i64(protect(task, result.page, page_size, 1, region.max_protection))
	if result.maximum_code != 0 && result.status == 0 {result.status = 10}
	final_region, final_ok := region_info(result.page, page_size)
	if final_ok {
		result.final_current = i64(final_region.protection)
		result.final_max = i64(final_region.max_protection)
	}
	page_unchanged := final_ok && final_region.protection == region.protection &&
		final_region.max_protection == region.max_protection
	if page_unchanged {
		for index in 0 ..< int(page_size) {
			if baseline[index] != page_bytes[index] {page_unchanged = false; break}
		}
	}
	if page_unchanged {
		result.flags |= FLAG_PAGE_UNCHANGED
	} else if result.status == 0 {result.status = 11}
	if !gate.leave_execution_barrier(&barrier) {
		result.barrier_leave_code = 1
		if result.status == 0 {result.status = 12}
	} else {
		result.flags |= FLAG_BARRIER_LEAVE
	}
	if barrier.active {
		write_result(&result)
		for {intrinsics.cpu_relax()}
	}
}

shoji_ws_permission_probe_start :: proc "c" () {
	context = runtime.default_context()
	permission_probe()
}

@(link_section = "__DATA,__mod_init_func", linkage = "strong", require)
shoji_ws_permission_probe_init: proc "c" () = shoji_ws_permission_probe_start
