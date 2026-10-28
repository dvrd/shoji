package main

// Read-only inspection of SkyLight mapped in this process. This neither opens
// WindowServer's task port nor invokes any resolved server/window entry point.
import "core:fmt"
import "core:os"
import "core:strings"
import posix "core:sys/posix"

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
foreign import system "system:System"
foreign system {
	dladdr :: proc "c" (address: rawptr, info: ^Image_Info) -> i32 ---
}

main :: proc() {
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
		at += uintptr(command.size)
	}
	if text == nil || linkedit == nil || symtab == nil {
		fmt.println("No inspectable symbol table"); return
	}
	slide := base - uintptr(text.address)
	link_base := slide + uintptr(linkedit.address) - uintptr(linkedit.offset)
	symbols := ([^]Symbol)(link_base + uintptr(symtab.symbols_offset))
	names := ([^]u8)(link_base + uintptr(symtab.strings_offset))
	fmt.printf("mapped_symbols=%d\n", symtab.symbols_count)
	matches, printed: int
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
}
