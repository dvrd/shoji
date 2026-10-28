package patterns

import "core:strconv"
import "core:strings"
Version :: struct {
	major, minor, patch: int,
}
// The private Dock focus entry crashed on the validated arm64 15.6 target.
// Do not advertise it until its exact ABI and target are established.
focus_target_blocked :: proc(v: Version) -> bool {
	when ODIN_ARCH == .arm64 {return v == (Version{15, 6, 0})}
	return false
}
// Explicit candidate builds allow target-OS validation without changing the
// default acceptance policy for the daily-use payload.
MACOS27_CANDIDATE :: #config(SHOJI_MACOS27_CANDIDATE, false)
Pattern :: struct {
	bytes:    []u8,
	wildcard: []bool,
}
compile :: proc(text: string) -> (p: Pattern, ok: bool) {
	tokens := strings.fields(text, context.temp_allocator)
	if len(tokens) == 0 {return}
	p.bytes = make([]u8, len(tokens));p.wildcard = make([]bool, len(tokens))
	for token, i in tokens {
		if len(token) != 2 {destroy(p);return {}, false}
		// Upstream treats a leading '?' as a wildcard for the entire byte, including '?8'.
		if token[0] == '?' {p.wildcard[i] = true;continue}
		value, valid := strconv.parse_u64(token, 16)
		if !valid || value > 255 {destroy(p);return {}, false}
		p.bytes[i] = u8(value)
	}
	return p, true
}
destroy :: proc(p: Pattern) {delete(p.bytes);delete(p.wildcard)}
find :: proc(bytes: []u8, p: Pattern) -> (offset: int, found: bool) {
	if len(p.bytes) == 0 || len(p.bytes) > len(bytes) {return}
	for i in 0 ..= len(bytes) - len(p.bytes) {
		matches := true
		for expected, j in p.bytes {if !p.wildcard[j] && bytes[i + j] != expected {matches = false;break}}
		if matches {return i, true}
	}
	return
}
// Decode a PC-relative ADRP/ADD pair, including negative page displacements.
decode_adrp_add :: proc(adrp, add: u32, pc: u64) -> (u64, bool) {
	if adrp & 0x9f000000 != 0x90000000 || add & 0xff000000 != 0x91000000 {return 0, false}
	if adrp & 31 != (add >> 5) & 31 {return 0, false}
	immediate := i64(((adrp >> 5) & 0x7ffff) << 2 | ((adrp >> 29) & 3))
	if immediate & (1 << 20) != 0 {immediate -= 1 << 21}
	offset := u64((add >> 10) & 0xfff)
	if add & (1 << 22) != 0 {offset <<= 12}
	return u64(i64(pc & ~u64(4095)) + (immediate << 12)) + offset, true
}
supported :: proc(v: Version) -> bool {
	when ODIN_ARCH == .arm64 {return v.major == 12 || v.major == 13 || v.major == 14 || v.major == 15 || v.major == 26 || (MACOS27_CANDIDATE && v == (Version{27, 0, 1}))} else {return v.major == 11 || v.major == 12 || v.major == 13 || v.major == 14 || v.major == 15 || v.major == 26}
}
