package gate

import "core:strings"

Image_Mach_Header :: struct {
	magic, cpu, subtype, kind, commands, commands_size, flags, reserved: u32,
}
Image_Load_Command :: struct {
	kind, size: u32,
}
Image_Segment :: struct {
	kind, size: u32,
	name: [16]u8,
	address, vm_size, offset, file_size: u64,
	maxprot, initprot, sections, flags: u32,
}

// Parse only a loaded image identified by dladdr. The final shared identity
// validator still has to accept the location before any candidate bytes are read.
inspect_ordering_image :: proc(base: rawptr) -> (location: Ordering_Location, ok: bool) {
	if base == nil {return}
	header := (^Image_Mach_Header)(base)
	if header.magic != 0xfeedfacf || header.commands > 1000 || header.commands_size > 16 * 1024 * 1024 {
		return
	}
	base_address := u64(uintptr(base))
	commands_size := u64(header.commands_size)
	if base_address > max(u64) - size_of(Image_Mach_Header) - commands_size {return}
	text: ^Image_Segment
	has_uuid := false
	remaining := commands_size
	offset := u64(size_of(Image_Mach_Header))
	for _ in 0 ..< header.commands {
		if remaining < size_of(Image_Load_Command) {return}
		command := (^Image_Load_Command)(uintptr(base_address + offset))
		if command.size < size_of(Image_Load_Command) || u64(command.size) > remaining {return}
		if command.kind == 0x19 && command.size >= size_of(Image_Segment) {
			segment := (^Image_Segment)(uintptr(base_address + offset))
			name := string(segment.name[:])
			if strings.has_prefix(name, "__TEXT\x00") {
				if text != nil {return}
				text = segment
			}
		} else if command.kind == 0x1b && command.size >= 24 {
			if has_uuid {return}
			bytes := ([^]u8)(uintptr(base_address + offset + 8))
			for index in 0 ..< 16 {location.uuid[index] = bytes[index]}
			has_uuid = true
		}
		offset += u64(command.size)
		remaining -= u64(command.size)
	}
	if text == nil || !has_uuid || base_address < text.address {return}
	location.slide = base_address - text.address
	if location.slide > max(u64) - ORDERING_UNSLID_ENTRY {return}
	location.candidate = location.slide + ORDERING_UNSLID_ENTRY
	if location.slide > max(u64) - text.address {return}
	location.text_start = location.slide + text.address
	location.text_size = text.vm_size
	return location, valid_ordering_location(location)
}
