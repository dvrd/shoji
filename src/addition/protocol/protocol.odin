package protocol

import "core:strings"
VERSION :: "shoji-sa-1"
MAX_PACKET :: 4096
Opcode :: enum u8 {
	Handshake = 1,
	Space_Focus,
	Space_Create,
	Space_Destroy,
	Space_Move,
	Window_Move,
	Window_Opacity,
	Window_Opacity_Fade,
	Window_Layer,
	Window_Sticky,
	Window_Shadow,
	Window_Focus,
	Window_Scale,
	Proxy_In,
	Proxy_Out,
	Window_Order,
	Window_Order_In,
	Window_List_To_Space,
	Window_To_Space,
}
Capability :: enum u32 {
	Dock_Spaces,
	Desktop_Pictures,
	Add_Space,
	Remove_Space,
	Move_Space,
	Focus_Window,
	Animation_Patch,
}
Capabilities :: bit_set[Capability;u32]
Status :: enum u8 {
	OK,
	Invalid_Message,
	Unsupported,
	Operation_Failed,
	Version_Mismatch,
}
Packet :: struct {
	data:  [MAX_PACKET]u8,
	count: int,
	valid: bool,
}
Reader :: struct {
	data:   []u8,
	offset: int,
	valid:  bool,
}
begin :: proc(op: Opcode) -> Packet {p := Packet {
		count = 3,
		valid = true,
	};p.data[2] = u8(op);return p}
pack :: proc(p: ^Packet, value: $T) {
	if !p.valid || p.count + size_of(T) > MAX_PACKET {p.valid = false;return}
	value := value
	copy(p.data[p.count:], (([^]u8)(&value))[:size_of(T)])
	p.count += size_of(T)
}
finish :: proc(p: ^Packet) -> []u8 {
	if !p.valid {return nil}
	n := p.count - 2;p.data[0] = u8(n);p.data[1] = u8(n >> 8)
	return p.data[:p.count]
}
reader :: proc(bytes: []u8) -> Reader {return {data = bytes, valid = true}}
unpack :: proc(r: ^Reader, $T: typeid) -> (value: T) {
	if !r.valid || r.offset + size_of(T) > len(r.data) {r.valid = false;return}
	copy(((^[size_of(T)]u8)(&value))[:], r.data[r.offset:r.offset + size_of(T)])
	r.offset += size_of(T);return
}
complete :: proc(r: Reader) -> bool {return r.valid && r.offset == len(r.data)}
expected_size :: proc(op: Opcode) -> int {
	switch op {
	case .Handshake:
		return 0
	case .Space_Focus, .Space_Create, .Space_Destroy:
		return 8
	case .Space_Move:
		return 25
	case .Window_Move, .Window_Opacity_Fade, .Window_To_Space, .Window_Order:
		return 12
	case .Window_Opacity, .Window_Layer:
		return 8
	case .Window_Sticky, .Window_Shadow:
		return 5
	case .Window_Focus:
		return 4
	case .Window_Scale:
		return 20
	case .Proxy_In, .Proxy_Out, .Window_Order_In, .Window_List_To_Space:
		return -1
	}
	return -2
}
validate :: proc(op: Opcode, data: []u8) -> bool {
	if u8(op) < 1 || u8(op) > 19 {return false}
	expected := expected_size(op)
	if expected >= 0 {return len(data) == expected}
	r := reader(data)
	if op == .Window_List_To_Space {unpack(&r, u64)}
	count := unpack(&r, i32)
	if !r.valid || count < 0 || count > MAX_PACKET / 4 {return false}
	for _ in 0 ..< count {
		id := unpack(&r, u32)
		if (op == .Proxy_In || op == .Proxy_Out) && id != 0 {unpack(&r, u32)}
	}
	return complete(r)
}
handshake :: proc(data: []u8) -> (caps: Capabilities, ok: bool) {
	at := strings.index_byte(string(data), 0)
	if at < 0 || string(data[:at]) != VERSION || len(data) != at + 5 {return}
	r := reader(data[at + 1:]);caps = unpack(&r, Capabilities);ok = complete(r);return
}
