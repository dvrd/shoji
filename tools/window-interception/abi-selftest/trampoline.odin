package main

import bridge "../../../src/dock"
import hook "../../../src/experimental/window_server"
import "core:fmt"
import "core:os"
import "core:sys/posix"
import mach "core:sys/darwin"
import "base:intrinsics"

foreign import system "system:System"

@(default_calling_convention = "c")
foreign system {
	sys_icache_invalidate :: proc(address: rawptr, size: uint) ---
	mach_vm_remap :: proc(target: u32, address: ^u64, size, mask: u64, flags: i32, source: u32, source_address: u64, copy: i32, current, maximum: ^i32, inheritance: i32) -> i32 ---
	mach_vm_region_recurse :: proc(task: u32, address, size: ^u64, depth: ^u32, info: ^u32, count: ^u32) -> i32 ---
}

trampoline_original: Ordering_Callback
Trampoline_Protect :: proc "c" (task: u32, address, size: u64, maximum, protection: i32) -> i32
Trampoline_Exit :: proc "c" (status: i32)

concurrent_start, concurrent_stop: u32
concurrent_calls, concurrent_errors: u64

concurrent_worker :: proc "c" (argument: rawptr) -> rawptr {
	callback := transmute(Ordering_Callback)uintptr(argument)
	for intrinsics.atomic_load_explicit(&concurrent_start, .Acquire) == 0 {intrinsics.cpu_relax()}
	for intrinsics.atomic_load_explicit(&concurrent_stop, .Acquire) == 0 {
		if shoji_abi_run(callback) != 0 {
			intrinsics.atomic_add_explicit(&concurrent_errors, 1, .Relaxed)
		}
		intrinsics.atomic_add_explicit(&concurrent_calls, 1, .Relaxed)
	}
	return nil
}

concurrent_join :: proc(workers: ^[4]posix.pthread_t, started: ^int, immediate_exit: Trampoline_Exit) {
	intrinsics.atomic_store_explicit(&concurrent_start, 1, .Release)
	intrinsics.atomic_store_explicit(&concurrent_stop, 1, .Release)
	for index in 0 ..< started^ {
		if posix.pthread_join(workers[index], nil) != nil {immediate_exit(1)}
	}
	started^ = 0
}

concurrent_failure :: proc(reason: string, barrier_active: bool) -> bool {
	fmt.eprintf("concurrent failure: %s; calls=%d errors=%d forwarded=%d barrier_active=%v\n",
		reason, intrinsics.atomic_load_explicit(&concurrent_calls, .Acquire),
		intrinsics.atomic_load_explicit(&concurrent_errors, .Acquire),
		intrinsics.atomic_load_explicit(&forward_calls, .Acquire), barrier_active)
	return false
}

