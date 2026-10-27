package dockscan

import "core:crypto/sha2"
import "core:fmt"
import "core:strings"

Section :: struct {
	name: string,
	address, offset, size: u64,
	executable: bool,
}
Image :: struct {
	bytes: []u8,
	slice_offset, slice_size, text_address, text_offset, text_size: u64,
	architecture, uuid: string,
	sections: [dynamic]Section,
	functions: [dynamic]u64,
}
span :: proc(b: []u8, at, size: u64) -> bool {
	return at <= u64(len(b)) && size <= u64(len(b)) - at
}
u32le :: proc(b: []u8, i: u64) -> u32 {
	return u32(b[i]) | u32(b[i + 1]) << 8 | u32(b[i + 2]) << 16 | u32(b[i + 3]) << 24
}
u32be :: proc(b: []u8, i: u64) -> u32 {
	return u32(b[i]) << 24 | u32(b[i + 1]) << 16 | u32(b[i + 2]) << 8 | u32(b[i + 3])
}
u64le :: proc(b: []u8, i: u64) -> u64 { return u64(u32le(b, i)) | u64(u32le(b, i + 4)) << 32 }
u64be :: proc(b: []u8, i: u64) -> u64 { return u64(u32be(b, i)) << 32 | u64(u32be(b, i + 4)) }
hex_bytes :: proc(b: []u8) -> string {
	s := strings.builder_make(context.allocator)
	for c in b { fmt.sbprintf(&s, "%02x", c) }
	return strings.to_string(s)
}
digest :: proc(b: []u8) -> string {
	c: sha2.Context_256; sha2.init_256(&c); sha2.update(&c, b)
	d: [32]u8; sha2.final(&c, d[:]); return hex_bytes(d[:])
}
fixed_name :: proc(b: []u8) -> string {
	n := 0; for n < len(b) && b[n] != 0 { n += 1 }; return string(b[:n])
}
// File offsets are relative to the selected slice; virtual addresses are unslid.
parse_image :: proc(data: []u8) -> (im: Image, err: string) {
	if len(data) < 32 {
		return {}, "truncated Mach-O header"
	}
	im.bytes = data; im.slice_size = u64(len(data))
	magic := u32be(data, 0)
	if magic == 0xcafebabe || magic == 0xcafebabf {
		count := u32be(data, 4); stride: u64 = 20; if magic == 0xcafebabf {
			stride = 32
		}
		if count == 0 || count > 128 || !span(data, 8, u64(count) * stride) {
			return {}, "invalid universal architecture table"
		}
		chosen := false; preferred := false
		for i: u64 = 0; i < u64(count); i += 1 {
			at := 8 + i * stride
			if u32be(data, at) != 0x100000c {
				continue
			}
			subtype := u32be(data, at + 4) & 0xffffff
			off, sz: u64
			if stride == 20 {
				off = u64(u32be(data, at + 8)); sz = u64(u32be(data, at + 12))
			} else {
				off = u64be(data, at + 8); sz = u64be(data, at + 16)
			}
			if !span(data, off, sz) || sz < 32 {
				return {}, "invalid universal slice range"
			}
			if !chosen || (!preferred && subtype == 2) {
				im.slice_offset = off; im.slice_size = sz; chosen = true; preferred = subtype == 2
			}
		}
		if !chosen {
			return {}, "no Apple silicon slice; Intel analysis is not supported"
		}
	}
	b := data[im.slice_offset:im.slice_offset + im.slice_size]
	if !span(b, 0, 32) || u32le(b, 0) != 0xfeedfacf || u32le(b, 4) != 0x100000c {
		return {}, "expected little-endian 64-bit Apple silicon Mach-O"
	}
	subtype := u32le(b, 8) & 0xffffff
	if subtype != 0 && subtype != 2 {
		return {}, fmt.tprintf("unsupported arm64 CPU subtype %d", subtype)
	}
	im.architecture = subtype == 2 ? "arm64e" : "arm64"
	ncmds := u32le(b, 16); cmdsize := u64(u32le(b, 20))
	if ncmds > 65536 || !span(b, 32, cmdsize) {
		return {}, "invalid load-command range"
	}
	stop := 32 + cmdsize; at: u64 = 32; starts_off, starts_size: u64
	text_found := false
	for _ in 0 ..< int(ncmds) {
		if at > stop || stop - at < 8 {
			return {}, "truncated load command"
		}
		cmd := u32le(b, at); sz := u64(u32le(b, at + 4))
		if sz < 8 || sz > stop - at {
			return {}, "invalid load-command size"
		}
		switch cmd {
		case 0x19:
			if sz < 72 {
				return {}, "truncated segment"
			}
			name := fixed_name(b[at + 8:at + 24]); fo := u64le(b, at + 40); fs := u64le(b, at + 48)
			if !span(b, fo, fs) {
				return {}, "segment extends beyond slice"
			}
			if name == "__TEXT" {
				im.text_address = u64le(b, at + 24); im.text_offset = fo; im.text_size = fs
				text_found = true
			}
			n := u64(u32le(b, at + 64)); if n > (sz - 72) / 80 {
				return {}, "truncated section table"
			}
			for i: u64 = 0; i < n; i += 1 {
				s := at + 72 + i * 80; flags := u32le(b, s + 64); kind := flags & 0xff
				sec := Section {
					name       = fixed_name(b[s:s + 16]),
					address    = u64le(b, s + 32),
					offset     = u64(u32le(b, s + 48)),
					size       = u64le(b, s + 40),
					executable = flags & 0x80000400 != 0,
				}
				if kind != 1 && kind != 0xc && kind != 0x12 && !span(b, sec.offset, sec.size) {
					return {}, "section extends beyond slice"
				}
				if kind != 1 && kind != 0xc && kind != 0x12 {
					append(&im.sections, sec)
				}
			}
		case 0x1b:
			if sz < 24 {
				return {}, "truncated UUID"
			}; im.uuid = hex_bytes(b[at + 8:at + 24])
		case 0x26:
			if sz < 16 {
				return {}, "truncated function starts"
			}; starts_off = u64(u32le(b, at + 8)); starts_size = u64(u32le(b, at + 12))
		}
		at += sz
	}
	if at != stop || !text_found || im.text_size == 0 {
		return {}, "invalid commands or missing __TEXT segment"
	}
	if !span(b, starts_off, starts_size) {
		return {}, "invalid function starts range"
	}
	if starts_size > 0 {
		address := im.text_address; cursor := starts_off; end := cursor + starts_size
		for cursor < end {
			delta: u64; shift: uint; done := false
			for cursor < end && shift <= 63 {
				c := b[cursor]; cursor += 1
				if shift == 63 && c & 0x7e != 0 {
					return {}, "function delta overflow"
				}
				delta |= u64(c & 0x7f) << shift
				if c & 0x80 == 0 {
					done = true; break
				}; shift += 7
			}
			if !done {
				return {}, "unterminated function delta"
			}
			if delta == 0 {
				break
			}
			if delta > max(u64) - address {
				return {}, "function address overflow"
			}
			address += delta
			if _, ok := image_offset(im, address, 4); !ok {
				return {}, "function start is outside executable code"
			}
			append(&im.functions, address)
		}
	}
	return im, ""
}
image_offset :: proc(im: Image, address, size: u64) -> (u64, bool) {
	for s in im.sections {
		if s.executable &&
		   address >= s.address &&
		   address - s.address <= s.size &&
		   size <= s.size - (address - s.address) {
			return s.offset + address - s.address, true
		}
	}
	return 0, false
}
slice_bytes :: proc(im: Image) -> []u8 {
	return im.bytes[im.slice_offset:im.slice_offset + im.slice_size]
}
