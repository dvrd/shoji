package dockscan

import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

pbzm_bytes :: proc(s: string) -> []u8 { return transmute([]u8)s }

pbzm_append64 :: proc(bytes: ^[dynamic]u8, value: u64) {
	for shift := 56;
	    shift >= 0;
	    shift -= 8 { append(bytes, u8(value >> uint(shift))) }
}
pbzm_fixture :: proc(
	payload: []u8,
	decoded_size: u64,
	nominal: u64 = 8192,
) -> []u8 {
	bytes := make([dynamic]u8)
	append(&bytes, ..pbzm_bytes("pbzm"))
	pbzm_append64(&bytes, nominal)
	pbzm_append64(&bytes, decoded_size)
	pbzm_append64(&bytes, u64(len(payload)))
	append(&bytes, ..payload)
	return bytes[:]
}

@(test)
pbzm_decodes_upstream_raven_and_stored_chunks :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	dir, e := os.make_directory_temp(
		"",
		"shoji-pbzm-test-*",
		context.allocator,
	)
	if !testing.expect_value(t, e, nil) {
		return
	}
	defer os.remove_all(dir)
	encoded := transmute([]u8)#load(
		"../../tools/shoji-dock/vendor/liblzraven/tests/vectors/zeros_4k.rav",
	)
	bytes := make([dynamic]u8)
	append(&bytes, ..pbzm_fixture(encoded, 4096))
	pbzm_append64(&bytes, 3); pbzm_append64(&bytes, 3)
	append(&bytes, ..pbzm_bytes("end"))
	source := join(dir, "payload")
	output := join(dir, "decoded")
	testing.expect_value(t, os.write_entire_file(source, bytes[:]), nil)
	testing.expect_value(t, decode_pbzm(source, output), "")
	actual, read_error := os.read_entire_file(output, context.allocator)
	testing.expect_value(t, read_error, nil)
	if testing.expect_value(t, len(actual), 4099) {
		for b in actual[:4096] { testing.expect_value(t, b, u8(0)) }
		testing.expect_value(t, string(actual[4096:]), "end")
	}
	// Existing output is never overwritten.
	testing.expect(
		t,
		strings.contains(decode_pbzm(source, output), "cannot create"),
	)
}

@(test)
pbzm_rejects_truncation_sizes_and_corrupt_codec :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	dir, e := os.make_directory_temp(
		"",
		"shoji-pbzm-reject-*",
		context.allocator,
	)
	if !testing.expect_value(t, e, nil) {
		return
	}
	defer os.remove_all(dir)
	source := join(dir, "payload")
	output := join(dir, "decoded")
	valid := pbzm_fixture(pbzm_bytes("stored"), 6)
	for size in 0 ..< len(valid) {
		testing.expect_value(
			t,
			os.write_entire_file(source, valid[:size]),
			nil,
		)
		testing.expect(t, decode_pbzm(source, output) != "")
		testing.expect(t, !os.exists(output))
	}
	for bad in ([]([]u8) {
			pbzm_fixture(pbzm_bytes("bad"), 4096),
			pbzm_fixture(pbzm_bytes("x"), 1, PBZM_BLOCK_LIMIT + 1),
			pbzm_fixture(pbzm_bytes("x"), 0),
			pbzm_fixture(pbzm_bytes("x"), 9000),
		}) {
		testing.expect_value(t, os.write_entire_file(source, bad), nil)
		testing.expect(t, decode_pbzm(source, output) != "")
		testing.expect(t, !os.exists(output))
	}
}