run_concurrent :: proc(entry, base, trampoline, relay: u64, target_callback: Ordering_Callback,
	protect: Trampoline_Protect, immediate_exit: Trampoline_Exit, deallocate: hook.Deallocate,
	initial_region: Trampoline_Region) -> bool {
	state: hook.Hook_State
	defer hook.teardown_quiescent(&state)
	barrier: hook.Execution_Barrier
	workers: [4]posix.pthread_t
	started := 0
	defer {
		if barrier.active {immediate_exit(1)}
		concurrent_join(&workers, &started, immediate_exit)
		trampoline_original = nil
	}
	defer {
		if barrier.active && !hook.leave_execution_barrier(&barrier) {immediate_exit(1)}
	}
	intrinsics.atomic_store_explicit(&concurrent_start, 0, .Relaxed)
	intrinsics.atomic_store_explicit(&concurrent_stop, 0, .Relaxed)
	intrinsics.atomic_store_explicit(&concurrent_calls, 0, .Relaxed)
	intrinsics.atomic_store_explicit(&concurrent_errors, 0, .Relaxed)
	intrinsics.atomic_store_explicit(&forward_calls, 0, .Relaxed)
	trampoline_original = transmute(Ordering_Callback)uintptr(trampoline)
	worker := transmute(proc "c" (rawptr) -> rawptr)uintptr(bridge.sign_function(u64(uintptr(rawptr(concurrent_worker)))))
	for &thread in workers {
		if posix.pthread_create(&thread, nil, worker, rawptr(transmute(uintptr)target_callback)) != nil {
			return concurrent_failure("pthread_create", barrier.active)
		}
		started += 1
	}
	intrinsics.atomic_store_explicit(&concurrent_start, 1, .Release)
	baseline := false
	for _ in 0 ..< 10_000_000 {
		if intrinsics.atomic_load_explicit(&concurrent_calls, .Acquire) >= 1000 {baseline = true; break}
		intrinsics.cpu_relax()
	}
	if !baseline || intrinsics.atomic_load_explicit(&concurrent_errors, .Acquire) != 0 ||
	   intrinsics.atomic_load_explicit(&forward_calls, .Acquire) != 0 {
		return concurrent_failure("baseline calls/errors/forwarding", barrier.active)
	}
	if !hook.enter_execution_barrier(&barrier, deallocate) {
		return concurrent_failure("thread barrier enter", barrier.active)
	}
	calls_before := intrinsics.atomic_load_explicit(&concurrent_calls, .Acquire)
	for _ in 0 ..< 10_000 {intrinsics.cpu_relax()}
	if intrinsics.atomic_load_explicit(&concurrent_calls, .Acquire) != calls_before {
		return concurrent_failure("calls advanced while suspended", barrier.active)
	}
	task := bridge.mach_task_self()
	if protect(task, base, mach.vm_page_size, 0, 1 | 2 | 16) != 0 {immediate_exit(1)}
	intrinsics.volatile_store((^u32)(uintptr(entry)), hook.PACIBSP)
	if protect(task, base, mach.vm_page_size, 0, initial_region.protection) != 0 {immediate_exit(1)}
	if !hook.install_entry_via_alias(&state, entry, relay, hook.PACIBSP, deallocate) {
		return concurrent_failure("install", barrier.active)
	}
	if !hook.leave_execution_barrier(&barrier) {
		return concurrent_failure("thread barrier leave", barrier.active)
	}
	observed := false
	for _ in 0 ..< 10_000_000 {
		if intrinsics.atomic_load_explicit(&forward_calls, .Acquire) >= 4000 {observed = true; break}
		intrinsics.cpu_relax()
	}
	if !observed || intrinsics.atomic_load_explicit(&concurrent_errors, .Acquire) != 0 {
		return concurrent_failure("forwarded calls/errors", barrier.active)
	}
	concurrent_join(&workers, &started, immediate_exit)
	trampoline_original = nil
	if !hook.teardown_quiescent(&state) {
		return concurrent_failure("teardown", barrier.active)
	}
	// Installation can split one shoji_abi_run across original and hooked calls,
	// so the forwarded total need not be a multiple of its four calls per run.
	forwarded := intrinsics.atomic_load_explicit(&forward_calls, .Acquire)
	fmt.printf("owned barrier: calls=%d forwarded=%d stable_during_privatization=true\n",
		intrinsics.atomic_load_explicit(&concurrent_calls, .Acquire), forwarded)
	return true
}

trampoline_fail :: proc(message: string, code: i32 = 0) {
	fmt.eprintf("FAIL: owned trampoline fixture: %s (%d)\n", message, code)
	os.exit(1)
}

Trampoline_Region :: struct {
	protection, max_protection: i32,
}

trampoline_region :: proc(page, page_size: u64) -> (info: Trampoline_Region, ok: bool) {
	depth: u32
	for _ in 0 ..< 16 {
		address := page
		size: u64
		words: [19]u32
		count := u32(len(words))
		code := mach_vm_region_recurse(bridge.mach_task_self(), &address, &size, &depth, &words[0], &count)
		if code != 0 || count < 13 || address > page || page - address > size ||
		   page_size > size - (page - address) {return {}, false}
		if words[12] == 0 {return {i32(words[0]), i32(words[1])}, true}
		depth += 1
	}
	return {}, false
}

