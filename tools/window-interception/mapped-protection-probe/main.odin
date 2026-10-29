package main

// Inspect SkyLight in this process. The default mode does not alter mappings.
// Neither mode opens WindowServer's task port or calls a server entry point.
import "core:fmt"
import "core:os"
import "core:strings"
import "base:intrinsics"
import posix "core:sys/posix"
import loader "../../../src/dock"
import hook "../../../src/experimental/window_server"

Header :: struct {
	magic: u32,
	cpu, subtype: i32,
	kind, ncmds, commands_size, flags, reserved: u32,
}
Command :: struct {
	kind, size: u32,
}
Segment :: struct {
	kind, size: u32,
	name: [16]u8,
	address, vm_size, offset, file_size: u64,
	maxprot, initprot, sections, flags: u32,
}
Symtab :: struct {
	kind,
	size,
	symbols_offset,
	symbols_count,
	strings_offset,
	strings_size: u32,
}
Symbol :: struct {
	name: u32,
	kind, section: u8,
	description: u16,
	value: u64,
}
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
foreign import system "system:System"
foreign system {
	dladdr :: proc "c" (address: rawptr, info: ^Image_Info) -> i32 ---
	mach_vm_region_recurse :: proc "c" (task: u32, address, size: ^u64, depth: ^u32, info: ^u32, count: ^u32) -> i32 ---
	getchar :: proc "c" () -> i32 ---
	vm_page_size: u64
}

// Only this disposable process is modified. The controller must start a
// witness first and coordinate its samples with PATCHED and RESTORED.
controlled_patch :: proc(page, page_size, candidate: u64, region: Region_Info, privatize_first, expand_alias_max: bool) -> (success: bool) {
	if region.protection != 5 || page_size > 1024 * 1024 {return false}
	kernel := loader.dlopen("/usr/lib/system/libsystem_kernel.dylib", 2)
	if kernel == nil {return false}
	defer loader.dlclose(kernel)
	deallocate := cast(hook.Deallocate)loader.raw_symbol(kernel, "mach_vm_deallocate")
	if deallocate == nil {return false}
	task := loader.mach_task_self()
	baseline := make([]u8, int(page_size))
	defer delete(baseline)
	bytes := ([^]u8)(uintptr(page))
	copy(baseline, bytes[:int(page_size)])
	entry := (^u32)(uintptr(candidate))
	original := entry^
	if privatize_first {
		code := loader.mach_vm_protect(task, page, page_size, 0, 1 | 2 | 16)
		if code != 0 {fmt.eprintf("private transition failed: %d\n", code); return false}
		// A same-value volatile store triggers the COW fault before creating an alias.
		intrinsics.volatile_store(entry, original)
		code = loader.mach_vm_protect(task, page, page_size, 0, region.protection)
		if code != 0 {fmt.eprintf("executable transition failed: %d\n", code); return false}
		restored, ok := region_info(page, page_size)
		if !ok || restored.protection != region.protection {return false}
	}
	fmt.printf("PATCH_STRATEGY privatize_first=%v expand_alias_max=%v\n", privatize_first, expand_alias_max)
	alias: u64
	current, maximum: i32
	code := hook.hook_mach_vm_remap(task, &alias, page_size, 0, 1, task, page, 0, &current, &maximum, 1)
	if code != 0 {fmt.eprintf("alias remap failed: %d\n", code); return false}
	fmt.printf("ALIAS_INITIAL current=0x%x maximum=0x%x\n", current, maximum)
	defer {
		release := deallocate(task, alias, page_size)
		fmt.printf("alias_release_code=%d\n", release)
		if release != 0 {success = false}
	}
	if expand_alias_max {
		code = loader.mach_vm_protect(task, alias, page_size, 1, 1 | 2)
		fmt.printf("ALIAS_MAXIMUM code=%d requested=0x3\n", code)
		if code != 0 {return false}
	}
	code = loader.mach_vm_protect(task, alias, page_size, 0, 1 | 2)
	if code != 0 {fmt.eprintf("alias writable transition failed: %d\n", code); return false}
	patch := (^u32)(uintptr(alias + candidate - page))
	if patch^ != original || entry^ != original {return false}
	fmt.println("PATCH_READY")
	if getchar() != i32('P') {fmt.eprintln("patch protocol error"); return false}
	patch^ = 0xd503201f // NOP, never executed in this probe.
	hook.hook_sys_icache_invalidate(rawptr(uintptr(candidate)), 4)
	propagated := entry^ == 0xd503201f
	fmt.printf("PATCHED alias_propagated=%v\n", propagated)
	command := getchar() // EOF also restores before returning.
	patch^ = original
	hook.hook_sys_icache_invalidate(rawptr(uintptr(candidate)), 4)
	unchanged := true
	for i in 0 ..< len(baseline) {
		if baseline[i] != bytes[i] {unchanged = false; break}
	}
	maximum_code := loader.mach_vm_protect(task, page, page_size, 1, region.max_protection)
	fmt.printf("RESTORE_MAXIMUM code=%d requested=0x%x\n", maximum_code, region.max_protection)
	final_region, final_ok := region_info(page, page_size)
	protections_restored := final_ok && final_region.protection == region.protection &&
		final_region.max_protection == region.max_protection
	fmt.printf("RESTORED_PROTECTIONS current=0x%x maximum=0x%x match=%v\n", final_region.protection, final_region.max_protection, protections_restored)
	unchanged = unchanged && protections_restored
	fmt.printf("RESTORED page_unchanged=%v\n", unchanged)
	return propagated && unchanged && command == i32('R')
}

