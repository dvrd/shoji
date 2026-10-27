package macos

import wire "../addition/protocol"
import e "../engine"
import "core:fmt"

addition_connect :: proc() -> i32 {
	return connect_socket(fmt.tprintf("/tmp/shoji-sa_%d.socket", getuid()))
}

addition_exchange :: proc(
	packet: ^wire.Packet,
	handshake: bool = false,
	created_space: ^u64 = nil,
) -> (
	wire.Capabilities,
	string,
) {
	fd := addition_connect()
	if fd < 0 {
		return {}, "Dock scripting addition is not loaded; use --load-sa"
	}; defer close(fd)

	uid, gid: u32
	if getpeereid(fd, &uid, &gid) != 0 || uid != getuid() {
		return {}, "unexpected scripting-addition socket owner"
	}

	if !write_all(fd, wire.finish(packet)) {
		return {}, "could not send scripting-addition request"
	}

	status: [1]u8
	if !read_exact(fd, status[:]) {
		return {}, "scripting addition did not acknowledge request"
	}

	if status[0] == u8(wire.Status.Native_Error) {
		data: [5]u8
		if !read_exact(fd, data[:]) {
			return {}, "incomplete scripting-addition native error"
		}
		r := wire.reader(data[:])
		stage := wire.unpack(&r, wire.Native_Stage)
		code := wire.unpack(&r, i32)
		return {}, fmt.tprintf(
			"scripting addition failed at %v (native error %d)",
			stage,
			code,
		)
	}

	if status[0] != u8(wire.Status.OK) {
		return {}, fmt.tprintf(
			"scripting addition returned %v",
			wire.Status(status[0]),
		)
	}

	if handshake {
		data: [len(wire.VERSION) + 5]u8
		if !read_exact(fd, data[:]) {
			return {}, "incomplete scripting-addition handshake"
		}

		caps, ok := wire.handshake(data[:]); if !ok {
			return {}, "incompatible scripting-addition protocol"
		}

		return caps, ""
	}

	if created_space != nil {
		data: [8]u8
		if !read_exact(fd, data[:]) {
			return {}, "incomplete tracked Space creation response"
		}

		r := wire.reader(data[:]); created_space^ = wire.unpack(&r, u64)
		if created_space^ == 0 {
			return {}, "payload did not identify its created Space"
		}
	}

	return {}, ""
}

addition_create_tracked_space :: proc(anchor: u64) -> (u64, string) {
	caps, err := addition_check()
	if err != "" {
		return 0, err
	}

	if .Tracked_Space_Create not_in caps {
		return 0,
			"loaded payload lacks tracked Space creation; load the rebuilt payload into a fresh Dock"
	}

	packet := wire.begin(.Space_Create_Tracked)
	wire.pack(&packet, anchor)

	id: u64
	_, err = addition_exchange(&packet, created_space = &id)
	return id, err
}

addition_check :: proc() -> (wire.Capabilities, string) {
	packet := wire.begin(.Handshake)
	return addition_exchange(&packet, true)
}

addition_action :: proc(action: e.Action) -> string {
	caps, err := addition_check(); if err != "" {
		return err
	}

	packet: wire.Packet

	#partial switch action.kind {
	case .Order:
		packet = wire.begin(.Window_Order); wire.pack(&packet, action.window)
		wire.pack(&packet, i32(action.value))
		wire.pack(&packet, action.relative)
	case .Scale:
		packet = wire.begin(.Window_Scale); wire.pack(&packet, action.window)
		wire.pack(&packet, f32(action.frame.x))
		wire.pack(&packet, f32(action.frame.y))
		wire.pack(&packet, f32(action.frame.w))
		wire.pack(&packet, f32(action.frame.h))
	case .Focus_Without_Raise:
		packet = wire.begin(.Window_Focus)
		wire.pack(&packet, action.window)
	case .Space_Focus, .Space_Create, .Space_Destroy:
		op := wire.Opcode.Space_Focus

		if action.kind == .Space_Create {
			op = .Space_Create
		}

		if action.kind == .Space_Destroy {
			op = .Space_Destroy
		}
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
		packet = wire.begin(
			action.duration > 0 \
				? wire.Opcode.Window_Opacity_Fade \
				: wire.Opcode.Window_Opacity,
		)
		wire.pack(&packet, action.window)
		wire.pack(&packet, f32(action.value))
		if action.duration > 0 {
			wire.pack(&packet, f32(action.duration))
		}
	case .Layer:
		level := wire.window_layer_key(action.value, caps)
		packet = wire.begin(.Window_Layer); wire.pack(&packet, action.window)
		wire.pack(&packet, level)
	case .Sticky, .Shadow:
		packet = wire.begin(
			action.kind == .Sticky \
				? wire.Opcode.Window_Sticky \
				: wire.Opcode.Window_Shadow,
		)
		wire.pack(&packet, action.window)
		wire.pack(&packet, action.flag)
	case:
		return "unsupported scripting-addition action"
	}
	_, err = addition_exchange(&packet)

	return err
}
