package shoji

import "core:strings"
import "core:sync"
foreign import sls "system:SkyLight.framework"
foreign import libc "system:c"

// Iterator getters and the sublevel RPC follow yabai's macOS 27 port:
// https://github.com/LCS-Dev-Ergos/yabai/blob/9da3923176d88e6c44a7802fa7d6374ae40414f4/src/window.c
// Unlike the exported getters, these read windows owned by other connections.
@(default_calling_convention = "c")
foreign sls {
	SLSWindowIteratorGetTags :: proc(iterator: Ref) -> u64 ---
	SLSWindowIteratorGetLevel :: proc(iterator: Ref) -> i32 ---
	SLSWindowIteratorGetWindowID :: proc(iterator: Ref) -> u32 ---
}

window_query_appearance :: proc(
	cid: i32,
	wid: u32,
) -> (
	tags: Maybe(u64),
	level: Maybe(i32),
) {
	id := wid
	number := CFNumberCreate(nil, 3, &id)
	if number == nil {
		return
	}
	defer CFRelease(number)
	array := CFArrayCreate(nil, &number, 1, nil)
	if array == nil {
		return
	}
	defer CFRelease(array)
	query := SLSWindowQueryWindows(cid, array, 1)
	if query == nil {
		return
	}
	defer CFRelease(query)
	iterator := SLSWindowQueryResultCopyWindows(query)
	if iterator == nil {
		return
	}
	defer CFRelease(iterator)
	if SLSWindowIteratorGetCount(iterator) != 1 ||
	   !SLSWindowIteratorAdvance(iterator) ||
	   SLSWindowIteratorGetWindowID(iterator) != wid {
		return
	}
	return SLSWindowIteratorGetTags(iterator), SLSWindowIteratorGetLevel(
		iterator,
	)
}

// All fields have four-byte alignment, matching the MIG wire layout. Extra
// storage accepts a receive trailer without letting it overlap the payload.
Sublevel_Message :: struct {
	bits, size, remote, local, voucher: u32,
	id: i32,
	ndr: [8]u8,
	code: u32,
	value: i32,
	storage: [88]u8,
}
SUBLEVEL_NDR :: [8]u8{0, 0, 0, 0, 1, 0, 0, 0}

decode_sublevel_reply :: proc(
	reply: ^Sublevel_Message,
	request: i32,
) -> Maybe(i32) {
	if reply.size != 40 ||
	   reply.id != request + 100 ||
	   reply.bits & 0x80000000 != 0 ||
	   reply.ndr != SUBLEVEL_NDR ||
	   reply.code != 0 {
		return nil
	}
	return reply.value
}

@(default_calling_convention = "c")
foreign libc {
	_dyld_image_count :: proc() -> u32 ---
	_dyld_get_image_name :: proc(index: u32) -> cstring ---
	_dyld_get_image_header :: proc(index: u32) -> rawptr ---
	_dyld_get_image_vmaddr_slide :: proc(index: u32) -> uintptr ---
	mach_reply_port :: proc() -> u32 ---
	mach_task_self :: proc() -> u32 ---
	mach_port_destroy :: proc(task, port: u32) -> i32 ---
	mach_msg :: proc(message: rawptr, options, send_size, receive_size, receive_port, timeout, notify: u32) -> i32 ---
	mach_msg_destroy :: proc(message: rawptr) ---
}

Readback_Header :: struct {
	magic, cpu, subtype, kind, commands, commands_size, flags, reserved: u32,
}
Readback_Command :: struct {
	kind, size: u32,
}
Readback_Segment :: struct {
	kind, size: u32,
	name: [16]u8,
	address, vm_size, offset, file_size: u64,
	maxprot, initprot, sections, flags: u32,
}
Readback_Symtab :: struct {
	kind, size, symbols, count, strings, strings_size: u32,
}
Readback_Symbol :: struct {
	name: u32,
	kind, section: u8,
	description: u16,
	value: u64,
}

