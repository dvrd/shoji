package loader

import m "../../macos"
import bridge "../bridge"
import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import objc "core:sys/darwin/Foundation"
import "core:sys/posix"
import "core:time"

// Loading is deliberately explicit. No daemon startup path calls inject.
// Dock is arm64e and the kernel refuses remote thread creation in an arm64e
// task from a plain arm64 process (KERN_PROTECTION_FAILURE; verified live on
// 2026-10-10), so arm64 loading delegates to the spawned Odin arm64e helper
// built by `task loader`. The helper runs the same in-process injector with
// an arm64e personality. Upstream yabai spawns a separate arm64e loader too.
run_arm64e_loader :: proc(payload_path: string) -> string {
	binary, err := os.get_executable_path(context.temp_allocator)
	if err != nil {return "cannot resolve shoji executable path"}
	helper := strings.concatenate({filepath.dir(binary), "/shoji-loader"}, context.temp_allocator)
	if !os.exists(helper) {return "arm64e loader helper is missing; rebuild with task build"}
	argv := [3]cstring {
		strings.clone_to_cstring(helper, context.temp_allocator),
		strings.clone_to_cstring(payload_path, context.temp_allocator),
		nil,
	}
	pid: posix.pid_t
	if posix.posix_spawn(&pid, argv[0], nil, nil, &argv[0], m._NSGetEnviron()^) != nil {
		return "cannot start arm64e loader helper"
	}
	status: i32
	if posix.waitpid(pid, &status, {}) != pid ||
	   !posix.WIFEXITED(status) ||
	   posix.WEXITSTATUS(status) != 0 {
		return "arm64e loader helper failed"
	}
	return ""
}

inject :: proc(payload_path: string) -> string {
	when ODIN_ARCH == .arm64 && !#config(SHOJI_ODIN_LOADER, false) {
		return run_arm64e_loader(payload_path)
	}

	path, err := filepath.abs(payload_path, context.temp_allocator)
	if err != nil || !os.exists(path) {return "scripting-addition library does not exist"}
	pool := m.pool_push();defer m.pool_pop(pool)
	identifier := m.cf_string("com.apple.dock");defer m.CFRelease(identifier)
	apps := intrinsics.objc_send(
		^objc.Object,
		m.Running_Application,
		"runningApplicationsWithBundleIdentifier:",
		(^objc.Object)(identifier),
	)
	if intrinsics.objc_send(uint, apps, "count") !=
	   1 {return "could not locate a unique running Dock process"}
	dock := intrinsics.objc_send(^objc.Object, apps, "objectAtIndex:", uint(0))
	if !intrinsics.objc_send(bool, dock, "isFinishedLaunching") {return "Dock is still launching"}
	pid := intrinsics.objc_send(i32, dock, "processIdentifier")
	self := mach_task_self();task: u32
	if code := task_for_pid(self, pid, &task);
	   code !=
	   0 {return fmt.tprintf("cannot obtain Dock task port (%d); injection requires the documented SIP/debugging configuration", code)}
	defer mach_port_deallocate(self, task)
	return inject_task(task, path)
}

// The self-test uses only its own task port and loads an existing system library.
// It exercises the same copied bootstrap and thread conversion as Dock injection.
self_test :: proc() -> string {
	return inject_task(mach_task_self(), "/usr/lib/libSystem.B.dylib")
}

