package main

import bridge "../../../src/addition/bridge"
import loader "../../../src/addition/loader"
import hook "../../../src/addition/windowserver/hook"
import "core:fmt"
import "core:os"

foreign import system "system:System"
@(default_calling_convention = "c")
foreign system {
	vm_page_size: u64
	sys_icache_invalidate :: proc(address: rawptr, size: uint) ---
	mach_vm_remap :: proc(target: u32, address: ^u64, size, mask: u64, flags: i32, source: u32, source_address: u64, copy: i32, current, maximum: ^i32, inheritance: i32) -> i32 ---
}

Function :: proc "c" (a, b, c, d, e, f: i32) -> i32
original: Function
calls: u32

replacement :: proc "c" (a, b, c, d, e, f: i32) -> i32 {
	calls += 1
	return original(a, b, c, d, e, f) + 3
}

fail :: proc(message: string, code: i32 = 0) {
	fmt.eprintf("FAIL: %s (%d)\n", message, code)
	os.exit(1)
}

main :: proc() {
	when ODIN_ARCH != .arm64 {fail("arm64e required")}
	if loader._dyld_get_image_header(0).subtype != 0x80000002 {fail("arm64e ABI v0 required")}
	kernel := loader.dlopen("/usr/lib/system/libsystem_kernel.dylib", 2)
	if kernel == nil {fail("kernel library unavailable")}
	defer loader.dlclose(kernel)
	allocate := cast(proc "c" (_: u32, _: ^u64, _: u64, _: i32) -> i32)loader.raw_symbol(kernel, "mach_vm_allocate")
	deallocate := cast(proc "c" (_: u32, _: u64, _: u64) -> i32)loader.raw_symbol(kernel, "mach_vm_deallocate")
	if allocate == nil || deallocate == nil {fail("Mach allocation symbols unavailable")}
	self := loader.mach_task_self()
	page := vm_page_size
	if page == 0 || page & (page - 1) != 0 {fail("invalid page size")}
	replacement_address := bridge.strip_function(u64(uintptr(rawptr(replacement))))
	base := replacement_address & ~(page - 1)
	region: u64
	for distance := page; distance < 0x08000000 - 3 * page; distance += page {
		candidate := base + distance
		if allocate(self, &candidate, 3 * page, 0) == 0 {region = candidate; break}
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
	if code := loader.mach_vm_protect(self, region, 3 * page, 0, 1 | 4); code != 0 {
		fail("cannot make test pages executable", code)
	}
	if len(os.args) == 2 && os.args[1] == "--check-rwx" {
		code := loader.mach_vm_protect(self, entry, page, 0, 1 | 2 | 4 | 16)
		fmt.printf("owned anonymous executable page RWX protection result: %d\n", code)
		if code != 0 {os.exit(1)}
		if restore := loader.mach_vm_protect(self, entry, page, 0, 1 | 4); restore != 0 {
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
		code = loader.mach_vm_protect(self, alias, page, 0, 1 | 2)
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
	if code := loader.mach_vm_protect(self, entry, page, 0, 1 | 2 | 16); code != 0 {
		fail("cannot make test target writable", code)
	}
	target[0] = plan.entry_branch
	sys_icache_invalidate(rawptr(uintptr(entry)), 4)
	if code := loader.mach_vm_protect(self, entry, page, 0, 1 | 4); code != 0 {
		fail("cannot restore test target executable", code)
	}
	result := target_fn(1, 2, 3, 4, 5, 6)
	if result != 31 || calls != 1 {fail("forwarding result incorrect", result)}
	fmt.println("PASS: Odin arm64e dynamic trampoline forwards six arguments and result")
}
