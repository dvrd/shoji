package tests

import loader "../src/addition/loader"
import wire "../src/addition/windowserver/protocol"
import target "../src/addition/windowserver/target"
import "core:os"
import "core:sys/posix"
import "core:testing"

@(test)
windowserver_target_requires_the_exact_system_executable :: proc(
	t: ^testing.T,
) {
	testing.expect(t, target.valid_path(target.PATH))
	testing.expect(t, target.valid_path(target.CANONICAL_PATH))
	testing.expect(t, !target.valid_path(target.CANONICAL_PATH + ".copy"))
	testing.expect(t, !target.valid_path("/usr/local/bin/WindowServer"))
	testing.expect(t, !target.valid_path(target.PATH + ".copy"))
	testing.expect_value(t, target.validate(123, target.PATH), "")
	testing.expect_value(
		t,
		target.validate(0, target.PATH),
		"WindowServer injection requires a positive process ID",
	)
	testing.expect_value(
		t,
		target.validate(123, "/tmp/WindowServer"),
		"target process is not the system WindowServer",
	)
	// Reject this test process before task-port acquisition or helper delegation.
	executable, path_error := os.get_executable_path(context.temp_allocator)
	testing.expect_value(t, path_error, nil)
	testing.expect_value(
		t,
		loader.inject_windowserver(executable, i32(posix.getpid())),
		"target process is not the system WindowServer",
	)
}

@(test)
windowserver_protocol_has_an_independent_versioned_handshake :: proc(
	t: ^testing.T,
) {
	expected := wire.Capabilities{.Load_Probe}
	p: wire.Packet
	wire.encode_handshake(&p, expected)
	caps, ok := wire.decode_handshake(p.data[:p.count])
	testing.expect(t, ok)
	testing.expect_value(t, caps, expected)

	p.data[0] = 'X'
	_, ok = wire.decode_handshake(p.data[:p.count])
	testing.expect(t, !ok)
	wire.encode_handshake(&p, expected)
	_, ok = wire.decode_handshake(p.data[:p.count - 1])
	testing.expect(t, !ok)
}

@(test)
windowserver_protocol_rejects_unknown_and_trailing_requests :: proc(
	t: ^testing.T,
) {
	p := wire.begin(.Handshake)
	data := wire.finish(&p)
	testing.expect_value(t, len(data), 3)
	testing.expect_value(t, data[0], u8(1))
	testing.expect_value(t, data[1], u8(0))
	testing.expect(t, wire.validate(.Handshake, data[3:]))
	testing.expect(t, !wire.validate(.Handshake, []u8{0}))
	testing.expect(t, !wire.validate(wire.Opcode(255), nil))
}
