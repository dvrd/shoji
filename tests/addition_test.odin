package tests

import b "../src/addition/bridge"
import loader "../src/addition/loader"
import p "../src/addition/patterns"
import wire "../src/addition/protocol"
import "core:testing"

@(test)
dock_focus_is_blocked_on_the_crashing_host_version :: proc(t: ^testing.T) {
	when ODIN_ARCH == .arm64 {
		testing.expect(t, p.focus_target_blocked({15, 6, 0}))
		testing.expect(t, !p.focus_target_blocked({15, 5, 0}))
	} else {
		testing.expect(t, !p.focus_target_blocked({15, 6, 0}))
	}
}

@(test)
proxy_diagnostics_preserve_the_first_native_failure :: proc(t: ^testing.T) {
	failure: wire.Native_Failure
	wire.note_native_failure(&failure, .Proxy_Order, 0)
	testing.expect_value(t, failure.stage, wire.Native_Stage.None)
	wire.note_native_failure(&failure, .System_Alpha, 1000)
	wire.note_native_failure(&failure, .Transaction_Commit, 1001)
	testing.expect_value(t, failure.stage, wire.Native_Stage.System_Alpha)
	testing.expect_value(t, failure.code, i32(1000))
	wire.note_native_failure(nil, .Proxy_Order, 1002)
	packet := wire.Packet{valid = true}
	wire.pack(&packet, wire.Status.Native_Error)
	wire.pack(&packet, failure.stage)
	wire.pack(&packet, failure.code)
	testing.expect_value(t, packet.count, 6)
	r := wire.reader(packet.data[:packet.count])
	testing.expect_value(t, wire.unpack(&r, wire.Status), wire.Status.Native_Error)
	testing.expect_value(t, wire.unpack(&r, wire.Native_Stage), wire.Native_Stage.System_Alpha)
	testing.expect_value(t, wire.unpack(&r, i32), i32(1000))
	testing.expect(t, wire.complete(r))
}

@(test)
addition_protocol_rejects_truncation_and_trailing_bytes :: proc(t: ^testing.T) {
	for code in 1 ..= 20 {
		op := wire.Opcode(code);n := wire.expected_size(op)
		if n < 0 {continue}
		data: [32]u8
		testing.expect(t, wire.validate(op, data[:n]))
		if n > 0 {testing.expect(t, !wire.validate(op, data[:n - 1]))}
		testing.expect(t, !wire.validate(op, data[:n + 1]))
	}
	testing.expect(t, !wire.validate(wire.Opcode(255), nil))
	packet := wire.begin(.Window_List_To_Space)
	wire.pack(&packet, u64(123));wire.pack(&packet, i32(2));wire.pack(&packet, u32(7))
	testing.expect(t, !wire.validate(.Window_List_To_Space, wire.finish(&packet)[3:]))
	wire.pack(&packet, u32(9))
	testing.expect(t, wire.validate(.Window_List_To_Space, wire.finish(&packet)[3:]))
	r := wire.reader(
		packet.data[3:packet.count],
	);testing.expect_value(t, wire.unpack(&r, u64), u64(123))
	testing.expect_value(t, wire.unpack(&r, i32), i32(2))
	for _ in 0 ..< wire.MAX_PACKET {wire.pack(&packet, u64(0))}
	testing.expect(t, wire.finish(&packet) == nil)
}
@(test)
addition_handshake_checks_version :: proc(t: ^testing.T) {
	packet := wire.Packet {
		valid = true,
	}
	version := string(wire.VERSION)
	for byte in transmute([]u8)version {wire.pack(&packet, byte)}
	wire.pack(&packet, u8(0));wire.pack(&packet, wire.Capabilities{.Dock_Spaces, .Add_Space})
	caps, ok := wire.handshake(
		packet.data[:packet.count],
	);testing.expect(t, ok && .Add_Space in caps)
	packet.data[0] = 'X';_, ok = wire.handshake(packet.data[:packet.count]);testing.expect(t, !ok)
}
@(test)
addition_pattern_bounds_and_wildcards :: proc(t: ^testing.T) {
	pattern, ok := p.compile("AA ?? ?8 CC");testing.expect(t, ok);defer p.destroy(pattern)
	bytes := []u8{0, 0xaa, 0xff, 0x12, 0xcc}
	at, found := p.find(bytes, pattern);testing.expect(t, found && at == 1)
	_, found = p.find(bytes[:3], pattern);testing.expect(t, !found)
	for malformed in ([]string {
			"",
			"A",
			"GG",
			"AAA",
		}) {_, ok = p.compile(malformed);testing.expect(t, !ok)}
	address, valid := p.decode_adrp_add(0x90000000, 0x91008000, 0x1234)
	testing.expect(t, valid && address == 0x1020)
	address, valid = p.decode_adrp_add(0xf0ffffe0, 0x91000000, 0x5000)
	testing.expect(t, valid && address == 0x4000)
	_, valid = p.decode_adrp_add(0, 0, 0);testing.expect(t, !valid)
	testing.expect(t, !p.supported({major = 99}))
}
bridge_callee :: proc "c" (object: rawptr) {
	owner := (^uintptr)(read_owner());owner^ = uintptr(object)
}
bridge_move_callee :: proc "c" (source, destination, uuid: rawptr) {
	owner := (^[3]uintptr)(
		read_owner(),
	);owner[0] = uintptr(source);owner[1] = uintptr(destination);owner[2] = uintptr(uuid)
}
@(test)
addition_native_swift_context_bridge :: proc(t: ^testing.T) {
	when ODIN_ARCH == .arm64 {
		entry := u64(0x100000000)
		testing.expect_value(t, b.strip_function(b.sign_function(entry)), entry)
	}
	value: uintptr
	b.call_add(rawptr(uintptr(123)), &value, rawptr(bridge_callee))
	testing.expect_value(t, value, uintptr(123))
	values: [3]uintptr
	b.call_move(
		rawptr(uintptr(1)),
		rawptr(uintptr(2)),
		rawptr(uintptr(3)),
		&values,
		rawptr(bridge_move_callee),
	)
	testing.expect_value(t, values, [3]uintptr{1, 2, 3})
}
bootstrap_fake_open :: proc "c" (path: cstring, mode: i32) -> rawptr {return rawptr(
		uintptr(mode + 40),
	)}