diagnose_alias :: proc(entry: u64, deallocate: hook.Deallocate) {
	page := mach.vm_page_size
	base := entry & ~(page - 1)
	self := bridge.mach_task_self()
	alias: u64
	current, maximum: i32
	code := mach_vm_remap(self, &alias, page, 0, 1, self, base, 0, &current, &maximum, 1)
	fmt.eprintf("alias diagnostic: remap=%d current=0x%x maximum=0x%x\n", code, current, maximum)
	if code != 0 {return}
	code = bridge.mach_vm_protect(self, alias, page, 0, 1 | 2)
	fmt.eprintf("alias diagnostic: writable=%d\n", code)
	fmt.eprintf("alias diagnostic: release=%d\n", deallocate(self, alias, page))
}

run_trampoline :: proc(callback: Ordering_Callback) {
	when ODIN_ARCH != .arm64 {trampoline_fail("arm64e required")}
	if bridge._dyld_get_image_header(0).subtype != 0x80000002 {
		trampoline_fail("arm64e ABI v0 required")
	}
	self_image := bridge.dlopen(nil, 2)
	if self_image == nil {trampoline_fail("main image handle unavailable")}
	defer bridge.dlclose(self_image)
	entry := u64(uintptr(bridge.raw_symbol(self_image, "shoji_abi_original")))
	replacement := bridge.strip_function(u64(uintptr(rawptr(forward))))
	if entry == 0 {trampoline_fail("native target symbol unavailable")}
	target_callback := transmute(Ordering_Callback)uintptr(bridge.sign_function(entry))
	fmt.eprintf("trampoline target: entry=0x%x first_word=0x%x replacement=0x%x\n", entry, (^u32)(uintptr(entry))^, replacement)
	fmt.eprintln("trampoline stage: direct forwarding baseline")
	if code := shoji_abi_run(callback); code != 0 {
		trampoline_fail("direct forwarding baseline", code)
	}
	if (^u32)(uintptr(entry))^ != hook.PACIBSP {
		trampoline_fail("native target does not start with PACIBSP")
	}
	fmt.eprintln("trampoline stage: native baseline")
	if code := shoji_abi_run(target_callback); code != 0 {
		trampoline_fail("native baseline", code)
	}
	fmt.eprintln("trampoline stage: entry validated")

	kernel := bridge.dlopen("/usr/lib/system/libsystem_kernel.dylib", 2)
	if kernel == nil {trampoline_fail("kernel library unavailable")}
	defer bridge.dlclose(kernel)
	allocate := cast(proc "c" (_: u32, _: ^u64, _: u64, _: i32) -> i32)bridge.raw_symbol(kernel, "mach_vm_allocate")
	deallocate := cast(proc "c" (_: u32, _: u64, _: u64) -> i32)bridge.raw_symbol(kernel, "mach_vm_deallocate")
	protect := cast(Trampoline_Protect)bridge.raw_symbol(kernel, "mach_vm_protect")
	immediate_exit := cast(Trampoline_Exit)bridge.raw_symbol(kernel, "_exit")
	if allocate == nil || deallocate == nil || protect == nil || immediate_exit == nil {
		trampoline_fail("Mach allocation symbols unavailable")
	}
	self := bridge.mach_task_self()
	page := mach.vm_page_size
	if page == 0 || page & (page - 1) != 0 {trampoline_fail("invalid page size")}
	base := entry & ~(page - 1)
	region: u64
	search:
	for distance := page; distance <= 0x08000000 - 2 * page; distance += page {
		for below in ([]bool{false, true}) {
			candidate, valid := hook.nearby_region_base(base, distance, 2 * page, page, below)
			if valid && allocate(self, &candidate, 2 * page, 0) == 0 {
				region = candidate
				break search
			}
		}
	}
	if region == 0 {trampoline_fail("no nearby trampoline/relay allocation")}
	defer deallocate(self, region, 2 * page)
	trampoline, relay := region, region + page
	plan, ok := hook.plan(entry, trampoline, relay, hook.PACIBSP)
	if !ok {trampoline_fail("cannot plan native branch")}
	trampoline_code := ([^]u32)(uintptr(trampoline))
	trampoline_code[0], trampoline_code[1] = plan.displaced, plan.resume_branch
	relay_code := ([^]u32)(uintptr(relay))
	relay_code[0], relay_code[1] = 0x58000050, 0xd61f0200
	relay_code[2], relay_code[3] = u32(replacement), u32(replacement >> 32)
	sys_icache_invalidate(rawptr(uintptr(region)), uint(2 * page))
	if code := protect(self, region, 2 * page, 0, 1 | 4); code != 0 {
		trampoline_fail("cannot protect trampoline/relay", code)
	}

	initial_region, region_ok := trampoline_region(base, page)
	if !region_ok || initial_region.protection != 5 || initial_region.max_protection != 5 {
		trampoline_fail("unexpected native text protections")
	}
	fmt.eprintln("trampoline stage: privatize")
	privatize_code := protect(self, base, page, 0, 1 | 2 | 16)
	if privatize_code != 0 {immediate_exit(1)}
	intrinsics.volatile_store((^u32)(uintptr(entry)), hook.PACIBSP)
	// No call through this image's stubs is safe here: they share the target
	// page. Only inline storage and raw libsystem calls may run before RX is back.
	execute_code := protect(self, base, page, 0, initial_region.protection)
	if execute_code != 0 {immediate_exit(1)}
	private_region, private_ok := trampoline_region(base, page)
	if !private_ok || private_region.protection != initial_region.protection {
		trampoline_fail("verify privatized native text")
	}
	fmt.printf("owned native text: privatized current=0x%x maximum=0x%x\n", private_region.protection, private_region.max_protection)

	state: hook.Hook_State
	defer hook.teardown_quiescent(&state)
	for cycle in 0 ..< 16 {
		if cycle == 0 {fmt.eprintln("trampoline stage: install")}
		if !hook.install_entry_via_alias(&state, entry, relay, hook.PACIBSP, deallocate) {
			hook.teardown_quiescent(&state)
			diagnose_alias(entry, deallocate)
			trampoline_fail("installation", i32(cycle))
		}
		if cycle == 0 {fmt.eprintln("trampoline stage: invoke patched target")}
		trampoline_original = transmute(Ordering_Callback)uintptr(trampoline)
		code := shoji_abi_run(target_callback)
		trampoline_original = nil
		if cycle == 0 {fmt.eprintln("trampoline stage: invocation returned")}
		if code != 0 {trampoline_fail("C -> Odin -> trampoline -> C", code)}
		if !hook.teardown_quiescent(&state) {trampoline_fail("quiescent teardown", i32(cycle))}
		if state.alias_page != 0 || (^u32)(uintptr(entry))^ != hook.PACIBSP {
			trampoline_fail("entry or alias restoration", i32(cycle))
		}
	}
	if !run_concurrent(entry, base, trampoline, relay, target_callback, protect, immediate_exit, deallocate, initial_region) {
		trampoline_fail("concurrent barrier/forwarding")
	}
	if code := shoji_abi_run(target_callback); code != 0 {
		trampoline_fail("restored native target", code)
	}
	if code := protect(self, base, page, 1, initial_region.max_protection); code != 0 {
		trampoline_fail("restore native text maximum protection", code)
	}
	final_region, final_ok := trampoline_region(base, page)
	if !final_ok || final_region != initial_region {
		trampoline_fail("verify final native text protections")
	}
	fmt.printf("PASS: 16 native/Odin trampoline round trips plus concurrent suspended-thread installation; pointer arrays, signed operations, booleans and returns preserved; entry, aliases and protections restored\n")
}
