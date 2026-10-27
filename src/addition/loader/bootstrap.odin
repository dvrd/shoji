package loader

import "base:intrinsics"
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
