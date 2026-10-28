package wsprotocol

import "core:strings"

VERSION :: "shoji-ws-1"
MAX_PACKET :: 64

Opcode :: enum u8 {
	Handshake = 1,
}

Capability :: enum u32 {
	Load_Probe,
	Ordering_Observer,
	Presentation_Hold,
}
Capabilities :: bit_set[Capability;u32]

Status :: enum u8 {
	OK,
	Invalid_Message,
	Unsupported,
}

Packet :: struct {
	data: [MAX_PACKET]u8,
	count: int,
	valid: bool,
}

Reader :: struct {
	data: []u8,
	offset: int,
	valid: bool,
}

begin :: proc(op: Opcode) -> Packet {
	p := Packet {
		count = 3,
		valid = true,
	}
	p.data[2] = u8(op)
	return p
}

pack :: proc(p: ^Packet, value: $T) {
	if !p.valid || p.count + size_of(T) > MAX_PACKET {
		p.valid = false
		return
	}
	value := value
	copy(p.data[p.count:], (([^]u8)(&value))[:size_of(T)])
	p.count += size_of(T)
}

finish :: proc(p: ^Packet) -> []u8 {
	if !p.valid {
		return nil
	}
	n := p.count - 2
	p.data[0] = u8(n)
	p.data[1] = u8(n >> 8)
	return p.data[:p.count]
}

reader :: proc(bytes: []u8) -> Reader {
	return {data = bytes, valid = true}
}

unpack :: proc(r: ^Reader, $T: typeid) -> (value: T) {
	if !r.valid || r.offset + size_of(T) > len(r.data) {
		r.valid = false
		return
	}
	copy(
		((^[size_of(T)]u8)(&value))[:],
		r.data[r.offset:r.offset + size_of(T)],
	)
	r.offset += size_of(T)
	return
}

complete :: proc(r: Reader) -> bool {
	return r.valid && r.offset == len(r.data)
}

validate :: proc(op: Opcode, data: []u8) -> bool {
	return op == .Handshake && len(data) == 0
}

encode_handshake :: proc(p: ^Packet, caps: Capabilities) {
	p^ = Packet {
		valid = true,
	}
	for byte in transmute([]u8)string(VERSION) { pack(p, byte) }
	pack(p, u8(0))
	pack(p, caps)
}

decode_handshake :: proc(data: []u8) -> (caps: Capabilities, ok: bool) {
	at := strings.index_byte(string(data), 0)
	if at < 0 || string(data[:at]) != VERSION || len(data) != at + 5 {
		return
	}
	r := reader(data[at + 1:])
	caps = unpack(&r, Capabilities)
	ok = complete(r)
	return
}
