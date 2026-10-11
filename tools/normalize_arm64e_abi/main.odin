package main

import "core:fmt"
import "core:os"

MH_MAGIC_64 :: 0xfeedfacf
CPU_TYPE_ARM64 :: 0x0100000c
CPU_SUBTYPE_ARM64E_ABI_V1 :: 0x81000002
CPU_SUBTYPE_ARM64E_ABI_V0 :: 0x80000002

read_u32_le :: proc(data: []byte, offset: int) -> u32 {
	return(
		u32(data[offset]) |
		u32(data[offset + 1]) << 8 |
		u32(data[offset + 2]) << 16 |
		u32(data[offset + 3]) << 24 \
	)
}

write_u32_le :: proc(data: []byte, offset: int, value: u32) {
	data[offset] = byte(value)
	data[offset + 1] = byte(value >> 8)
	data[offset + 2] = byte(value >> 16)
	data[offset + 3] = byte(value >> 24)
}

fail :: proc(format: string, args: ..any) -> ! {
	fmt.eprintf(format, ..args)
	fmt.eprintln()
	os.exit(1)
}

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintf("usage: %s MACH_O\n", os.args[0])
		os.exit(2)
	}
	path := os.args[1]
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fail("%s: could not read file", path)
	}
	defer delete(data)
	if len(data) < 32 {
		fail("%s: truncated Mach-O header", path)
	}
	magic := read_u32_le(data, 0)
	cputype := read_u32_le(data, 4)
	subtype := read_u32_le(data, 8)
	if magic != MH_MAGIC_64 || cputype != CPU_TYPE_ARM64 {
		fail("%s: expected a thin arm64 Mach-O executable", path)
	}
	if subtype == CPU_SUBTYPE_ARM64E_ABI_V0 {
		return
	}
	if subtype != CPU_SUBTYPE_ARM64E_ABI_V1 {
		fail("%s: expected arm64e ABI v1, found subtype 0x%08x", path, subtype)
	}
	write_u32_le(data, 8, CPU_SUBTYPE_ARM64E_ABI_V0)
	if err := os.write_entire_file(path, data); err != nil {
		fail("%s: could not write file", path)
	}
}
