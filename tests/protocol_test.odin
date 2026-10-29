package tests

import e "../src"
import "core:testing"

@(test)
message_round_trip_preserves_empty_and_unicode_arguments :: proc(t: ^testing.T) {
	expected := []string{"rule", "--add", "title=日本語 title", "", "action=echo hello world"}
	data, ok := e.encode_message(expected)
	testing.expect(t, ok)
	defer delete(data)
	args, valid := e.decode_message(data)
	testing.expect(t, valid)
	defer delete(args)
	testing.expect_value(t, len(args), len(expected))
	for value, i in args {
		testing.expect_value(t, value, expected[i])
	}
	testing.expect_value(t, data[len(data) - 1], u8(0))
	testing.expect_value(t, data[len(data) - 2], u8(0))
}
@(test)
malformed_protocol_is_rejected :: proc(t: ^testing.T) {
	data, _ := e.encode_message([]string{"query", "--windows"})
	defer delete(data)
	for i in 0 ..< len(data) {
		args, ok := e.decode_message(data[:i])
		testing.expect(t, !ok)
		delete(args)
	}
	data[0] += 1
	args, ok := e.decode_message(data)
	testing.expect(t, !ok)
	delete(args)
	data[0] -= 1
	data[len(data) - 1] = 1
	args, ok = e.decode_message(data)
	testing.expect(t, !ok)
	delete(args)
	invalid, encoded := e.encode_message([]string{"x\x00y"})
	testing.expect(t, !encoded)
	delete(invalid)
	empty, encoded_empty := e.encode_message(nil)
	testing.expect(t, !encoded_empty)
	delete(empty)
}
