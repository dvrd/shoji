package main

import bridge "../../../../src/dock"
import hook "../../../../src/experimental/window_server"
import "core:fmt"
import "core:os"
import mach "core:sys/darwin"
import "base:intrinsics"
import "core:sys/posix"

foreign import system "system:System"
@(default_calling_convention = "c")
foreign system {
	sys_icache_invalidate :: proc(address: rawptr, size: uint) ---
	mach_vm_remap :: proc(target: u32, address: ^u64, size, mask: u64, flags: i32, source: u32, source_address: u64, copy: i32, current, maximum: ^i32, inheritance: i32) -> i32 ---
}

Function :: proc "c" (a, b, c, d, e, f: i32) -> i32
original: Function
calls: u32
release_attempts: u32
stress_start: u32
stress_original, stress_hooked, stress_errors: u64

stress_worker :: proc "c" (argument: rawptr) -> rawptr {
	// No Odin context or allocation on this foreign-created thread.
	function := transmute(Function)uintptr(argument)
	for intrinsics.atomic_load_explicit(&stress_start, .Acquire) == 0 {intrinsics.cpu_relax()}
	for _ in 0 ..< 1_000_000 {
		result := function(1, 2, 3, 4, 5, 6)
		switch result {
		case 28: intrinsics.atomic_add_explicit(&stress_original, 1, .Relaxed)
		case 31: intrinsics.atomic_add_explicit(&stress_hooked, 1, .Relaxed)
		case: intrinsics.atomic_add_explicit(&stress_errors, 1, .Relaxed)
		}
	}
	return nil
}

reject_release :: proc "c" (task: u32, address, size: u64) -> i32 {
	release_attempts += 1
	return 5
}

replacement :: proc "c" (a, b, c, d, e, f: i32) -> i32 {
	intrinsics.atomic_add_explicit(&calls, 1, .Relaxed)
	return original(a, b, c, d, e, f) + 3
}

fail :: proc(message: string, code: i32 = 0) {
	fmt.eprintf("FAIL: %s (%d)\n", message, code)
	os.exit(1)
}

