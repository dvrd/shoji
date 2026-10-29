package dock

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import objc "core:sys/darwin/Foundation"
import "core:sys/posix"
import "core:time"
import target "../experimental/window_server"

foreign import sys "system:System"
foreign import cf "system:CoreFoundation.framework"

@(objc_class = "NSRunningApplication")
Running_Application :: struct {using _: objc.Object}

@(default_calling_convention = "c")
foreign cf {
	CFStringCreateWithCString :: proc(allocator: rawptr, value: cstring, encoding: u32) -> rawptr ---
	CFRelease :: proc(value: rawptr) ---
}

// Mach declarations
// ------------------------------------------------------------------------

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
	_NSGetEnviron :: proc() -> ^[^]cstring ---
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

// Copied bootstrap
// ------------------------------------------------------------------------

// This section is copied into Dock. These procedures must remain relocation-free:
// no strings, globals, direct calls, runtime checks, or implicit Odin context.
Bootstrap :: struct {
	create:                                   proc "c" (
		_: ^uint,
		_: rawptr,
		_: rawptr,
		_: rawptr,
	) -> i32,
	self:                                     proc "c" () -> uint,
	detach:                                   proc "c" (_: uint) -> i32,
	open:                                     proc "c" (_: cstring, _: i32) -> rawptr,
	error:                                    proc "c" () -> cstring,
	worker:                                   rawptr,
	path:                                     cstring,
	handle:                                   rawptr,
	reason:                                   cstring,
	create_result, detach_result:             i32,
	done, entry_ready, seen, worker_finished: u32,
}
@(link_section = "__TEXT,__shoji_boot,regular,pure_instructions", no_instrumentation)
remote_worker :: proc "c" (arg: rawptr) -> rawptr {
	data := (^Bootstrap)(arg)
	if data.detach != nil {data.detach_result = data.detach(data.self())}
	data.handle = data.open(data.path, 2)
	if data.handle == nil && data.error != nil {data.reason = data.error()}
	intrinsics.atomic_store_explicit(&data.done, 1, .Release)
	if data.handle == nil {
		for intrinsics.atomic_load_explicit(&data.seen, .Acquire) == 0 {intrinsics.cpu_relax()}
	}
	// Last access to shared data; publishing the dlopen result alone is not completion.
	intrinsics.atomic_store_explicit(&data.worker_finished, 1, .Release)
	return nil
}
@(link_section = "__TEXT,__shoji_boot,regular,pure_instructions", no_instrumentation)
remote_entry :: proc "c" (arg: rawptr) {
	data := (^Bootstrap)(arg)
	worker: uint
	start := data.worker
	when ODIN_ARCH == .arm64 {start = rawptr(uintptr(sign_worker(u64(uintptr(start)))))}
	data.create_result = data.create(&worker, nil, start, arg)
	// A raw Mach thread has no pthread TLS, so it cannot call pthread_join.
	if data.create_result != 0 {
		intrinsics.atomic_store_explicit(&data.done, 1, .Release)
	}
	intrinsics.atomic_store_explicit(&data.entry_ready, 1, .Release)
	for {intrinsics.cpu_relax()}
}

// Injection and loader lifecycle
// ------------------------------------------------------------------------