bootstrap_fake_self :: proc "c" () -> uint {return 123}
bootstrap_fake_detach :: proc "c" (thread: uint) -> i32 {
	return thread == 123 ? 0 : -1
}
@(test)
addition_bootstrap_worker_uses_explicit_abi :: proc(t: ^testing.T) {
	data := loader.Bootstrap {
		open          = bootstrap_fake_open,
		self          = bootstrap_fake_self,
		detach        = bootstrap_fake_detach,
		detach_result = -1,
	}
	loader.remote_worker(&data)
	testing.expect_value(t, data.detach_result, i32(0))
	testing.expect_value(t, data.done, u32(1))
	testing.expect_value(t, data.worker_finished, u32(1))
	testing.expect_value(t, uintptr(data.handle), uintptr(42))
	size: uint
	section := loader.getsectiondata(
		loader._dyld_get_image_header(0),
		"__TEXT",
		"__shoji_boot",
		&size,
	)
	testing.expect(t, section != nil && size > 0)
	for address in ([]uintptr {
			uintptr(rawptr(loader.remote_worker)),
			uintptr(rawptr(loader.remote_entry)),
		}) {
		testing.expect(
			t,
			address >= uintptr(section) && address < uintptr(section) + uintptr(size),
		)
	}
}

@(test)
addition_bootstrap_worker_executes_after_relocation :: proc(t: ^testing.T) {
	library := loader.dlopen("/usr/lib/system/libsystem_kernel.dylib", 2)
	if !testing.expect(t, library != nil) {return};defer loader.dlclose(library)
	allocate := cast(proc "c" (_: u32, _: ^u64, _: u64, _: i32) -> i32)loader.dlsym(
		library,
		"mach_vm_allocate",
	)
	deallocate := cast(proc "c" (_: u32, _: u64, _: u64) -> i32)loader.dlsym(
		library,
		"mach_vm_deallocate",
	)
	size: uint
	section := loader.getsectiondata(
		loader._dyld_get_image_header(0),
		"__TEXT",
		"__shoji_boot",
		&size,
	)
	if !testing.expect(t, section != nil && size > 0) {return}
	self := loader.mach_task_self();address: u64;stack: u64
	if !testing.expect_value(t, allocate(self, &address, u64(size), 1), i32(0)) {return}
	defer deallocate(self, address, u64(size))
	if !testing.expect_value(t, allocate(self, &stack, 16 * 1024, 1), i32(0)) {return}
	defer deallocate(self, stack, 16 * 1024)
	if !testing.expect_value(
		t,
		loader.mach_vm_protect(self, stack, 16 * 1024, 1, 1 | 2),
		i32(0),
	) {return}
	if !testing.expect_value(
		t,
		loader.mach_vm_write(self, address, uintptr(section), u32(size)),
		i32(0),
	) {return}
	if !testing.expect_value(
		t,
		loader.mach_vm_protect(self, address, u64(size), 0, 1 | 4),
		i32(0),
	) {return}
	offset := uintptr(rawptr(loader.remote_worker)) - uintptr(section)
	worker := cast(proc "c" (_: rawptr) -> rawptr)rawptr(uintptr(address) + offset)
	data := loader.Bootstrap {
		open = bootstrap_fake_open,
	}
	worker(&data)
	testing.expect_value(t, uintptr(data.handle), uintptr(42))
}

// The full in-process injector path against this test process: remote thread
// creation, arm64 thread-state signing and conversion, pthread bootstrap, and a
// real dlopen of an existing system library. No desktop process is contacted.
@(test)
addition_injector_self_test :: proc(t: ^testing.T) {
	testing.expect_value(t, loader.self_test(), "")
}

@(test)
addition_upstream_pattern_tables_compile :: proc(t: ^testing.T) {
	providers := []proc(_: p.Version) -> string {
		p.get_dock_spaces_pattern,
		p.get_dppm_pattern,
		p.get_add_space_pattern,
		p.get_remove_space_pattern,
		p.get_move_space_pattern,
		p.get_set_front_window_pattern,
		p.get_fix_animation_pattern,
	}
	for major in ([]int{11, 12, 13, 14, 15, 26}) {
		for minor in 0 ..< 10 {
			version := p.Version {
				major = major,
				minor = minor,
				patch = 0,
			}
			if !p.supported(version) {continue}
			for provider in providers {
				text := provider(version);if text == "" {continue}
				pattern, ok := p.compile(text)
				if testing.expect(
					t,
					ok,
				) {_, found := p.find(pattern.bytes, pattern);testing.expect(t, found);p.destroy(pattern)}
			}
		}
	}
}