// A witness is an independently launched process; the controller supplies the
// three phase bytes over stdin while the other process retains its patch.
witness :: proc(page, page_size, candidate: u64) -> bool {
	if page_size > 1024 * 1024 {return false}
	baseline := make([]u8, int(page_size))
	defer delete(baseline)
	bytes := ([^]u8)(uintptr(page))
	copy(baseline, bytes[:int(page_size)])
	fmt.println("WITNESS_READY")
	all_unchanged := true
	for phase in ([]u8{'B', 'D', 'A'}) {
		if getchar() != i32(phase) {
			fmt.eprintf("witness protocol error waiting for %c\n", phase)
			return false
		}
		unchanged := true
		for i in 0 ..< len(baseline) {
			if baseline[i] != bytes[i] {unchanged = false; break}
		}
		all_unchanged = all_unchanged && unchanged
		fmt.printf("WITNESS phase=%c page_unchanged=%v entry_bytes=", phase, unchanged)
		entry := ([^]u8)(uintptr(candidate))
		for i in 0 ..< 16 {fmt.printf("%02x", entry[i])}
		fmt.println()
	}
	return all_unchanged
}

region_info :: proc(page, page_size: u64) -> (info: Region_Info, ok: bool) {
	task := loader.mach_task_self()
	depth: u32
	for _ in 0 ..< 16 {
		address := page
		size: u64
		// Mach's submap info is 4-byte packed, including its 64-bit fields.
		words: [19]u32
		count := u32(len(words))
		code := mach_vm_region_recurse(task, &address, &size, &depth, &words[0], &count)
		if code != 0 || count < 13 || address > page || page - address > size ||
		   page_size > size - (page - address) {
			fmt.eprintf("candidate region query failed: code=%d count=%d depth=%d address=0x%x size=0x%x\n", code, count, depth, address, size)
			return {}, false
		}
		if words[12] == 0 {
			return {i32(words[0]), i32(words[1]), u8(words[11] >> 24)}, true
		}
		depth += 1
	}
	fmt.eprintln("candidate region nesting exceeds limit")
	return {}, false
}

