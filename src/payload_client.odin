#+build darwin

package shoji

import wire "dock"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:time"
import ws_wire "experimental/window_server"

// Scripting-addition protocol client
// ------------------------------------------------------------------------

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

addition_action :: proc(action: Action) -> string {
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

// Scripting-addition reload
// ------------------------------------------------------------------------

Addition_Reload_Phase :: enum {
	Check,
	Load,
}
Addition_Reload :: struct {
	binary, payload: string,
	dock, child, child_dock: i32,
	phase: Addition_Reload_Phase,
	healthy, loaded: bool,
	next_attempt: time.Time,
	retry_delay: time.Duration,
	spawn: proc(
		user: rawptr,
		phase: Addition_Reload_Phase,
		binary, payload: string,
	) -> (
		i32,
		string,
	),
	user: rawptr,
}

addition_reload_init :: proc(r: ^Addition_Reload, payload: string) -> string {
	if payload == "" {
		return ""
	}
	path, err := filepath.abs(payload, context.temp_allocator)
	if err != nil || !os.is_file(path) {
		return "scripting-addition library does not exist or is not a file"
	}
	binary, binary_err := os.get_executable_path(context.temp_allocator)
	if binary_err != nil {
		return "cannot resolve shoji executable path"
	}
	r.payload = strings.clone(path)
	r.binary = strings.clone(binary)
	return ""
}
addition_reload_destroy :: proc(r: ^Addition_Reload) {
	// The standalone loader owns its remote operation and completion cleanup.
	// Do not interrupt an in-flight injection when the daemon shuts down.
	delete(r.payload); delete(r.binary)
	r^ = {}
}
addition_reload_spawn :: proc(
	user: rawptr,
	phase: Addition_Reload_Phase,
	binary, payload: string,
) -> (
	i32,
	string,
) {
	args: [6]cstring
	if phase == .Load {
		args = {
			"/usr/bin/sudo",
			"-n",
			strings.clone_to_cstring(binary, context.temp_allocator),
			"--load-sa",
			strings.clone_to_cstring(payload, context.temp_allocator),
			nil,
		}
	} else {
		args = {
			strings.clone_to_cstring(binary, context.temp_allocator),
			"--check-sa",
			nil,
			nil,
			nil,
			nil,
		}
	}
	pid: posix.pid_t
	if posix.posix_spawn(
		   &pid,
		   args[0],
		   nil,
		   nil,
		   &args[0],
		   _NSGetEnviron()^,
	   ) !=
	   nil {
		return 0, "cannot start scripting-addition recovery subprocess"
	}
	return i32(pid), ""
}
addition_reload_backoff :: proc(r: ^Addition_Reload, now: time.Time) {
	r.retry_delay =
		r.retry_delay == 0 \
			? time.Second \
			: min(r.retry_delay * 2, 30 * time.Second)
	r.next_attempt = time.time_add(now, r.retry_delay)
}
addition_reload_tick :: proc(r: ^Addition_Reload, dock: i32, now: time.Time) {
	if r.payload == "" {
		return
	}
	if dock != r.dock {
		r.dock = dock
		r.healthy, r.loaded = false, false
		r.phase = .Check
		r.next_attempt = now
		r.retry_delay = 0
	}
	if dock == 0 ||
	   r.child != 0 ||
	   r.healthy ||
	   time.diff(now, r.next_attempt) > 0 {
		return
	}
	spawn := r.spawn
	if spawn == nil {
		spawn = addition_reload_spawn
	}
	pid, err := spawn(r.user, r.phase, r.binary, r.payload)
	if err != "" || pid <= 0 {
		fmt.eprintln("shoji: payload recovery:", err)
		addition_reload_backoff(r, now)
		return
	}
	r.child, r.child_dock = pid, dock
}
addition_reload_finished :: proc(
	r: ^Addition_Reload,
	child: i32,
	success: bool,
	now: time.Time,
) -> bool {
	if child == 0 || child != r.child {
		return false
	}
	r.child = 0
	// A subprocess completing for an old Dock cannot establish current health.
	if r.child_dock != r.dock {
		return true
	}
	if r.phase == .Check {
		if success {
			r.healthy = true
			r.retry_delay = 0
			fmt.eprintln("shoji: Dock payload is ready")
		} else if !r.loaded {
			r.phase = .Load
			r.next_attempt = now
		} else {
			fmt.eprintln(
				"shoji: loaded payload handshake failed; retrying verification",
			)
			addition_reload_backoff(r, now)
		}
	} else {
		r.phase = .Check
		if success {
			r.loaded = true
			r.next_attempt = now
		} else {
			fmt.eprintln(
				"shoji: payload reload failed; retrying (noninteractive sudo permission is required)",
			)
			addition_reload_backoff(r, now)
		}
	}
	return true
}

// Experimental WindowServer integration
// ------------------------------------------------------------------------

windowserver_check :: proc() -> (ws_wire.Capabilities, string) {
	fd := connect_socket(fmt.tprintf("/tmp/shoji-ws_%d.socket", getuid()))
	if fd < 0 {
		return {},
			"WindowServer experimental payload is not loaded; use --load-ws only in the test VM"
	}
	defer close(fd)

	uid, gid: u32
	if getpeereid(fd, &uid, &gid) != 0 || uid != ws_wire.UID {
		return {}, "unexpected WindowServer payload socket owner"
	}

	packet := ws_wire.begin(.Handshake)
	if !write_all(fd, ws_wire.finish(&packet)) {
		return {}, "could not send WindowServer payload handshake"
	}
	status: [1]u8
	if !read_exact(fd, status[:]) {
		return {}, "WindowServer payload did not acknowledge the handshake"
	}
	if status[0] != u8(ws_wire.Status.OK) {
		return {}, fmt.tprintf(
			"WindowServer payload returned %v",
			ws_wire.Status(status[0]),
		)
	}
	data: [len(ws_wire.VERSION) + 5]u8
	if !read_exact(fd, data[:]) {
		return {}, "incomplete WindowServer payload handshake"
	}
	caps, ok := ws_wire.decode_handshake(data[:])
	if !ok {
		return {}, "incompatible WindowServer payload protocol"
	}
	return caps, ""
}
