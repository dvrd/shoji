package engine

import "core:strings"

MAX_MESSAGE :: 1024 * 1024
// The yabai client sends a little-endian i32 byte count followed by NUL-separated argv
// and a final extra NUL. Both supported macOS architectures are little-endian.
encode_message :: proc(args: []string) -> ([]u8, bool) {
	size := 1
	if len(args) == 0 {
		return nil, false
	}
	for arg in args {
		if strings.contains(arg, "\x00") {
			return nil, false
		}
		size += len(arg) + 1
		if size > MAX_MESSAGE {
			return nil, false
		}
	}
	data := make([]u8, size + 4)
	for i in 0 ..< 4 {
		data[i] = u8(u32(size) >> uint(8 * i))
	}
	offset := 4
	for arg in args {
		copy(data[offset:], transmute([]u8)arg)
		offset += len(arg) + 1
	}
	return data, true
}

decode_message :: proc(data: []u8) -> (args: [dynamic]string, ok: bool) {
	if len(data) < 6 || len(data) > MAX_MESSAGE + 4 {
		return
	}
	size := u32(data[0]) | u32(data[1]) << 8 | u32(data[2]) << 16 | u32(data[3]) << 24
	if int(size) != len(data) - 4 || data[len(data) - 1] != 0 || data[len(data) - 2] != 0 {
		return
	}
	begin := 4
	for i in 4 ..< len(data) - 1 {
		if data[i] == 0 {
			append(&args, string(data[begin:i]))
			begin = i + 1
		}
	}
	if len(args) == 0 || len(args[0]) == 0 {
		delete(args)
		return nil, false
	}
	return args, true
}