// Loading runs in an explicit CLI invocation or a daemon recovery subprocess.
// Dock is arm64e and the kernel refuses remote thread creation in an arm64e
// task from a plain arm64 process (KERN_PROTECTION_FAILURE; verified live on
// 2026-10-10), so arm64 loading delegates to the spawned Odin arm64e helper
// built by `task loader`. The helper runs the same in-process injector with
// an arm64e personality. Upstream yabai spawns a separate arm64e loader too.
run_arm64e_loader_command :: proc(arguments: []string) -> string {
	binary, err := os.get_executable_path(context.temp_allocator)
	if err != nil {return "cannot resolve shoji executable path"}
	helper := strings.concatenate({filepath.dir(binary), "/shoji-loader"}, context.temp_allocator)
	if !os.exists(helper) {return "arm64e loader helper is missing; rebuild with task build"}
	argv := make([]cstring, len(arguments) + 2, context.temp_allocator)
	argv[0] = strings.clone_to_cstring(helper, context.temp_allocator)
	for argument, i in arguments {
		argv[i + 1] = strings.clone_to_cstring(argument, context.temp_allocator)
	}
	pid: posix.pid_t
	if posix.posix_spawn(&pid, argv[0], nil, nil, &argv[0], _NSGetEnviron()^) != nil {
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

run_arm64e_loader :: proc(payload_path: string) -> string {
	return run_arm64e_loader_command({payload_path})
}

inject :: proc(payload_path: string) -> string {
	when ODIN_ARCH == .arm64 && !#config(SHOJI_ODIN_LOADER, false) {
		return run_arm64e_loader(payload_path)
	}

	path, err := filepath.abs(payload_path, context.temp_allocator)
	if err != nil || !os.exists(path) {return "scripting-addition library does not exist"}
	pool := intrinsics.objc_send(^objc.Object, objc.AutoreleasePool, "alloc")
	pool = intrinsics.objc_send(^objc.Object, pool, "init")
	defer intrinsics.objc_send(nil, pool, "drain")
	identifier := CFStringCreateWithCString(nil, "com.apple.dock", 0x08000100); defer CFRelease(identifier)
	apps := intrinsics.objc_send(
		^objc.Object,
		Running_Application,
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
	if err := inject_task(mach_task_self(), "/usr/lib/libSystem.B.dylib"); err != "" {return err}
	// A rejected dlopen must release the worker's data only after the failure
	// acknowledgment has been consumed. Exercise this in the arm64e helper too.
	err := inject_task(mach_task_self(), "/nonexistent/shoji-loader-self-test.dylib")
	if !strings.contains(err, "shoji-loader-self-test") {
		return fmt.tprintf("loader failure self-test returned an unexpected result: %s", err)
	}
	return ""
}

inject_task :: proc(task: u32, path: string) -> string {
	return inject_task_named(task, path, "Dock")
}

inject_task_named :: proc(task: u32, path: string, target: string) -> string {
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
		) -> i32)rawptr(uintptr(strip_function(u64(uintptr(create))))),
		self   = cast(proc "c" () -> uint)worker_self,
		detach = cast(proc "c" (_: uint) -> i32)detach,
		open   = cast(proc "c" (
			_: cstring,
			_: i32,
		) -> rawptr)rawptr(uintptr(strip_function(u64(uintptr(open))))),
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
	failure_reason := ""
	acknowledged := false
	for _ in 0 ..< 500 {
		time.sleep(10 * time.Millisecond)
		actual: u64
		// Read publication flags before the result. A single remote-memory copy
		// could otherwise mix pre-publication fields with newly published flags.
		flags: [4]u32
		if code := mach_vm_read_overwrite(
			task,
			data_address + u64(offset_of(Bootstrap, done)),
			size_of(flags),
			uintptr(&flags),
			&actual,
		); code != 0 || actual != size_of(flags) {
			return(
				"failed to read bootstrap completion; remote buffers retained to avoid use-after-free" \
			)
		}
		if flags[0] == 0 || flags[1] == 0 {continue}
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
		if bootstrap.create_result != 0 {
			safe_to_free = true
			return fmt.tprintf("remote pthread creation failed (%d)", bootstrap.create_result)
		}
		keep_code = true
		if bootstrap.handle == nil && !acknowledged {
			failure_reason = remote_c_string(task, uintptr(rawptr(bootstrap.reason)))
			if failure_reason == "" {failure_reason = fmt.tprintf("%s rejected the payload library", target)}
			seen: u32 = 1
			if code := mach_vm_write(
				task,
				data_address + u64(offset_of(Bootstrap, seen)),
				uintptr(&seen),
				size_of(seen),
			); code != 0 {
				return(
					"cannot acknowledge loader failure; remote buffers retained to avoid use-after-free" \
				)
			}
			acknowledged = true
		}
		// The worker must acknowledge receipt before its data can be unmapped.
		// Its return epilogue may still use copied code, so keep that allocation.
		if bootstrap.worker_finished == 0 {continue}
		safe_to_free = true
		if bootstrap.detach_result != 0 {
			return fmt.tprintf("remote pthread detach failed (%d)", bootstrap.detach_result)
		}
		if bootstrap.handle == nil {return failure_reason}
		return ""
	}
	return fmt.tprintf(
		"%s injection timed out; remote buffers retained because the loader thread may still be active",
		target,
	)
}

// Odin's experimental arm64e target retains raw procedure values. dyld returns
// signed function pointers to arm64e callers; normalize at this FFI boundary.
raw_symbol :: proc(library: rawptr, name: cstring) -> rawptr {
	return rawptr(uintptr(strip_function(u64(uintptr(dlsym(library, name))))))
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

// Experimental WindowServer integration
// ------------------------------------------------------------------------

foreign sys {
	proc_pidpath :: proc "c" (pid: i32, buffer: [^]u8, size: u32) -> i32 ---
}

windowserver_process_path :: proc(pid: i32) -> string {
	buffer: [4096]u8
	if proc_pidpath(pid, &buffer[0], u32(len(buffer))) <= 0 {
		return ""
	}
	return strings.clone(string(cstring(&buffer[0])), context.temp_allocator)
}

inject_windowserver :: proc(payload_path: string, pid: i32) -> string {
	if !target.valid_pid(pid) {
		return target.validate_target(pid, "")
	}
	path, err := filepath.abs(payload_path, context.temp_allocator)
	if err != nil || !os.exists(path) {
		return "WindowServer payload library does not exist"
	}
	if message := target.validate_target(pid, windowserver_process_path(pid));
	   message != "" {
		return message
	}
	if os.get_env(target.EXPERIMENT_ENV, context.temp_allocator) != "1" {
		return fmt.tprintf(
			"WindowServer injection is disabled; set %s=1 only inside the recoverable test VM",
			target.EXPERIMENT_ENV,
		)
	}
	when ODIN_ARCH == .arm64 && !#config(SHOJI_ODIN_LOADER, false) {
		return run_arm64e_loader_command(
			{"--windowserver", fmt.tprintf("%d", pid), path},
		)
	}
	self := mach_task_self()
	task: u32
	if code := task_for_pid(self, pid, &task); code != 0 {
		return fmt.tprintf(
			"cannot obtain WindowServer task port (%d); verify the VM's SIP, debugging, and task-port policy",
			code,
		)
	}
	defer mach_port_deallocate(self, task)
	return inject_task_named(task, path, "WindowServer")
}
