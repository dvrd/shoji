package dockscan

import "base:runtime"
import "core:fmt"
import "core:os"

foreign import raven "../../bin/libshoji-raven.a"
foreign raven {
	lzraven_decode_buffer_ex :: proc(dst: [^]u8, capacity: uint, src: [^]u8, size: uint, status: ^i32) -> uint ---
	lzraven_status_string :: proc(status: i32) -> cstring ---
}

PBZM_BLOCK_LIMIT :: 64 * 1024 * 1024
pbzm_be64 :: proc(bytes: []u8) -> u64 {
	v: u64
	for b in bytes { v = (v << 8) | u64(b) }
	return v
}
pbzm_read :: proc(file: ^os.File, bytes: []u8) -> bool {
	offset := 0
	for offset < len(bytes) {
		n, error := os.read(file, bytes[offset:])
		if error != nil || n == 0 {
			return false
		}
		offset += n
	}
	return true
}

// pbzm is a sequence of independently compressed chunks. Keep only one encoded
// and one decoded chunk in memory; never allocate from the whole archive's size.
decode_pbzm :: proc(
	source, destination: string,
	progress: ^Progress = nil,
) -> string {
	file, error := os.open(source)
	if error != nil {
		return fmt.tprintf("cannot open pbzm: %v", error)
	}
	defer os.close(file)
	info, stat_error := os.stat(source, context.allocator)
	if stat_error != nil || info.size < 12 {
		return "truncated pbzm header"
	}
	header: [12]u8
	if !pbzm_read(file, header[:]) || string(header[:4]) != "pbzm" {
		return "invalid pbzm header"
	}
	nominal := pbzm_be64(header[4:])
	if nominal == 0 || nominal > PBZM_BLOCK_LIMIT {
		return "pbzm block size exceeds the 64 MiB limit"
	}
	output, create_error := os.open(
		destination,
		{.Write, .Create, .Excl},
		os.perm(0o600),
	)
	if create_error != nil {
		return fmt.tprintf("cannot create decoded archive: %v", create_error)
	}
	success := false
	defer {
		_ = os.close(output)
		if !success {
			_ = os.remove(destination)
		}
	}
	allocator := runtime.heap_allocator()
	encoded := make([]u8, int(nominal), allocator)
	decoded := make([]u8, int(nominal), allocator)
	defer delete(encoded, allocator)
	defer delete(decoded, allocator)
	offset := i64(12)
	block := 0
	defer progress_clear(progress)
	for offset < info.size {
		chunk: [16]u8
		if info.size - offset < 16 || !pbzm_read(file, chunk[:]) {
			return "truncated pbzm chunk header"
		}
		offset += 16
		uncompressed := pbzm_be64(chunk[:8])
		compressed := pbzm_be64(chunk[8:])
		if uncompressed == 0 ||
		   uncompressed > nominal ||
		   compressed == 0 ||
		   compressed > nominal {
			return "invalid pbzm chunk size"
		}
		if compressed > u64(info.size - offset) {
			return "pbzm chunk extends past end of file"
		}
		bytes := encoded[:int(compressed)]
		if !pbzm_read(file, bytes) {
			return "truncated pbzm chunk"
		}
		offset += i64(compressed)
		if compressed != uncompressed {
			status: i32
			n := lzraven_decode_buffer_ex(
				raw_data(decoded),
				uint(uncompressed),
				raw_data(bytes),
				uint(compressed),
				&status,
			)
			if status != 0 || n != uint(uncompressed) {
				return fmt.tprintf(
					"pbzm/LZRAVEN block %d failed: %s (decoded %d, expected %d)",
					block,
					lzraven_status_string(status),
					n,
					uncompressed,
				)
			}
			bytes = decoded[:int(uncompressed)]
		}
		written := 0
		for written < len(bytes) {
			n, write_error := os.write(output, bytes[written:])
			if write_error != nil || n == 0 {
				return fmt.tprintf(
					"cannot write decoded archive: %v",
					write_error,
				)
			}
			written += n
		}
		block += 1
		progress_stage(
			progress,
			"Decoding MobileAsset payload",
			fmt.tprintf("block %d", block),
		)
		progress_draw(progress)
	}
	if block == 0 {
		return "pbzm container has no chunks"
	}
	success = true
	return ""
}
