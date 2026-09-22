package macos

import wire "../addition/protocol"
import e "../engine"
import "core:fmt"

addition_connect :: proc() -> i32 {return connect_socket(
		fmt.tprintf("/tmp/shoji-sa_%d.socket", getuid()),
	)}
addition_exchange :: proc(
	packet: ^wire.Packet,
	handshake: bool = false,
) -> (
	wire.Capabilities,
	string,
) {
	fd := addition_connect()
	if fd <
	   0 { return {}, "Dock scripting addition is not loaded; use --load-sa" }; defer close(fd)
	uid, gid: u32
	if getpeereid(fd, &uid, &gid) != 0 ||
	   uid != getuid() { return {}, "unexpected scripting-addition socket owner" }
	if !write_all(
		fd,
		wire.finish(packet),
	) { return {}, "could not send scripting-addition request" }
	status: [1]u8
	if !read_exact(fd, status[:]) { return {}, "scripting addition did not acknowledge request" }
	if status[0] !=
	   u8(
		   wire.Status.OK,
	   ) { return {}, fmt.tprintf("scripting addition returned %v", wire.Status(status[0])) }
	if handshake {
		data: [len(wire.VERSION) + 5]u8
		if !read_exact(fd, data[:]) { return {}, "incomplete scripting-addition handshake" }
		caps, ok := wire.handshake(
			data[:],
		); if !ok { return {}, "incompatible scripting-addition protocol" }; return caps, ""
	}
	return {}, ""
}
addition_check :: proc() -> (wire.Capabilities, string) {packet := wire.begin(.Handshake)
	return addition_exchange(&packet, true)}
addition_action :: proc(action: e.Action) -> string {
	_, err := addition_check(); if err != "" { return err }
	packet: wire.Packet
	#partial switch action.kind {
	case .Order:
		packet = wire.begin(.Window_Order); wire.pack(&packet, action.window)
		wire.pack(&packet, i32(action.value))
		wire.pack(&packet, action.relative)
	case .Scale:
		packet = wire.begin(.Window_Scale); wire.pack(&packet, action.window)
		wire.pack(
			&packet,
			f32(action.frame.x),
		); wire.pack(&packet, f32(action.frame.y)); wire.pack(&packet, f32(action.frame.w)); wire.pack(&packet, f32(action.frame.h))
	case .Focus_Without_Raise:
		packet = wire.begin(.Window_Focus); wire.pack(&packet, action.window)
	case .Space_Focus, .Space_Create, .Space_Destroy:
		op := wire.Opcode.Space_Focus
		if action.kind ==
		   .Space_Create { op = .Space_Create }; if action.kind == .Space_Destroy { op = .Space_Destroy }
		packet = wire.begin(op); wire.pack(&packet, action.space)
	case .Space_Move:
		packet = wire.begin(.Space_Move); wire.pack(&packet, action.space)
		wire.pack(&packet, action.destination)
		wire.pack(&packet, u64(0))
		wire.pack(&packet, false)
	case .Space:
		packet = wire.begin(.Window_To_Space); wire.pack(&packet, action.space)
		wire.pack(&packet, action.window)
	case .Opacity:
		packet = wire.begin(.Window_Opacity); wire.pack(&packet, action.window)
		wire.pack(&packet, f32(action.value))
	case .Layer:
		level: i32 = 4; if action.value < 0 { level = 1 }; if action.value > 0 { level = 6 }
		packet = wire.begin(
			.Window_Layer,
		); wire.pack(&packet, action.window); wire.pack(&packet, level)
	case .Sticky, .Shadow:
		packet = wire.begin(
			action.kind == .Sticky ? wire.Opcode.Window_Sticky : wire.Opcode.Window_Shadow,
		)
		wire.pack(&packet, action.window)
		wire.pack(&packet, action.flag)
	case:
		return "unsupported scripting-addition action"
	}
	_, err = addition_exchange(&packet); return err
}
