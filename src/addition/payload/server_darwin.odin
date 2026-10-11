package payload

import m "../../macos"
import b "../bridge"
import wire "../protocol"
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import posix "core:sys/posix"

Request :: struct {
	op:     wire.Opcode,
	bytes:  []u8,
	result: wire.Status,
	tick:   bool,
	ctx:    runtime.Context,
}
main_request :: proc "c" (user: rawptr) {
	req := (^Request)(user);context = req.ctx
	pool := m.pool_push();defer m.pool_pop(pool)
	if req.tick {tick_fades();return}
	if !wire.validate(req.op, req.bytes) {req.result = .Invalid_Message;return}
	if req.op == .Handshake {req.result = .OK;return}
	r := wire.reader(req.bytes)
	if req.op >= .Space_Focus &&
	   req.op <=
		   .Space_Move {req.result = space_action(req.op, &r)} else {req.result = window_action(req.op, &r)}
}
initialize_payload :: proc "c" (unused: rawptr) {
	context = runtime.default_context()
	pool := m.pool_push();defer m.pool_pop(pool)
	discover();fades = make(map[u32]Fade)
}
listen_fd: i32 = -1
serve :: proc "c" (unused: rawptr) -> rawptr {
	context = runtime.default_context()
	dispatch_sync_f(dispatch_get_main_queue(), nil, sign_c(initialize_payload))
	for {
		scratch: mem.Dynamic_Arena;mem.dynamic_arena_init(&scratch)
		{
			context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
			ready := m.Poll_FD {
				fd     = listen_fd,
				events = 1,
			}
			if m.poll(&ready, 1, 8) > 0 && ready.revents & 1 != 0 {
				fd := m.accept(listen_fd, nil, nil)
				if fd >= 0 {serve_one(fd)}
			}
			req := Request {
				tick = true,
				ctx  = context,
			}
			dispatch_sync_f(dispatch_get_main_queue(), &req, sign_c(main_request))
		}
		mem.dynamic_arena_destroy(&scratch)
	}
}
serve_one :: proc(fd: i32) {
	defer m.close(fd);m.prepare_socket(fd)
	uid, gid: u32
	if m.getpeereid(fd, &uid, &gid) != 0 || uid != m.getuid() {return}
	header: [2]u8
	if !m.read_exact(fd, header[:]) {return}
	count := int(header[0]) | int(header[1]) << 8
	if count < 1 ||
	   count >
		   wire.MAX_PACKET -
			   2 {reply := [1]u8{u8(wire.Status.Invalid_Message)};m.write_all(fd, reply[:]);return}
	buffer: [wire.MAX_PACKET]u8
	if !m.read_exact(fd, buffer[:count]) {return}
	req := Request {
		op    = wire.Opcode(buffer[0]),
		bytes = buffer[1:count],
		ctx   = context,
	}
	dispatch_sync_f(dispatch_get_main_queue(), &req, sign_c(main_request))
	response := [1]u8{u8(req.result)}
	if !m.write_all(fd, response[:]) || req.result != .OK || req.op != .Handshake {return}
	p := wire.Packet {
		valid = true,
	}
	version := string(wire.VERSION)
	for byte in transmute([]u8)version {wire.pack(&p, byte)}
	wire.pack(&p, u8(0));wire.pack(&p, g.caps)
	m.write_all(fd, p.data[:p.count])
}
load_payload :: proc "c" () {
	context = runtime.default_context()
	pool := m.pool_push();defer m.pool_pop(pool)
	path := fmt.tprintf("/tmp/shoji-sa_%d.socket", m.getuid())
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	// A previous loaded copy must not lose its endpoint on repeated dlopen.
	existing := m.connect_socket(path)
	if existing >= 0 {m.close(existing);return}
	fd := m.socket(1, 1, 0);if fd < 0 {return}
	m.prepare_socket(fd);m.unlink(cpath)
	addr, ok := m.address(path)
	if !ok ||
	   m.bind(fd, &addr, size_of(addr)) != 0 ||
	   m.chmod(cpath, 0o600) != 0 ||
	   m.listen(fd, 64) != 0 {m.close(fd);return}
	listen_fd = fd
	thread: posix.pthread_t
	if posix.pthread_create(&thread, nil, sign_c(serve), nil) !=
	   nil {m.close(fd);m.unlink(cpath);return}
	posix.pthread_detach(thread)
}

@(export)
shoji_sa_start :: proc "c" () {load_payload()}

@(link_section = "__DATA,__mod_init_func", linkage = "strong", require)
shoji_sa_init: proc "c" () = shoji_sa_start

sign_c :: proc(p: $P) -> P {
	return transmute(P)uintptr(b.sign_function(u64(uintptr(transmute(rawptr)p))))
}
