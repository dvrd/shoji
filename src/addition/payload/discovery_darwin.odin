package payload

import m "../../macos"
import p "../patterns"
import wire "../protocol"
import "core:fmt"
import objc "core:sys/darwin/Foundation"

Globals :: struct {
	dock, pictures:           Object,
	add, remove, move, focus: rawptr,
	caps:                     wire.Capabilities,
	version:                  p.Version,
	cid:                      i32,
}
g: Globals
locate :: proc(bytes: []u8, offset: u64, pattern: string) -> rawptr {
	if offset == 0 || offset >= u64(len(bytes)) || pattern == "" {return nil}
	compiled, ok := p.compile(pattern)
	if !ok {return nil};defer p.destroy(compiled)
	stop := min(len(bytes), int(offset) + 0x1286a0 + len(compiled.bytes))
	at, found := p.find(bytes[int(offset):stop], compiled)
	if !found {return nil}
	return rawptr(&bytes[int(offset) + at])
}
resolve_global :: proc(address: rawptr) -> Object {
	if address == nil {return nil}
	value: u64
	when ODIN_ARCH == .arm64 {
		instructions := ([^]u32)(address)
		decoded, ok := p.decode_adrp_add(instructions[0], instructions[1], u64(uintptr(address)))
		if !ok {return nil};value = decoded
	} else {
		// Read unaligned RIP displacement without imposing pointer alignment.
		displacement: i32
		copy(((^[4]u8)(&displacement))[:], (([^]u8)(address))[:4])
		value = u64(i64(uintptr(address)) + i64(displacement) + 4)
	}
	return (^Object)(uintptr(value))^
}
discover :: proc() {
	g.cid = m.SLSMainConnectionID()
	info := send(Object, objc.ProcessInfo, "processInfo")
	version := send(objc.OperatingSystemVersion, info, "operatingSystemVersion")
	g.version = {int(version.majorVersion), int(version.minorVersion), int(version.patchVersion)}
	if !p.supported(
		g.version,
	) {fmt.eprintln("shoji-sa: unsupported Dock version", g.version);return}
	size: uint
	data := getsegmentdata(_dyld_get_image_header(0), "__TEXT", &size)
	if data == nil {return}
	bytes := data[:size]
	dock := locate(
		bytes,
		p.get_dock_spaces_offset(g.version),
		p.get_dock_spaces_pattern(g.version),
	)
	g.dock = resolve_global(dock)
	pictures := locate(bytes, p.get_dppm_offset(g.version), p.get_dppm_pattern(g.version))
	g.pictures = resolve_global(pictures)
	// Sonoma's alternate desktop-picture-manager slot is eight bytes earlier.
	if g.pictures == nil && pictures != nil {
		when ODIN_ARCH == .arm64 {
			ins := ([^]u32)(pictures)
			address, ok := p.decode_adrp_add(ins[0], ins[1], u64(uintptr(pictures)))
			if ok {g.pictures = (^Object)(uintptr(address - 8))^}
		} else {
			displacement: i32;copy(((^[4]u8)(&displacement))[:], (([^]u8)(pictures))[:4])
			g.pictures = (^Object)(uintptr(i64(uintptr(pictures)) + i64(displacement) - 4))^
		}
	}
	g.add = locate(bytes, p.get_add_space_offset(g.version), p.get_add_space_pattern(g.version))
	g.remove = locate(
		bytes,
		p.get_remove_space_offset(g.version),
		p.get_remove_space_pattern(g.version),
	)
	g.move = locate(bytes, p.get_move_space_offset(g.version), p.get_move_space_pattern(g.version))
	g.focus = locate(
		bytes,
		p.get_set_front_window_offset(g.version),
		p.get_set_front_window_pattern(g.version),
	)
	if g.dock != nil {send(Object, g.dock, "retain");g.caps += {.Dock_Spaces}}
	if g.pictures != nil {send(Object, g.pictures, "retain");g.caps += {.Desktop_Pictures}}
	if g.add != nil {g.caps += {.Add_Space}};if g.remove != nil {g.caps += {.Remove_Space}}
	if g.move != nil {g.caps += {.Move_Space}};if g.focus != nil {g.caps += {.Focus_Window}}
	patch := locate(
		bytes,
		p.get_fix_animation_offset(g.version),
		p.get_fix_animation_pattern(g.version),
	)
	if patch != nil {
		page := u64(uintptr(patch)) & ~(vm_page_size - 1)
		// An eight-byte Intel patch can straddle the page boundary.
		span := ((u64(uintptr(patch)) + 8 + vm_page_size - 1) & ~(vm_page_size - 1)) - page
		if mach_vm_protect(mach_task_self(), page, span, 0, 1 | 2 | 16) == 0 {
			when ODIN_ARCH == .arm64 {(^u32)(patch)^ = 0x2f00e400;sys_icache_invalidate(patch, 4)} else {value: u64 = 0x660fefc0660fefc0;copy((([^]u8)(patch))[:8], ((^[8]u8)(&value))[:])}
			if mach_vm_protect(mach_task_self(), page, span, 0, 1 | 4) ==
			   0 {g.caps += {.Animation_Patch}}
		}
	}
	fmt.eprintf("shoji-sa: Dock %d.%d capabilities=%v\n", g.version.major, g.version.minor, g.caps)
}
space_object :: proc(uuid: m.Ref, id: u64) -> Object {
	if g.dock == nil || uuid == nil {return nil}
	array := send(Object, g.dock, "spacesForDisplay:", uuid)
	for i in 0 ..< send(uint, array, "count") {
		space := send(Object, array, "objectAtIndex:", i)
		if send(u64, space, "spid") == id {return space}
	};return nil
}
display_object :: proc(uuid: m.Ref) -> Object {
	array := ivar(g.dock, "_displaySpaces")
	for i in 0 ..< send(uint, array, "count") {
		display := send(Object, array, "objectAtIndex:", i)
		space := ivar(display, "_currentSpace")
		identifier := SLSCopyManagedDisplayForSpace(g.cid, send(u64, space, "spid"))
		if identifier == nil {continue}
		same := m.text(identifier) == m.text(uuid);m.CFRelease(identifier)
		if same {return display}
	};return nil
}