main :: proc() {
	protect := false
	witness_mode := false
	patch_mode := false
	privatize_first := false
	expand_alias_max := false
	if len(os.args) > 2 {
		fmt.eprintln("usage: mapped-protection-probe [--observe | --protect | --witness | --patch | --patch-alias | --patch-alias-max]"); os.exit(2)
	}
	if len(os.args) == 2 {
		switch os.args[1] {
		case "--observe":
		case "--protect": protect = true
		case "--witness": witness_mode = true
		case "--patch": patch_mode = true; privatize_first = true
		case "--patch-alias": patch_mode = true
		case "--patch-alias-max": patch_mode = true; expand_alias_max = true
		case: fmt.eprintln("usage: mapped-protection-probe [--observe | --protect | --witness | --patch | --patch-alias | --patch-alias-max]"); os.exit(2)
		}
	}
	handle := posix.dlopen(
		"/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
		{.NOW},
	)
	if handle == nil {
		fmt.eprintln("SkyLight unavailable"); os.exit(1)
	}
	defer posix.dlclose(handle)
	for name in ([]cstring {
			"SLXServer",
			"SLSNewWindowWithOpaqueShapeAndContext",
			"SLSOrderWindow",
			"SLSTransactionOrderWindowGroup",
			"SLSTransactionSetWindowSystemAlpha",
			"SLSRegisterNotifyProc",
			"SLSRegisterConnectionNotifyProc",
			"SLSWindowManagementBridgeSetDelegate",
		}) {
		fmt.printf(
			"export %s present=%v\n",
			name,
			posix.dlsym(handle, name) != nil,
		)
	}
	info: Image_Info
	server := posix.dlsym(handle, "SLXServer")
	if server == nil || dladdr(server, &info) == 0 {
		os.exit(1)
	}
	fmt.printf("image=%s\n", info.path)
	base := uintptr(info.base)
	header := (^Header)(info.base)
	if header.magic != 0xfeedfacf || header.ncmds > 1000 {
		os.exit(1)
	}
	end := base + size_of(Header) + uintptr(header.commands_size)
	at := base + size_of(Header)
	text, linkedit: ^Segment
	symtab: ^Symtab
	uuid: [16]u8
	has_uuid := false
	for _ in 0 ..< header.ncmds {
		if at + size_of(Command) > end {
			os.exit(1)
		}
		command := (^Command)(at)
		if command.size < size_of(Command) ||
		   at + uintptr(command.size) > end {
			os.exit(1)
		}
		if command.kind == 0x19 && command.size >= size_of(Segment) {
			segment := (^Segment)(at)
			name := string(segment.name[:])
			if strings.has_prefix(name, "__TEXT\x00") {
				text = segment
			}
			if strings.has_prefix(name, "__LINKEDIT\x00") {
				linkedit = segment
			}
		}
		if command.kind == 2 && command.size >= size_of(Symtab) {
			symtab = (^Symtab)(at)
		}
		if command.kind == 0x1b && command.size >= 24 {
			if has_uuid {fmt.eprintln("ambiguous image UUID"); os.exit(1)}
			bytes := ([^]u8)(at + 8)
			for i in 0 ..< 16 {uuid[i] = bytes[i]}
			has_uuid = true
		}
		at += uintptr(command.size)
	}
	if text == nil || linkedit == nil || symtab == nil {
		fmt.println("No inspectable symbol table"); return
	}
	slide := base - uintptr(text.address)
	fmt.printf("image_base=0x%x text_address=0x%x slide=0x%x\n", base, text.address, slide)
	if has_uuid {
		fmt.print("image_uuid=")
		for b in uuid {fmt.printf("%02x", b)}
		fmt.println()
	} else {
		fmt.println("image_uuid=unavailable")
	}
	link_base := slide + uintptr(linkedit.address) - uintptr(linkedit.offset)
	symbols := ([^]Symbol)(link_base + uintptr(symtab.symbols_offset))
	names := ([^]u8)(link_base + uintptr(symtab.strings_offset))
	fmt.printf("mapped_symbols=%d\n", symtab.symbols_count)
	matches, printed: int
	candidate: uintptr
	for i in 0 ..< symtab.symbols_count {
		symbol := symbols[i]
		if symbol.name >= symtab.strings_size {
			continue
		}
		start := int(symbol.name)
		stop := start
		for stop < int(symtab.strings_size) && names[stop] != 0 { stop += 1 }
		if stop == int(symtab.strings_size) {
			continue
		}
		name := string(names[start:stop])
		if name == "__ZL36CGXOrderWindowListSpaceSwitchOptionsP13CGXConnectionPKjPK10CGSOrderOpS2_jb" && symbol.value != 0 {
			if candidate != 0 {fmt.eprintln("ambiguous candidate"); os.exit(1)}
			candidate = uintptr(symbol.value) + slide
		}
		if !strings.contains(name, "Window") {
			continue
		}
		if !(strings.contains(name, "Order") ||
			   strings.contains(name, "Create") ||
			   strings.contains(name, "Commit")) {
			continue
		}
		matches += 1
		if printed < 100 {
			fmt.printf("candidate kind=0x%x %s\n", symbol.kind, name)
			printed += 1
		}
	}
	fmt.printf(
		"window_order_create_commit_name_matches=%d printed=%d\n",
		matches,
		printed,
	)
	// Only inspect entries wholly inside this image's executable text segment.
	text_start := slide + uintptr(text.address)
	if text.initprot & 5 != 5 || candidate < text_start ||
	   text.vm_size < 16 || candidate - text_start > uintptr(text.vm_size - 16) {
		fmt.eprintln("ordering candidate outside readable executable text"); os.exit(1)
	}
	if (^u32)(candidate)^ != 0xd503237f {
		fmt.eprintln("ordering candidate missing or prologue differs")
		os.exit(1)
	}
	if vm_page_size == 0 || vm_page_size & (vm_page_size - 1) != 0 {os.exit(1)}
	page := u64(candidate) & ~(vm_page_size - 1)
	region, region_ok := region_info(page, vm_page_size)
	if !region_ok {os.exit(1)}
	fmt.printf("region_protection=0x%x max_protection=0x%x share_mode=%d\n", region.protection, region.max_protection, region.share_mode)
	fmt.printf("candidate=0x%x page=0x%x page_size=%d entry_bytes=", candidate, page, vm_page_size)
	bytes := ([^]u8)(candidate)
	for i in 0 ..< 16 {fmt.printf("%02x", bytes[i])}
	fmt.println()
	if patch_mode || witness_mode {
		location := hook.Ordering_Location {
			uuid = uuid,
			slide = u64(slide),
			text_start = u64(text_start),
			text_size = text.vm_size,
			candidate = u64(candidate),
		}
		if !has_uuid || !hook.matches_ordering_entry(location, bytes[:16]) {
			fmt.eprintln("unsupported image identity, range or entry signature"); os.exit(1)
		}
	}
	if patch_mode {
		if !controlled_patch(page, vm_page_size, u64(candidate), region, privatize_first, expand_alias_max) {os.exit(1)}
		fmt.println("PASS: controlled patch restored")
		return
	}
	if witness_mode {
		if !witness(page, vm_page_size, u64(candidate)) {os.exit(1)}
		fmt.println("PASS: witness page unchanged at all requested phases")
		return
	}
	if !protect {
		fmt.println("PASS: observe-only; no protection or byte changes attempted")
		return
	}
	if region.protection != 5 {
		fmt.eprintln("refusing protection experiment: original protection is not read/execute"); os.exit(1)
	}
	code := loader.mach_vm_protect(loader.mach_task_self(), page, vm_page_size, 0, 1 | 2 | 16)
	if code != 0 {fmt.eprintf("own SkyLight page writable transition rejected: %d\n", code); os.exit(1)}
	code = loader.mach_vm_protect(loader.mach_task_self(), page, vm_page_size, 0, 1 | 4)
	if code != 0 {fmt.eprintf("own SkyLight page executable restore rejected: %d\n", code); os.exit(1)}
	restored, restored_ok := region_info(page, vm_page_size)
	if !restored_ok || restored.protection != region.protection {
		fmt.eprintln("original protection verification failed"); os.exit(1)
	}
	fmt.println("PASS: own SkyLight candidate page writable and executable transitions; no bytes changed")
}
