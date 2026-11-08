package tests

import dock "../src/dock"
import "core:testing"
import inject "../src/inject"

@(test)
dock_focus_is_blocked_on_the_crashing_host_version :: proc(t: ^testing.T) {
	when ODIN_ARCH == .arm64 {
		testing.expect(t, dock.focus_target_blocked({15, 6, 0}))
		testing.expect(t, !dock.focus_target_blocked({15, 5, 0}))
	} else {
		testing.expect(t, !dock.focus_target_blocked({15, 6, 0}))
	}
}

@(test)
proxy_diagnostics_preserve_the_first_native_failure :: proc(t: ^testing.T) {
	failure: dock.Native_Failure
	dock.note_native_failure(&failure, .Proxy_Order, 0)
	testing.expect_value(t, failure.stage, dock.Native_Stage.None)
	dock.note_native_failure(&failure, .System_Alpha, 1000)
	dock.note_native_failure(&failure, .Transaction_Commit, 1001)
	testing.expect_value(t, failure.stage, dock.Native_Stage.System_Alpha)
	testing.expect_value(t, failure.code, i32(1000))
	dock.note_native_failure(nil, .Proxy_Order, 1002)
	packet := dock.Packet{valid = true}
	dock.pack(&packet, dock.Status.Native_Error)
	dock.pack(&packet, failure.stage)
	dock.pack(&packet, failure.code)
	testing.expect_value(t, packet.count, 6)
	r := dock.reader(packet.data[:packet.count])
	testing.expect_value(t, dock.unpack(&r, dock.Status), dock.Status.Native_Error)
	testing.expect_value(t, dock.unpack(&r, dock.Native_Stage), dock.Native_Stage.System_Alpha)
	testing.expect_value(t, dock.unpack(&r, i32), i32(1000))
	testing.expect(t, dock.complete(r))
}

@(test)
addition_protocol_rejects_truncation_and_trailing_bytes :: proc(t: ^testing.T) {
	for code in 1 ..= int(dock.Opcode.Window_Conceal) {
		op := dock.Opcode(code);n := dock.expected_size(op)
		if n < 0 {continue}
		data: [32]u8
		testing.expect(t, dock.validate(op, data[:n]))
		if n > 0 {testing.expect(t, !dock.validate(op, data[:n - 1]))}
		testing.expect(t, !dock.validate(op, data[:n + 1]))
	}
	testing.expect(t, !dock.validate(dock.Opcode(255), nil))
	packet := dock.begin(.Window_List_To_Space)
	dock.pack(&packet, u64(123));dock.pack(&packet, i32(2));dock.pack(&packet, u32(7))
	testing.expect(t, !dock.validate(.Window_List_To_Space, dock.finish(&packet)[3:]))
	dock.pack(&packet, u32(9))
	testing.expect(t, dock.validate(.Window_List_To_Space, dock.finish(&packet)[3:]))
	r := dock.reader(
		packet.data[3:packet.count],
	);testing.expect_value(t, dock.unpack(&r, u64), u64(123))
	testing.expect_value(t, dock.unpack(&r, i32), i32(2))
	for _ in 0 ..< dock.MAX_PACKET {dock.pack(&packet, u64(0))}
	testing.expect(t, dock.finish(&packet) == nil)
}
@(test)
addition_handshake_checks_version :: proc(t: ^testing.T) {
	packet := dock.Packet {
		valid = true,
	}
	version := string(dock.VERSION)
	for byte in transmute([]u8)version {dock.pack(&packet, byte)}
	dock.pack(&packet, u8(0));dock.pack(&packet, dock.Capabilities{.Dock_Spaces, .Add_Space})
	caps, ok := dock.handshake(
		packet.data[:packet.count],
	);testing.expect(t, ok && .Add_Space in caps)
	packet.data[0] = 'X';_, ok = dock.handshake(packet.data[:packet.count]);testing.expect(t, !ok)
}
@(test)
addition_pattern_bounds_and_wildcards :: proc(t: ^testing.T) {
	pattern, ok := dock.compile("AA ?? ?8 CC");testing.expect(t, ok);defer dock.destroy(pattern)
	bytes := []u8{0, 0xaa, 0xff, 0x12, 0xcc}
	at, found := dock.find(bytes, pattern);testing.expect(t, found && at == 1)
	_, found = dock.find(bytes[:3], pattern);testing.expect(t, !found)
	for malformed in ([]string {
			"",
			"A",
			"GG",
			"AAA",
		}) {_, ok = dock.compile(malformed);testing.expect(t, !ok)}
	address, valid := dock.decode_adrp_add(0x90000000, 0x91008000, 0x1234)
	testing.expect(t, valid && address == 0x1020)
	address, valid = dock.decode_adrp_add(0xf0ffffe0, 0x91000000, 0x5000)
	testing.expect(t, valid && address == 0x4000)
	_, valid = dock.decode_adrp_add(0, 0, 0);testing.expect(t, !valid)
	testing.expect(t, !dock.supported({major = 99}))
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
		testing.expect_value(t, inject.strip_function(inject.sign_function(entry)), entry)
	}
	value: uintptr
	inject.call_add(rawptr(uintptr(123)), &value, rawptr(bridge_callee))
	testing.expect_value(t, value, uintptr(123))
	values: [3]uintptr
	inject.call_move(
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
	data := inject.Bootstrap {
		open          = bootstrap_fake_open,
		self          = bootstrap_fake_self,
		detach        = bootstrap_fake_detach,
		detach_result = -1,
	}
	inject.remote_worker(&data)
	testing.expect_value(t, data.detach_result, i32(0))
	testing.expect_value(t, data.done, u32(1))
	testing.expect_value(t, data.worker_finished, u32(1))
	testing.expect_value(t, uintptr(data.handle), uintptr(42))
	size: uint
	section := inject.getsectiondata(
		inject._dyld_get_image_header(0),
		"__TEXT",
		"__shoji_boot",
		&size,
	)
	testing.expect(t, section != nil && size > 0)
	for address in ([]uintptr {
			uintptr(rawptr(inject.remote_worker)),
			uintptr(rawptr(inject.remote_entry)),
		}) {
		testing.expect(
			t,
			address >= uintptr(section) && address < uintptr(section) + uintptr(size),
		)
	}
}