inject_task :: proc(task: u32, path: string) -> string {
	self := mach_task_self()
	size: uint
	section := getsectiondata(_dyld_get_image_header(0), "__TEXT", "__shoji_boot", &size)
	if section == nil || size == 0 {return "loader bootstrap section is missing"}
	entry_offset := uintptr(rawptr(remote_entry)) - uintptr(raw_data(section[:size]))
	worker_offset := uintptr(rawptr(remote_worker)) - uintptr(raw_data(section[:size]))
	if entry_offset >= uintptr(size) ||
	   worker_offset >=
		   uintptr(size) {return "bootstrap procedures are outside their code section"}
	library := dlopen("/usr/lib/system/libsystem_pthread.dylib", 2)
	if library == nil {return "cannot resolve pthread bootstrap library"};defer dlclose(library)
	create := dlsym(library, "pthread_create_from_mach_thread")
	worker_self := raw_symbol(library, "pthread_self")
	detach := raw_symbol(library, "pthread_detach")
	system := dlopen("/usr/lib/libSystem.B.dylib", 2)
	if system == nil {return "cannot resolve dlopen"};defer dlclose(system)
	open := dlsym(system, "dlopen")
	describe := raw_symbol(system, "dlerror")
	if create == nil || open == nil || worker_self == nil || detach == nil || describe == nil {
		return "missing bootstrap entry point"
	}
	kernel_vm := dlopen("/usr/lib/system/libsystem_kernel.dylib", 2)
	if kernel_vm == nil {return "cannot resolve Mach VM library"};defer dlclose(kernel_vm)
	mach_vm_allocate := cast(proc "c" (_: u32, _: ^u64, _: u64, _: i32) -> i32)raw_symbol(
		kernel_vm,
		"mach_vm_allocate",
	)
	mach_vm_deallocate := cast(proc "c" (_: u32, _: u64, _: u64) -> i32)raw_symbol(
		kernel_vm,
		"mach_vm_deallocate",
	)
	if mach_vm_allocate == nil || mach_vm_deallocate == nil {return "missing Mach VM entry points"}
	code_address, stack_address, data_address: u64
	stack_size: u64 = 64 * 1024
	stack_marker: u64 = 0x00000000CAFEBABE
	data_size := u64(size_of(Bootstrap) + len(path) + 1)
	if code := mach_vm_allocate(task, &code_address, u64(size), 1);
	   code != 0 {return fmt.tprintf("cannot allocate remote code (%d)", code)}
	// The worker publishes completion before its return epilogue. Keep its code
	// mapped after success; a raw Mach entry thread cannot join a pthread.
	safe_to_free := true
	keep_code := false
	defer {if safe_to_free && !keep_code {mach_vm_deallocate(task, code_address, u64(size))}}
	if code := mach_vm_allocate(task, &stack_address, stack_size, 1);
	   code != 0 {return fmt.tprintf("cannot allocate remote stack (%d)", code)}
	defer {if safe_to_free {mach_vm_deallocate(task, stack_address, stack_size)}}
	if code := mach_vm_write(task, stack_address, uintptr(&stack_marker), size_of(stack_marker));
	   code != 0 {
		return fmt.tprintf("cannot initialize remote stack (%d)", code)
	}
	if code := mach_vm_protect(task, stack_address, stack_size, 1, 1 | 2); code != 0 {
		return fmt.tprintf("cannot protect remote stack (%d)", code)
	}
	if code := mach_vm_allocate(task, &data_address, data_size, 1);
	   code != 0 {return fmt.tprintf("cannot allocate remote data (%d)", code)}
	defer {if safe_to_free {mach_vm_deallocate(task, data_address, data_size)}}
	if code := mach_vm_write(task, code_address, uintptr(raw_data(section[:size])), u32(size));
	   code != 0 {return fmt.tprintf("cannot copy bootstrap (%d)", code)}
	if code := mach_vm_protect(task, code_address, u64(size), 0, 1 | 4);
	   code != 0 {return fmt.tprintf("cannot make bootstrap executable (%d)", code)}
	bootstrap := Bootstrap {
		create = cast(proc "c" (
			_: ^uint,
			_: rawptr,
			_: rawptr,
			_: rawptr,
		) -> i32)rawptr(uintptr(bridge.strip_function(u64(uintptr(create))))),
		self   = cast(proc "c" () -> uint)worker_self,
		detach = cast(proc "c" (_: uint) -> i32)detach,
		open   = cast(proc "c" (
			_: cstring,
			_: i32,
		) -> rawptr)rawptr(uintptr(bridge.strip_function(u64(uintptr(open))))),
		error  = cast(proc "c" () -> cstring)describe,
		worker = rawptr(uintptr(code_address + u64(worker_offset))),
		path   = cstring(rawptr(uintptr(data_address + size_of(Bootstrap)))),
	}
	if code := mach_vm_write(task, data_address, uintptr(&bootstrap), size_of(bootstrap));
	   code != 0 {return fmt.tprintf("cannot write bootstrap data (%d)", code)}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if code := mach_vm_write(
		task,
		data_address + size_of(Bootstrap),
		uintptr(rawptr(cpath)),
		u32(len(path) + 1),
	); code != 0 {return fmt.tprintf("cannot write payload path (%d)", code)}
	thread: u32
	when ODIN_ARCH == .arm64 {
		state := ARM_State {
			sp = stack_address + stack_size / 2,
			pc = code_address + u64(entry_offset),
		}
		state.pc = sign_thread_pc(state.pc)
		state.sp = sign_thread_sp(state.sp)
		state.x[0] = data_address
		converted: ARM_State
		kernel := dlopen("/usr/lib/system/libsystem_kernel.dylib", 2)
		if kernel == nil {return "cannot open kernel support library"};defer dlclose(kernel)
		convert := cast(proc "c" (
			_: u32,
			_: i32,
			_: i32,
			_: rawptr,
			_: u32,
			_: rawptr,
			_: ^u32,
		) -> i32)raw_symbol(kernel, "thread_convert_thread_state")
		if convert == nil {return "thread_convert_thread_state is unavailable"}
		if code := thread_create(task, &thread);
		   code != 0 {return fmt.tprintf("cannot create remote thread (%d)", code)}
		count: u32 = size_of(state) / 4
		code := convert(thread, 2, 6, &state, count, &converted, &count)
		if code !=
		   0 {thread_terminate(thread);mach_port_deallocate(self, thread);return fmt.tprintf("cannot convert arm64 thread state (%d)", code)}
		info := intrinsics.objc_send(^objc.Object, objc.ProcessInfo, "processInfo")
		version := intrinsics.objc_send(
			objc.OperatingSystemVersion,
			info,
			"operatingSystemVersion",
		)
		if version.majorVersion > 14 || (version.majorVersion == 14 && version.minorVersion >= 4) {
			thread_terminate(thread);mach_port_deallocate(self, thread);thread = 0
			if code := thread_create_running(task, 6, &converted, count, &thread);
			   code != 0 {return fmt.tprintf("cannot start remote thread (%d)", code)}
		} else {
			code := thread_set_state(thread, 6, &converted, count)
			if code == 0 {code = thread_resume(thread)}
			if code !=
			   0 {thread_terminate(thread);mach_port_deallocate(self, thread);return fmt.tprintf("cannot start remote thread (%d)", code)}
		}
	} else {
		// SysV ABI expects an 8-byte return-address slot on function entry.
		state := X86_State {
			rip = code_address + u64(entry_offset),
			rsp = stack_address + stack_size - 8,
			rdi = data_address,
		}
		if code := thread_create_running(task, 4, &state, size_of(state) / 4, &thread);
		   code != 0 {return fmt.tprintf("cannot start remote thread (%d)", code)}
	}
	safe_to_free = false
	defer {
		if thread_terminate(thread) != 0 {safe_to_free = false}
		mach_port_deallocate(self, thread)
	}
	for _ in 0 ..< 500 {
		time.sleep(10 * time.Millisecond)
		actual: u64
		if code := mach_vm_read_overwrite(
			task,
			data_address,
			size_of(bootstrap),
			uintptr(&bootstrap),
			&actual,
		);
		code != 0 ||
		actual !=
			size_of(
				bootstrap,
			) {return "failed to read bootstrap completion; remote buffers retained to avoid use-after-free"}
		if bootstrap.done == 0 || bootstrap.entry_ready == 0 {continue}
		safe_to_free = true
		keep_code = bootstrap.create_result == 0
		if bootstrap.create_result !=
		   0 {return fmt.tprintf("remote pthread creation failed (%d)", bootstrap.create_result)}
		if bootstrap.detach_result != 0 {
			return fmt.tprintf("remote pthread detach failed (%d)", bootstrap.detach_result)
		}
		if bootstrap.handle == nil {
			text := remote_c_string(task, uintptr(rawptr(bootstrap.reason)))
			seen: u32 = 1
			mach_vm_write(
				task,
				data_address + u64(offset_of(Bootstrap, seen)),
				uintptr(&seen),
				size_of(seen),
			)
			if text == "" {return "Dock rejected the payload library"}
			return text
		}
		return ""
	}
	return(
		"Dock injection timed out; remote buffers retained because the loader thread may still be active" \
	)
}

// Odin's experimental arm64e target retains raw procedure values. dyld returns
// signed function pointers to arm64e callers; normalize at this FFI boundary.
raw_symbol :: proc(library: rawptr, name: cstring) -> rawptr {
	return rawptr(uintptr(bridge.strip_function(u64(uintptr(dlsym(library, name))))))
}

remote_c_string :: proc(task: u32, address: uintptr) -> string {
	if address == 0 {return ""}
	buf: [240]u8
	actual: u64
	if mach_vm_read_overwrite(task, u64(address), len(buf) - 1, uintptr(&buf), &actual) != 0 ||
	   actual == 0 {
		return ""
	}
	n := 0
	for n < int(actual) && buf[n] != 0 {n += 1}
	return strings.clone(string(buf[:n]), context.temp_allocator)
}