// Restrict lookup to bounded tables in the already loaded SkyLight image.
// No scanning for machine-code patterns or dependency on a fixed address.
readback_image_symbol :: proc(
	base: rawptr,
	slide: uintptr,
	name: string,
) -> rawptr {
	if base == nil {
		return nil
	}
	header := (^Readback_Header)(base)
	if header.magic != 0xfeedfacf ||
	   header.commands > 1000 ||
	   header.commands_size > 16 * 1024 * 1024 {
		return nil
	}
	address := uintptr(base)
	if address >
	   max(uintptr) -
		   size_of(Readback_Header) -
		   uintptr(header.commands_size) {
		return nil
	}
	offset := uintptr(size_of(Readback_Header))
	remaining := uintptr(header.commands_size)
	linkedit, text: ^Readback_Segment
	table: ^Readback_Symtab
	for _ in 0 ..< header.commands {
		if remaining < size_of(Readback_Command) {
			return nil
		}
		command := (^Readback_Command)(address + offset)
		if command.size < size_of(Readback_Command) ||
		   uintptr(command.size) > remaining {
			return nil
		}
		if command.kind == 0x19 && command.size >= size_of(Readback_Segment) {
			segment := (^Readback_Segment)(command)
			if strings.has_prefix(string(segment.name[:]), "__LINKEDIT\x00") {
				linkedit = segment
			}
			if strings.has_prefix(string(segment.name[:]), "__TEXT\x00") {
				text = segment
			}
		} else if command.kind == 2 &&
		   command.size >= size_of(Readback_Symtab) {
			table = (^Readback_Symtab)(command)
		}
		offset += uintptr(command.size); remaining -= uintptr(command.size)
	}
	if linkedit == nil ||
	   text == nil ||
	   table == nil ||
	   linkedit.address < linkedit.offset {
		return nil
	}
	if linkedit.offset > max(u64) - linkedit.file_size {
		return nil
	}
	end := linkedit.offset + linkedit.file_size
	if u64(table.symbols) < linkedit.offset ||
	   u64(table.strings) < linkedit.offset ||
	   u64(table.symbols) + u64(table.count) * size_of(Readback_Symbol) >
		   end ||
	   u64(table.strings) + u64(table.strings_size) > end {
		return nil
	}
	origin := linkedit.address - linkedit.offset
	if origin > max(u64) - u64(slide) || end > max(u64) - origin - u64(slide) {
		return nil
	}
	origin += u64(slide)
	symbols := ([^]Readback_Symbol)(uintptr(origin + u64(table.symbols)))
	names := ([^]u8)(uintptr(origin + u64(table.strings)))
	for index in 0 ..< table.count {
		symbol := symbols[index]
		if symbol.kind & 0xe0 != 0 ||
		   symbol.kind & 0x0e != 0x0e ||
		   symbol.name >= table.strings_size {
			continue
		}
		available := int(table.strings_size - symbol.name)
		if available <= len(name) {
			continue
		}
		candidate := names[symbol.name:][:len(name) + 1]
		if string(candidate[:len(name)]) != name || candidate[len(name)] != 0 {
			continue
		}
		if symbol.value < text.address ||
		   symbol.value - text.address >= text.vm_size ||
		   symbol.value > max(u64) - u64(slide) {
			return nil
		}
		return rawptr(uintptr(symbol.value + u64(slide)))
	}
	return nil
}

Readback_Port :: proc "c" (cid: i32) -> u32
readback_once: sync.Once
readback_port: Readback_Port
readback_request: i32

initialize_window_readback :: proc() {
	version: [64]u8
	length := uintptr(len(version))
	if sysctlbyname("kern.osproductversion", &version[0], &length, nil, 0) !=
	   0 {
		return
	}
	major: int
	for ch in version {
		if ch < '0' || ch > '9' {
			break
		}
		major = major * 10 + int(ch - '0')
		if major > 100 {
			return
		}
	}
	switch major {
	case 11, 12, 13, 14, 15:
		readback_request = 0x73c3
	case 26, 27:
		readback_request = 0x76e3
	case:
		return
	}
	for index in 0 ..< _dyld_image_count() {
		path := _dyld_get_image_name(index)
		if path == nil {
			continue
		}
		if string(path) !=
			   "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight" &&
		   string(path) !=
			   "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight" {
			continue
		}
		readback_port = Readback_Port(
			readback_image_symbol(
				_dyld_get_image_header(index),
				_dyld_get_image_vmaddr_slide(index),
				"_CGSGetConnectionPortById",
			),
		)
		return
	}
}

window_sublevel :: proc(cid: i32, wid: u32) -> Maybe(i32) {
	sync.once_do(&readback_once, initialize_window_readback)
	if readback_port == nil || readback_request == 0 {
		return nil
	}
	remote := readback_port(cid)
	if remote == 0 {
		return nil
	}
	reply := mach_reply_port()
	if reply == 0 {
		return nil
	}
	// A private receive right avoids stale replies after a timeout. Destroy it on
	// every exit, including send failure and invalid/error replies.
	defer mach_port_destroy(mach_task_self(), reply)
	message := Sublevel_Message {
		bits   = 0x1513,
		size   = 36,
		remote = remote,
		local  = reply,
		id     = readback_request,
		ndr    = SUBLEVEL_NDR,
		code   = wid,
	}
	// SEND_MSG | RCV_MSG | SEND_TIMEOUT | RCV_TIMEOUT; milliseconds, bounded.
	if mach_msg(
		   &message,
		   0x113,
		   36,
		   size_of(Sublevel_Message),
		   reply,
		   100,
		   0,
	   ) !=
	   0 {
		return nil
	}
	if message.bits & 0x80000000 != 0 {
		mach_msg_destroy(&message)
		return nil
	}
	return decode_sublevel_reply(&message, readback_request)
}