main :: proc() {
	when ODIN_ARCH != .arm64 {fail("arm64e required")}
	if bridge._dyld_get_image_header(0).subtype != 0x80000002 {fail("arm64e ABI v0 required")}
	kernel := bridge.dlopen("/usr/lib/system/libsystem_kernel.dylib", 2)
	if kernel == nil {fail("kernel library unavailable")}
	defer bridge.dlclose(kernel)
	allocate := cast(proc "c" (_: u32, _: ^u64, _: u64, _: i32) -> i32)bridge.raw_symbol(kernel, "mach_vm_allocate")
	deallocate := cast(proc "c" (_: u32, _: u64, _: u64) -> i32)bridge.raw_symbol(kernel, "mach_vm_deallocate")
	if allocate == nil || deallocate == nil {fail("Mach allocation symbols unavailable")}
	self := bridge.mach_task_self()
	page := mach.vm_page_size
	if page == 0 || page & (page - 1) != 0 {fail("invalid page size")}
	replacement_address := bridge.strip_function(u64(uintptr(rawptr(replacement))))
	base := replacement_address & ~(page - 1)
	region: u64
	search:
	for distance := page; distance <= 0x08000000 - 3 * page; distance += page {
		for below in ([]bool{false, true}) {
			candidate, valid := hook.nearby_region_base(base, distance, 3 * page, page, below)
			if valid && allocate(self, &candidate, 3 * page, 0) == 0 {
				region = candidate
				break search
			}
		}
	}
	if region == 0 {fail("no free nearby memory for test code")}
	defer deallocate(self, region, 3 * page)
	entry, trampoline, relay := region, region + page, region + 2 * page
	target := ([^]u32)(uintptr(entry))
	target[0] = hook.PACIBSP
	for index in 1 ..= 5 {target[index] = 0x0b000000 | u32(index << 16)}
	target[6] = 0x11001c00 // add w0, w0, #7
	target[7] = 0xd65f0fff // retab
	plan, ok := hook.plan(entry, trampoline, relay, target[0])
	if !ok {fail("cannot plan verified branch")}
	trampoline_code := ([^]u32)(uintptr(trampoline))
	trampoline_code[0], trampoline_code[1] = plan.displaced, plan.resume_branch
	// ldr x16, [pc, #8]; br x16; followed by the raw replacement address.
	relay_code := ([^]u32)(uintptr(relay))
	relay_code[0], relay_code[1] = 0x58000050, 0xd61f0200
	relay_code[2], relay_code[3] = u32(replacement_address), u32(replacement_address >> 32)
	sys_icache_invalidate(rawptr(uintptr(region)), uint(3 * page))
	if code := bridge.mach_vm_protect(self, region, 3 * page, 0, 1 | 4); code != 0 {
		fail("cannot make test pages executable", code)
	}
	if len(os.args) == 2 && os.args[1] == "--check-rwx" {
		code := bridge.mach_vm_protect(self, entry, page, 0, 1 | 2 | 4 | 16)
		fmt.printf("owned anonymous executable page RWX protection result: %d\n", code)
		if code != 0 {os.exit(1)}
		if restore := bridge.mach_vm_protect(self, entry, page, 0, 1 | 4); restore != 0 {
			fail("cannot restore test page protection", restore)
		}
		return
	}
	if len(os.args) == 2 && os.args[1] == "--check-alias" {
		alias: u64
		current, maximum: i32
		code := mach_vm_remap(self, &alias, page, 0, 1, self, entry, 0, &current, &maximum, 1)
		if code != 0 {fail("cannot remap test page", code)}
		defer deallocate(self, alias, page)
		code = bridge.mach_vm_protect(self, alias, page, 0, 1 | 2)
		if code != 0 {fail("cannot make alias writable", code)}
		alias_code := ([^]u32)(uintptr(alias))
		alias_code[0] = 0xd503201f
		shared := target[0] == 0xd503201f
		alias_code[0] = hook.PACIBSP
		sys_icache_invalidate(rawptr(uintptr(entry)), 4)
		fmt.printf("writable alias modifies executable mapping: %v\n", shared)
		if !shared {os.exit(1)}
		return
	}
	// The experimental Odin arm64e target calls raw procedure values with BLR.
	target_fn := transmute(Function)uintptr(entry)
	original = transmute(Function)uintptr(trampoline)
	if target_fn(1, 2, 3, 4, 5, 6) != 28 {fail("baseline result incorrect")}
	// Patch through the reusable alias installer. The executable mapping never
	// loses execute permission during the transaction.
	state: hook.Hook_State
	if !hook.install_entry_via_alias(&state, entry, relay, hook.PACIBSP, deallocate) {
		fail("cannot install branch through writable alias")
	}
	result := target_fn(1, 2, 3, 4, 5, 6)
	if result != 31 || calls != 1 {fail("forwarding result incorrect", result)}
	if hook.install_entry_via_alias(&state, entry, relay, hook.PACIBSP, deallocate) {
		fail("installer accepted an already-patched entry")
	}
	alias := state.alias_page
	// An unrelated writer owns this changed instruction. Teardown must leave it
	// untouched and keep our alias; never execute this deliberately broken entry.
	patch := (^u32)(uintptr(alias + entry - state.target_page))
	patch^ = 0xd503201f // nop
	sys_icache_invalidate(rawptr(uintptr(entry)), 4)
	state.deallocate = reject_release
	if hook.teardown_quiescent(&state) || !state.installed || state.alias_page != alias ||
	   patch^ != 0xd503201f || target[0] != 0xd503201f || release_attempts != 0 {
		fail("conflicting instruction was overwritten or ownership lost")
	}
	// Only the fixture knows how to remove its simulated conflict.
	patch^ = state.branch_word
	sys_icache_invalidate(rawptr(uintptr(entry)), 4)
	if hook.teardown_quiescent(&state) || state.installed || state.alias_page != alias || release_attempts != 1 {
		fail("failed release lost alias ownership")
	}
	before_release := calls
	if target_fn(1, 2, 3, 4, 5, 6) != 28 || calls != before_release {fail("release failure did not restore original")}
	if hook.install_entry_via_alias(&state, entry, relay, hook.PACIBSP, deallocate) || state.alias_page != alias {
		fail("installer accepted pending alias cleanup")
	}
	state.deallocate = deallocate
	if !hook.teardown_quiescent(&state) || state.alias_page != 0 {fail("release retry failed")}
	if !hook.install_entry_via_alias(&state, entry, relay, hook.PACIBSP, deallocate) {fail("install after cleanup failed")}
	// Model the already-restored state left by a failed post-write read-back.
	// Retry must release the retained alias rather than requiring another branch.
	patch^ = state.original_word
	sys_icache_invalidate(rawptr(uintptr(entry)), 4)
	if !hook.teardown_quiescent(&state) || state.installed || state.alias_page != 0 {
		fail("completed-restore retry retained the alias or lost the restored word")
	}
	if target_fn(1, 2, 3, 4, 5, 6) != 28 {fail("completed-restore retry did not call original")}
	if !hook.install_entry_via_alias(&state, entry, relay, hook.PACIBSP, deallocate) {fail("install after completed-restore retry failed")}
	// This fixture has one thread and no outstanding calls: quiescence is known,
	// not inferred from an active-call counter that could race with a new entry.
	for cycle in 0 ..< 100 {
		if !hook.teardown_quiescent(&state) {fail("alias teardown failed")}
		if state.alias_page != 0 || state.installed {fail("alias ownership not cleared")}
		before := calls
		if target_fn(1, 2, 3, 4, 5, 6) != 28 || calls != before {fail("original not restored")}
		if !hook.teardown_quiescent(&state) {fail("empty teardown not idempotent")}
		if !hook.install_entry_via_alias(&state, entry, relay, hook.PACIBSP, deallocate) {
			fail("reinstallation failed", i32(cycle))
		}
		if target_fn(1, 2, 3, 4, 5, 6) != 31 || calls != before + 1 {fail("reinstalled forwarding failed")}
	}
	if !hook.teardown_quiescent(&state) {fail("final alias teardown failed")}
	before_stress := calls
	workers: [4]posix.pthread_t
	worker := transmute(proc "c" (rawptr) -> rawptr)uintptr(bridge.sign_function(u64(uintptr(rawptr(stress_worker)))))
	for &thread in workers {
		if posix.pthread_create(&thread, nil, worker, rawptr(uintptr(entry))) != nil {fail("stress worker creation failed")}
	}
	intrinsics.atomic_store_explicit(&stress_start, 1, .Release)
	observed := false
	for _ in 0 ..< 10_000_000 {
		if intrinsics.atomic_load_explicit(&stress_original, .Acquire) >= 10_000 {observed = true; break}
		intrinsics.cpu_relax()
	}
	if !observed {fail("stress workers did not reach baseline")}
	if !hook.install_entry_via_alias(&state, entry, relay, hook.PACIBSP, deallocate) {fail("concurrent installation failed")}
	for thread in workers {
		if posix.pthread_join(thread, nil) != nil {fail("stress worker join failed")}
	}
	if stress_errors != 0 || stress_hooked == 0 || stress_original + stress_hooked != 4_000_000 ||
	   u64(calls - before_stress) != stress_hooked {
		fail("concurrent callers returned unexpected results")
	}
	// Joining every caller establishes the fixture's teardown barrier.
	if !hook.teardown_quiescent(&state) {fail("post-stress teardown failed")}
	if target_fn(1, 2, 3, 4, 5, 6) != 28 {fail("post-stress original not restored")}
	fmt.printf("PASS: 4,000,000 concurrent calls (%d original, %d hooked); conflict/retry and 100 alias lifecycle cycles\n", stress_original, stress_hooked)
}
