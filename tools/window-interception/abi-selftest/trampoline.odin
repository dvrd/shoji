package main

import bridge "../../../src/addition/bridge"
import loader "../../../src/addition/loader"
import hook "../../../src/addition/windowserver/hook"
import "core:fmt"
import "core:os"
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
		code := mach_vm_region_recurse(loader.mach_task_self(), &address, &size, &depth, &words[0], &count)
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
	self := loader.mach_task_self()
	alias: u64
	current, maximum: i32
	code := mach_vm_remap(self, &alias, page, 0, 1, self, base, 0, &current, &maximum, 1)
	fmt.eprintf("alias diagnostic: remap=%d current=0x%x maximum=0x%x\n", code, current, maximum)
	if code != 0 {return}
	code = loader.mach_vm_protect(self, alias, page, 0, 1 | 2)
	fmt.eprintf("alias diagnostic: writable=%d\n", code)
	fmt.eprintf("alias diagnostic: release=%d\n", deallocate(self, alias, page))
}

run_trampoline :: proc(callback: Ordering_Callback) {
	when ODIN_ARCH != .arm64 {trampoline_fail("arm64e required")}
	if loader._dyld_get_image_header(0).subtype != 0x80000002 {
		trampoline_fail("arm64e ABI v0 required")
	}
	self_image := loader.dlopen(nil, 2)
	if self_image == nil {trampoline_fail("main image handle unavailable")}
	defer loader.dlclose(self_image)
	entry := u64(uintptr(loader.raw_symbol(self_image, "shoji_abi_original")))
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

	kernel := loader.dlopen("/usr/lib/system/libsystem_kernel.dylib", 2)
	if kernel == nil {trampoline_fail("kernel library unavailable")}
	defer loader.dlclose(kernel)
	allocate := cast(proc "c" (_: u32, _: ^u64, _: u64, _: i32) -> i32)loader.raw_symbol(kernel, "mach_vm_allocate")
	deallocate := cast(proc "c" (_: u32, _: u64, _: u64) -> i32)loader.raw_symbol(kernel, "mach_vm_deallocate")
	if allocate == nil || deallocate == nil {trampoline_fail("Mach allocation symbols unavailable")}
	self := loader.mach_task_self()
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
	if code := loader.mach_vm_protect(self, region, 2 * page, 0, 1 | 4); code != 0 {
		trampoline_fail("cannot protect trampoline/relay", code)
	}

	initial_region, region_ok := trampoline_region(base, page)
	if !region_ok || initial_region.protection != 5 || initial_region.max_protection != 5 {
		trampoline_fail("unexpected native text protections")
	}
	fmt.eprintln("trampoline stage: privatize")
	privatize_code := loader.mach_vm_protect(self, base, page, 0, 1 | 2 | 16)
	fmt.eprintf("privatize result=%d\n", privatize_code)
	if privatize_code != 0 {os.exit(1)}
	intrinsics.volatile_store((^u32)(uintptr(entry)), hook.PACIBSP)
	fmt.eprintln("privatize COW store completed")
	execute_code := loader.mach_vm_protect(self, base, page, 0, initial_region.protection)
	fmt.eprintf("execute restore result=%d\n", execute_code)
	// The native target and custom failure helper share this page. Never call
	// that helper until execute permission is known to have been restored.
	if execute_code != 0 {os.exit(1)}
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
	if code := shoji_abi_run(target_callback); code != 0 {
		trampoline_fail("restored native target", code)
	}
	if code := loader.mach_vm_protect(self, base, page, 1, initial_region.max_protection); code != 0 {
		trampoline_fail("restore native text maximum protection", code)
	}
	final_region, final_ok := trampoline_region(base, page)
	if !final_ok || final_region != initial_region {
		trampoline_fail("verify final native text protections")
	}
	fmt.printf("PASS: 16 C -> patched C entry -> Odin -> trampoline -> original C round trips; pointer arrays, signed operations, booleans and returns preserved; entry, aliases and protections restored\n")
}
