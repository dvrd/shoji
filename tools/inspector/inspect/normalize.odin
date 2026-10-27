package inspector

import s "../../../src/support"
import tc "../../common"
import "core:fmt"
import "core:os"
normalize_bytes :: proc(bytes: []u8) -> string {
	if len(bytes) < 32 {
		return "truncated Mach-O header"
	}
	if tc.le32(bytes[:4]) != 0xfeedfacf || tc.le32(bytes[4:8]) != 0x0100000c {
		return "expected a thin arm64 Mach-O binary"
	}
	subtype := tc.le32(bytes[8:12])
	if subtype == 0x80000002 {
		return ""
	}
	if subtype != 0x81000002 {
		return fmt.tprintf(
			"expected arm64e ABI v1; found subtype 0x%08x",
			subtype,
		)
	}
	bytes[8], bytes[9], bytes[10], bytes[11] = 2, 0, 0, 0x80; return ""
}
normalize_arm64e :: proc(path: string) -> string {
	if !s.regular(path) {
		return "ABI input must be a regular, non-symlink file"
	}
	b, err := os.read_entire_file(path, context.allocator); if err != nil {
		return fmt.tprintf("cannot read binary: %v", err)
	}
	if e := normalize_bytes(b); e != "" {
		return e
	}
	if e := os.write_entire_file(path, b); e != nil {
		return fmt.tprintf("cannot normalize binary: %v", e)
	}
	return ""
}