@(test)
addition_bootstrap_worker_executes_after_relocation :: proc(t: ^testing.T) {
	library := inject.dlopen("/usr/lib/system/libsystem_kernel.dylib", 2)
	if !testing.expect(t, library != nil) {return};defer inject.dlclose(library)
	allocate := cast(proc "c" (_: u32, _: ^u64, _: u64, _: i32) -> i32)inject.dlsym(
		library,
		"mach_vm_allocate",
	)
	deallocate := cast(proc "c" (_: u32, _: u64, _: u64) -> i32)inject.dlsym(
		library,
		"mach_vm_deallocate",
	)
	size: uint
	section := inject.getsectiondata(
		inject._dyld_get_image_header(0),
		"__TEXT",
		"__shoji_boot",
		&size,
	)
	if !testing.expect(t, section != nil && size > 0) {return}
	self := inject.mach_task_self();address: u64;stack: u64
	if !testing.expect_value(t, allocate(self, &address, u64(size), 1), i32(0)) {return}
	defer deallocate(self, address, u64(size))
	if !testing.expect_value(t, allocate(self, &stack, 16 * 1024, 1), i32(0)) {return}
	defer deallocate(self, stack, 16 * 1024)
	if !testing.expect_value(
		t,
		inject.mach_vm_protect(self, stack, 16 * 1024, 1, 1 | 2),
		i32(0),
	) {return}
	if !testing.expect_value(
		t,
		inject.mach_vm_write(self, address, uintptr(section), u32(size)),
		i32(0),
	) {return}
	if !testing.expect_value(
		t,
		inject.mach_vm_protect(self, address, u64(size), 0, 1 | 4),
		i32(0),
	) {return}
	offset := uintptr(rawptr(inject.remote_worker)) - uintptr(section)
	worker := cast(proc "c" (_: rawptr) -> rawptr)rawptr(uintptr(address) + offset)
	data := inject.Bootstrap {
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
	testing.expect_value(t, inject.self_test(), "")
}

@(test)
addition_upstream_pattern_tables_compile :: proc(t: ^testing.T) {
	providers := []proc(_: dock.Version) -> string {
		dock.get_dock_spaces_pattern,
		dock.get_dppm_pattern,
		dock.get_add_space_pattern,
		dock.get_remove_space_pattern,
		dock.get_move_space_pattern,
		dock.get_set_front_window_pattern,
		dock.get_fix_animation_pattern,
	}
	for major in ([]int{11, 12, 13, 14, 15, 26}) {
		for minor in 0 ..< 10 {
			version := dock.Version {
				major = major,
				minor = minor,
				patch = 0,
			}
			if !dock.supported(version) {continue}
			for provider in providers {
				text := provider(version);if text == "" {continue}
				pattern, ok := dock.compile(text)
				if testing.expect(
					t,
					ok,
				) {_, found := dock.find(pattern.bytes, pattern);testing.expect(t, found);dock.destroy(pattern)}
			}
		}
	}
}
