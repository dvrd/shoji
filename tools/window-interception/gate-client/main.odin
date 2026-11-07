package main

// Mach gate client (B1). One process registers the reversed rendezvous, takes
// the payload's send right, then may issue several commands. The first HELLO
// claims ownership; a later process can still connect and must be rejected.
import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:strconv"
import "core:strings"
import "core:time"
import gate "../../../src/windowserver/gate"

foreign import sls "system:SkyLight.framework"

Point :: struct {x, y: f64} // CGPoint; SLSMoveWindow takes a pointer to this
Rect :: struct {x, y, w, h: f64} // CGRect

foreign sls {
	SLSMainConnectionID :: proc "c" () -> i32 ---
	SLSMoveWindow :: proc "c" (connection: i32, window: u32, point: ^Point) -> i32 ---
	SLSMoveWindowWithGroup :: proc "c" (connection: i32, window: u32, point: ^Point) -> i32 ---
	SLSGetWindowBounds :: proc "c" (connection: i32, window: u32, bounds: ^Rect) -> i32 ---
	SLSCopySpacesForWindows :: proc "c" (connection: i32, selector: i32, windows: rawptr) -> rawptr ---
}

foreign import cf "system:CoreFoundation.framework"
foreign cf {
	CFNumberCreate :: proc "c" (allocator: rawptr, type: i32, value: rawptr) -> rawptr ---
	CFNumberGetValue :: proc "c" (number: rawptr, type: i32, value: rawptr) -> bool ---
	CFArrayCreate :: proc "c" (allocator: rawptr, values: ^rawptr, count: int, callbacks: rawptr) -> rawptr ---
	CFArrayGetCount :: proc "c" (array: rawptr) -> int ---
	CFArrayGetValueAtIndex :: proc "c" (array: rawptr, index: int) -> rawptr ---
	CFRelease :: proc "c" (object: rawptr) ---
	kCFTypeArrayCallBacks: u8
}

HISERVICES_PATH :: "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"

// A zero submission result is insufficient: the transaction wrapper returns
// zero even when its server-side operation does not change the foreign window.
move_verified :: proc(cid: i32, wid: u32, point: Point, group: bool) -> (code: i32, bounds: Rect, readback: i32, verified: bool) {
	requested := point
	if group {code = SLSMoveWindowWithGroup(cid, wid, &requested)} else {code = SLSMoveWindow(cid, wid, &requested)}
	if code != 0 {return}
	for _ in 0 ..< 20 {
		readback = SLSGetWindowBounds(cid, wid, &bounds)
		if readback == 0 && bounds.x == point.x && bounds.y == point.y {
			verified = true
			return
		}
		time.sleep(10 * time.Millisecond)
	}
	return
}

// Persistent controller (B7): one long-lived process claims gate ownership
// and serves placement/hold commands for the whole session, the role Shoji
// plays. Commands arrive one per line as "<id> <verb> [args]" on the request
// file; the matching "<id> ..." response is published atomically.
CONTROLLER_REQUEST_PATH :: "/private/tmp/shoji-gate-controller-request"
CONTROLLER_RESPONSE_PATH :: "/private/tmp/shoji-gate-controller-response"
CONTROLLER_LOCK_PATH :: "/private/tmp/shoji-gate-controller-lock"

foreign import system "system:System"
foreign system {
	@(link_name = "rename") rename_file :: proc "c" (from, to: cstring) -> i32 ---
	@(link_name = "flock") lock_file :: proc "c" (fd: i32, operation: i32) -> i32 ---
}

controller_write_response :: proc(line: string) {
	temporary := strings.concatenate({CONTROLLER_RESPONSE_PATH, ".tmp"})
	if os.write_entire_file(temporary, transmute([]u8)line) != nil {return}
	rename_file(strings.unsafe_string_to_cstring(temporary), CONTROLLER_RESPONSE_PATH)
}

Controller_State :: struct {
	task, service: u32,
	cid:         i32,
}

// The SLS connection appears only once a GUI session exists; resolve lazily
// so a controller started before login gains placement once the user logs in.
controller_cid :: proc(state: ^Controller_State) -> i32 {
	if state.cid == 0 {state.cid = SLSMainConnectionID()}
	return state.cid
}

handle_line :: proc(state: ^Controller_State, raw: []u8) -> (shutdown: bool, response: string) {
	fields := strings.fields(string(raw))
	if len(fields) < 2 {return false, "? status=1 err=parse"}
	id, verb := fields[0], fields[1]
	switch verb {
	case "layout-begin", "layout-status":
		command := gate.Gate_Command.LayoutBegin
		if verb == "layout-status" {command = .LayoutStatus}
		p, ok := exchange(state.task, state.service, command, 0, 0)
		if !ok {return false, fmt.tprintf("%s status=1 err=exchange", id)}
		return false, fmt.tprintf("%s status=%d gen=%d applied=%d elapsed_us=%d", id, p.status, p.data0, u32(p.data1), u32(p.data1 >> 32))
	case "layout-add":
		if len(fields) != 5 {return false, fmt.tprintf("%s status=1 err=args", id)}
		wid, wok := strconv.parse_u64(fields[2])
		x, xok := strconv.parse_i64(fields[3])
		y, yok := strconv.parse_i64(fields[4])
		if !wok || !xok || !yok || !gate.placement_coordinates_valid(wid, x, y) {return false, fmt.tprintf("%s status=1 err=args", id)}
		p, ok := exchange(state.task, state.service, .LayoutAdd, wid, gate.placement_pack(i32(x), i32(y)))
		if !ok {return false, fmt.tprintf("%s status=1 err=exchange", id)}
		return false, fmt.tprintf("%s status=%d count=%d target=%d", id, p.status, p.data0, p.data1)
	case "layout-arm":
		if len(fields) != 4 {return false, fmt.tprintf("%s status=1 err=args", id)}
		wid, wok := strconv.parse_u64(fields[2])
		budget, bok := strconv.parse_u64(fields[3])
		if !wok || !bok {return false, fmt.tprintf("%s status=1 err=args", id)}
		p, ok := exchange(state.task, state.service, .LayoutArm, wid, budget)
		if !ok {return false, fmt.tprintf("%s status=1 err=exchange", id)}
		return false, fmt.tprintf("%s status=%d target=%d gen=%d", id, p.status, p.data0, p.data1)
	case "place-server", "space-place":
		if len(fields) != 5 {return false, fmt.tprintf("%s status=1 err=args", id)}
		wid, wok := strconv.parse_u64(fields[2])
		x, xok := strconv.parse_i64(fields[3])
		y, yok := strconv.parse_i64(fields[4])
		if !wok || !xok || !yok || !gate.placement_coordinates_valid(wid, x, y) {return false, fmt.tprintf("%s status=1 err=args", id)}
		command := gate.Gate_Command.ArmPlace
		if verb == "space-place" {command = .SpacePlace}
		p, ok := exchange(state.task, state.service, command, wid, gate.placement_pack(i32(x), i32(y)))
		if !ok {return false, fmt.tprintf("%s status=1 err=exchange", id)}
		return false, fmt.tprintf("%s status=%d target=%d gen=%d", id, p.status, p.data0, p.data1)
	case "placement":
		p, ok := exchange(state.task, state.service, .PlacementStatus, 0, 0)
		if !ok {return false, fmt.tprintf("%s status=1 err=exchange", id)}
		x, y := gate.placement_unpack(p.data1)
		return false, fmt.tprintf("%s status=%d gen=%d x=%d y=%d", id, p.status, p.data0, x, y)
	case "arm":
		if len(fields) < 4 {return false, fmt.tprintf("%s status=1 err=args", id)}
		wid, wok := strconv.parse_u64(fields[2])
		scope, sok := strconv.parse_u64(fields[3])
		if !wok || !sok {return false, fmt.tprintf("%s status=1 err=args", id)}
		p, ok := exchange(state.task, state.service, .Arm, wid, scope)
		if !ok {return false, fmt.tprintf("%s status=1 err=exchange", id)}
		return false, fmt.tprintf("%s status=%d target=%d gen=%d", id, p.status, p.data0, p.data1)
	case "release":
		if len(fields) < 3 {return false, fmt.tprintf("%s status=1 err=args", id)}
		generation, gok := strconv.parse_u64(fields[2])
		if !gok {return false, fmt.tprintf("%s status=1 err=args", id)}
		p, ok := exchange(state.task, state.service, .Release, generation, 0)
		if !ok {return false, fmt.tprintf("%s status=1 err=exchange", id)}
		return false, fmt.tprintf("%s status=%d target=%d gen=%d", id, p.status, p.data0, p.data1)
	case "status", "dump":
		command := gate.Gate_Command.Status
		if verb == "dump" {command = .Dump}
		p, ok := exchange(state.task, state.service, command, 0, 0)
		if !ok {return false, fmt.tprintf("%s status=1 err=exchange", id)}
		return false, fmt.tprintf("%s status=%d calls=%d owner=%d handshake=%d", id, p.status, p.data0, u32(p.data1), u32(p.data1 >> 32))
	case "watch":
		if len(fields) < 3 {return false, fmt.tprintf("%s status=1 err=args", id)}
		wid, wok := strconv.parse_u64(fields[2])
		if !wok {return false, fmt.tprintf("%s status=1 err=args", id)}
		p, ok := exchange(state.task, state.service, .Watch, wid, 0)
		if !ok {return false, fmt.tprintf("%s status=1 err=exchange", id)}
		return false, fmt.tprintf("%s status=%d target=%d gen=%d", id, p.status, p.data0, p.data1)
	case "receipt":
		generation: u64
		gok := true
		if len(fields) >= 3 {
			generation, gok = strconv.parse_u64(fields[2])
		}
		if !gok {return false, fmt.tprintf("%s status=1 err=args", id)}
		p, ok := exchange(state.task, state.service, .WatchStatus, generation, 0)
		if !ok {return false, fmt.tprintf("%s status=1 err=exchange", id)}
		return false, fmt.tprintf("%s status=%d result=%d ticks=%d", id, p.status, i64(p.data0), p.data1)
	case "place", "place-group":
		if len(fields) < 5 {return false, fmt.tprintf("%s status=1 err=args", id)}
		wid, wok := strconv.parse_u64(fields[2])
		x, xok := strconv.parse_u64(fields[3])
		y, yok := strconv.parse_u64(fields[4])
		if !wok || !xok || !yok {return false, fmt.tprintf("%s status=1 err=args", id)}
		cid := controller_cid(state)
		if cid == 0 {return false, fmt.tprintf("%s status=2", id)}
		point := Point{f64(x), f64(y)}
		code, bounds, readback, verified := move_verified(cid, u32(wid), point, verb == "place-group")
		return false, fmt.tprintf("%s status=%d verified=%v readback=%d x=%d y=%d", id, code, verified, readback, i64(bounds.x), i64(bounds.y))
	case "bounds":
		if len(fields) < 3 {return false, fmt.tprintf("%s status=1 err=args", id)}
		wid, wok := strconv.parse_u64(fields[2])
		if !wok {return false, fmt.tprintf("%s status=1 err=args", id)}
		cid := controller_cid(state)
		if cid == 0 {return false, fmt.tprintf("%s status=2", id)}
		rect: Rect
		code := SLSGetWindowBounds(cid, u32(wid), &rect)
		return false, fmt.tprintf("%s status=%d x=%d y=%d w=%d h=%d", id, code, i64(rect.x), i64(rect.y), i64(rect.w), i64(rect.h))
	case "shutdown":
		return true, fmt.tprintf("%s status=0", id)
	}
	return false, fmt.tprintf("%s status=1 err=verb", id)
}

// Persistent controller: claim ownership, then serve one-line commands.
run_serve :: proc(task, service: u32) -> int {
	lock := posix.open(CONTROLLER_LOCK_PATH, {.RDWR, .CREAT, .NOFOLLOW}, {.IRUSR, .IWUSR})
	if lock < 0 {fmt.eprintln("FAIL: controller lock open"); return 1}
	defer posix.close(lock)
	info: posix.stat_t
	if posix.fstat(lock, &info) != nil || !posix.S_ISREG(info.st_mode) || info.st_uid != posix.getuid() || lock_file(i32(lock), 2 | 4) != 0 {
		fmt.eprintln("FAIL: controller already running or invalid lock")
		return 1
	}
	p, ok := exchange(task, service, .Hello, 0x53484f4a, 0)
	if !ok || !accepted(p) {
		fmt.eprintf("FAIL: serve hello status=%d data0=%d (gate already owned?)\n", p.status, p.data0)
		return 1
	}
	fmt.printf("owner pid=%d\n", posix.getpid())
	state := Controller_State{task = task, service = service, cid = SLSMainConnectionID()}
	if state.cid == 0 {fmt.eprintln("WARN: SLSMainConnectionID=0; place/bounds unavailable")}
	last: [64]u8
	last_n := -1
	for {
		// A WindowServer restart leaves a dead name. Stop serving the shared
		// driver files instead of competing with the replacement controller.
		port_type: u32
		if gate.gate_mach_port_type(task, service, &port_type) != 0 || port_type & gate.MACH_PORT_TYPE_SEND == 0 {
			fmt.eprintln("gate disconnected; controller exiting")
			return 1
		}
		fd := posix.open(CONTROLLER_REQUEST_PATH, {.NOFOLLOW, .NONBLOCK})
		if fd >= 0 {
			info: posix.stat_t
			request: [64]u8
			valid := posix.fstat(fd, &info) == nil && posix.S_ISREG(info.st_mode) &&
				info.st_uid == posix.getuid() && info.st_size > 0 && info.st_size <= len(request)
			n: int
			if valid {
				n = posix.read(fd, &request[0], len(request))
				// Reject in-flight partial writes: every command ends with \n.
				valid = n > 0 && request[n - 1] == '\n'
			}
			posix.close(fd)
			changed := valid && n != last_n
			if valid && n == last_n {
				for index in 0 ..< n {
					if request[index] != last[index] {changed = true; break}
				}
			}
			if valid && changed {
				last_n = n
				for index in 0 ..< n {last[index] = request[index]}
				exit, response := handle_line(&state, request[:n - 1])
				controller_write_response(fmt.tprintf("%s\n", response))
				if exit {return 0}
			}
		}
		time.sleep(10 * time.Millisecond)
	}
}

Mach_Buffer :: struct #align(16) {
	bytes: [128]u8,
}

usage :: proc() {
	fmt.eprintln("usage: shoji-gate-client hello | arm WID [SCOPE] | release | status | dump | prove | fuzz | serve | place WID X Y | place-group WID X Y | bounds WID | spaces WID")
	os.exit(2)
}

// Task-port handoff rendezvous: publish request.<pid> and wait for the root
// helper to insert a send right to the gate port into this task, answering
// through response.<pid>. Per-pid channels survive concurrent clients; the
// response's pid must match so a stale response cannot be mistaken for ours.
connect_handoff :: proc(task: u32) -> (service: u32, ok: bool) {
	pid := posix.getpid()
	request: [32]u8
	n := len(strconv.write_int(request[:], i64(pid), 10))
	request[n] = '\n'
	request_path := fmt.tprintf("%s.%d", gate.GATE_HANDOFF_REQUEST_PATH, pid)
	response_path := fmt.tprintf("%s.%d", gate.GATE_HANDOFF_RESPONSE_PATH, pid)
	fd := posix.open(strings.unsafe_string_to_cstring(request_path), {.WRONLY, .CREAT, .TRUNC}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if fd < 0 {return}
	written := posix.write(fd, &request[0], uint(n + 1))
	posix.close(fd)
	if written != n + 1 {return}
	for _ in 0 ..< 100 {
		time.sleep(50 * time.Millisecond)
		response_fd := posix.open(strings.unsafe_string_to_cstring(response_path), {.NOFOLLOW})
		if response_fd < 0 {continue}
		buffer: [64]u8
		count := posix.read(response_fd, &buffer[0], len(buffer))
		info: posix.stat_t
		valid := posix.fstat(response_fd, &info) == nil && posix.S_ISREG(info.st_mode)
		posix.close(response_fd)
		if !valid || count <= 0 {continue}
		line := string(buffer[:count])
		space := -1
		for i in 0 ..< count {
			if buffer[i] == ' ' {space = i; break}
		}
		if space <= 0 || space + 1 >= count {continue}
		owner, owner_ok := strconv.parse_u64(line[:space])
		name_end := space + 1
		for name_end < count && buffer[name_end] >= '0' && buffer[name_end] <= '9' {name_end += 1}
		name, name_ok := strconv.parse_u64(line[space + 1:name_end])
		if !owner_ok || !name_ok || i64(owner) != i64(pid) || name == 0 {continue}
		candidate := u32(name)
		type: u32
		if code := gate.gate_mach_port_type(task, candidate, &type); code != 0 {continue}
		if type & gate.MACH_PORT_TYPE_SEND == 0 {continue}
		return candidate, true
	}
	return
}

// Bootstrap rendezvous retained for environments where WindowServer may call
// bootstrap_look_up; on macOS 27 that call is denied (1100), so the handoff
// above is the live path there.
connect_bootstrap :: proc(task: u32) -> (service: u32, ok: bool) {
	bp, bp_ok := gate.gate_process_bootstrap_port()
	if !bp_ok {
		fmt.eprintln("FAIL: bootstrap_port")
		return
	}
	rendezvous: u32
	if code := gate.gate_mach_port_allocate(task, gate.MACH_PORT_RIGHT_RECEIVE, &rendezvous); code != 0 {
		fmt.eprintf("FAIL: rendezvous allocate (%d)\n", code)
		return
	}
	defer gate.gate_mach_port_destroy(task, rendezvous)
	if code := gate.gate_bootstrap_register(bp, gate.GATE_RENDEZVOUS_NAME, rendezvous); code != 0 {
		fmt.eprintf("FAIL: rendezvous register (%d); another client holding it?\n", code)
		return
	}
	handshake: Mach_Buffer
	hcode := gate.gate_mach_msg(&handshake.bytes[0], gate.MACH_MSG_RECEIVE|gate.MACH_RCV_TIMEOUT, 0, len(handshake.bytes), rendezvous, 3000, 0)
	if hcode != 0 {
		fmt.eprintf("FAIL: handshake receive (%#x); is the observer payload installed?\n", u32(hcode))
		return
	}
	service, ok = gate.gate_handshake_send_right(handshake.bytes[:])
	if !ok {
		fmt.eprintln("FAIL: handshake carried no send right")
	}
	return
}

connect :: proc() -> (task, service: u32, ok: bool) {
	task = gate.gate_mach_task_self()
	if handoff, handoff_ok := connect_handoff(task); handoff_ok {
		return task, handoff, true
	}
	service, ok = connect_bootstrap(task)
	return
}

// Send a prebuilt message; the reply port is allocated here and stamped over
// whatever the buffer carries so fuzz cases cannot lose the reply channel.
send_raw :: proc(task, service: u32, msg: ^Mach_Buffer, n: int) -> (parsed: gate.Gate_Reply, ok: bool) {
	reply: u32
	if code := gate.gate_mach_port_allocate(task, gate.MACH_PORT_RIGHT_RECEIVE, &reply); code != 0 {
		fmt.eprintf("FAIL: reply port allocate (%d)\n", code)
		return
	}
	defer gate.gate_mach_port_destroy(task, reply)
	if !gate.gate_store_u32(msg.bytes[:], 12, reply) {
		fmt.eprintln("FAIL: stamp reply right")
		return
	}
	options := u32(gate.MACH_MSG_SEND) | u32(gate.MACH_MSG_RECEIVE) | u32(gate.MACH_RCV_TIMEOUT)
	if code := gate.gate_mach_msg(&msg.bytes[0], options, u32(n), len(msg.bytes), reply, 1000, 0); code != 0 {
		fmt.eprintf("FAIL: mach_msg (%#x)\n", u32(code))
		return
	}
	parsed, ok = gate.gate_unpack_reply(msg.bytes[:])
	if !ok {
		fmt.eprintln("FAIL: short reply")
	}
	return
}

exchange :: proc(task, service: u32, command: gate.Gate_Command, arg0, arg1: u64) -> (parsed: gate.Gate_Reply, ok: bool) {
	msg: Mach_Buffer
	n, packed := gate.gate_pack_request(msg.bytes[:], service, 1, command, arg0, arg1)
	if !packed {
		fmt.eprintln("FAIL: pack request")
		return
	}
	parsed, ok = send_raw(task, service, &msg, n)
	if ok && (parsed.magic != gate.GATE_REPLY_MAGIC || parsed.version != gate.GATE_VERSION || parsed.command != u32(command)) {
		fmt.eprintln("FAIL: reply identity/version/command mismatch")
		ok = false
	}
	return
}

// Negative coverage: well-formed framing with one corrupted field each. The
// gate must reject every case with status 1 (malformed), never crash, and
// keep answering afterwards (proven by the caller's next command).
run_fuzz :: proc(task, service: u32) -> bool {
	cases := []struct {
		name:  string,
		off:   int,
		value: u32,
	}{
		{"bad magic", gate.GATE_OFF_MAGIC, 0xdeadbeef},
		{"bad version", gate.GATE_OFF_VERSION, 2},
		{"unknown command", gate.GATE_OFF_COMMAND, 0xff},
		{"zero command", gate.GATE_OFF_COMMAND, 0},
	}
	all_ok := true
	for c in cases {
		msg: Mach_Buffer
		n, packed := gate.gate_pack_request(msg.bytes[:], service, 1, .Hello, 0, 0)
		if !packed {
			fmt.eprintln("FAIL: pack request")
			return false
		}
		gate.gate_store_u32(msg.bytes[:], c.off, c.value)
		parsed, ok := send_raw(task, service, &msg, n)
		if !ok {
			fmt.eprintf("%s: no reply\n", c.name)
			all_ok = false
			continue
		}
		fmt.printf("%s: reply status=%d (want 1)\n", c.name, parsed.status)
		if parsed.status != 1 {all_ok = false}
	}
	return all_ok
}

report :: proc(parsed: gate.Gate_Reply) {
	fmt.printf("reply: magic=%#x version=%d command=%d status=%d data0=%#x data1=%#x\n",
		parsed.magic, parsed.version, parsed.command, parsed.status, parsed.data0, parsed.data1)
}

accepted :: proc(parsed: gate.Gate_Reply) -> bool {
	return parsed.magic == gate.GATE_REPLY_MAGIC && parsed.status == 0
}

// Hold state machine (B2) battery. Runs as the gate owner right after the
// classic prove steps; the slot must be free again when it ends.
prove_hold_battery :: proc(task, service: u32) -> bool {
	expect :: proc(parsed: gate.Gate_Reply, label: string, good: bool) -> bool {
		report(parsed)
		if !good {fmt.eprintf("FAIL: %s\n", label)}
		return good
	}
	// Arm a real slot; the reply carries the generation.
	p1, r1 := exchange(task, service, .Arm, 55, 3)
	if !r1 || !expect(p1, "arm 55", accepted(p1)) {return false}
	generation := u32(p1.data1)
	if generation == 0 {
		fmt.eprintln("FAIL: arm returned generation 0")
		return false
	}
	// Busy arm: status 6, reporting the current target and generation.
	p2, r2 := exchange(task, service, .Arm, 66, 3)
	if !r2 || !expect(p2, "busy arm", p2.status == 6 && p2.data0 == 55 && u32(p2.data1) == generation) {return false}
	// Stale generation release: status 7, slot untouched.
	p3, r3 := exchange(task, service, .Release, u64(generation) + 99, 0)
	if !r3 || !expect(p3, "stale release", p3.status == 7 && p3.data0 == 55) {return false}
	// Current generation releases.
	p4, r4 := exchange(task, service, .Release, u64(generation), 0)
	if !r4 || !expect(p4, "release", p4.status == 0 && p4.data0 == 55) {return false}
	// Releasing a free slot is an idempotent no-op.
	p5, r5 := exchange(task, service, .Release, u64(generation), 0)
	if !r5 || !expect(p5, "idempotent release", p5.status == 0 && p5.data0 == 0) {return false}
	// Re-arm after free works and bumps the generation.
	p6, r6 := exchange(task, service, .Arm, 55, 3)
	if !r6 || !expect(p6, "re-arm", p6.status == 0 && u32(p6.data1) == generation + 1) {return false}
	p7, r7 := exchange(task, service, .Release, 0, 0)
	if !r7 || !expect(p7, "final release", p7.status == 0 && p7.data0 == 55) {return false}
	return true
}

main :: proc() {
	if len(os.args) < 2 {usage()}
	if os.args[1] == "axcheck" {
		handle := gate.gate_dlopen(HISERVICES_PATH, 2)
		if handle == nil {
			fmt.eprintln("FAIL: dlopen HIServices")
			os.exit(1)
		}
		symbol := gate.gate_dlsym(handle, "AXIsProcessTrusted")
		if symbol == nil {
			fmt.eprintln("FAIL: dlsym AXIsProcessTrusted")
			os.exit(1)
		}
		trusted := transmute(proc "c" () -> bool)symbol
		fmt.printf("ax_trusted=%v\n", trusted())
		return
	}
	// place/bounds are pure SLS operations: no gate connection, no ownership.
	// They run as one-shots so a controller started before login (SLS cid 0)
	// never blocks placement; a fresh connection resolves per invocation.
	if os.args[1] == "place" || os.args[1] == "place-group" {
		if len(os.args) < 5 {usage()}
		wid, wok := strconv.parse_u64(os.args[2])
		x, xok := strconv.parse_u64(os.args[3])
		y, yok := strconv.parse_u64(os.args[4])
		if !wok || !xok || !yok {usage()}
		cid := SLSMainConnectionID()
		if cid == 0 {
			fmt.eprintln("FAIL: no SLS connection (GUI session present?)")
			os.exit(1)
		}
		point := Point{f64(x), f64(y)}
		code, bounds, readback, verified := move_verified(cid, u32(wid), point, os.args[1] == "place-group")
		fmt.printf("place: window=%d requested_x=%d requested_y=%d status=%d verified=%v readback=%d x=%d y=%d\n", u32(wid), i64(point.x), i64(point.y), code, verified, readback, i64(bounds.x), i64(bounds.y))
		if code != 0 || !verified {os.exit(1)}
		return
	}
	if os.args[1] == "bounds" {
		if len(os.args) < 3 {usage()}
		wid, wok := strconv.parse_u64(os.args[2])
		if !wok {usage()}
		cid := SLSMainConnectionID()
		if cid == 0 {
			fmt.eprintln("FAIL: no SLS connection (GUI session present?)")
			os.exit(1)
		}
		rect: Rect
		code := SLSGetWindowBounds(cid, u32(wid), &rect)
		fmt.printf("bounds: window=%d status=%d x=%d y=%d w=%d h=%d\n", u32(wid), code, i64(rect.x), i64(rect.y), i64(rect.w), i64(rect.h))
		if code != 0 {os.exit(1)}
		return
	}
	// Independent Space membership readback (selector 7: all spaces).
	if os.args[1] == "spaces" {
		if len(os.args) < 3 {usage()}
		wid, wok := strconv.parse_u64(os.args[2])
		if !wok {usage()}
		cid := SLSMainConnectionID()
		if cid == 0 {
			fmt.eprintln("FAIL: no SLS connection (GUI session present?)")
			os.exit(1)
		}
		id := wid
		value := CFNumberCreate(nil, 4, &id)
		array := CFArrayCreate(nil, &value, 1, &kCFTypeArrayCallBacks)
		spaces := SLSCopySpacesForWindows(cid, 7, array)
		CFRelease(array)
		CFRelease(value)
		fmt.printf("spaces: window=%d", u32(wid))
		if spaces != nil {
			for index in 0 ..< CFArrayGetCount(spaces) {
				space: u64
				CFNumberGetValue(CFArrayGetValueAtIndex(spaces, index), 4, &space)
				fmt.printf(" %d", space)
			}
			CFRelease(spaces)
		}
		fmt.println()
		return
	}
	command: gate.Gate_Command
	arg0, arg1: u64
	prove := false
	fuzz := false
	serve := false
	switch os.args[1] {
	case "hello":
		command = .Hello
		arg0 = 0x53484f4a
	case "arm":
		if len(os.args) < 3 {
			fmt.eprintln("arm requires a window id")
			os.exit(2)
		}
		wid, wid_ok := strconv.parse_u64(os.args[2])
		if !wid_ok || wid == 0 {
			fmt.eprintln("arm requires a decimal window id")
			os.exit(2)
		}
		command = .Arm
		arg0 = wid
		arg1 = 3
		if len(os.args) > 3 {
			scope, scope_ok := strconv.parse_u64(os.args[3])
			if scope_ok {arg1 = scope}
		}
	case "release":
		command = .Release
	case "status":
		command = .Status
	case "dump":
		command = .Dump
	case "watch":
		command = .Watch
		if len(os.args) < 3 {
			fmt.eprintln("watch requires a window id (0 cancels)")
			os.exit(2)
		}
		wid, wid_ok := strconv.parse_u64(os.args[2])
		if !wid_ok {
			fmt.eprintln("watch requires a decimal window id")
			os.exit(2)
		}
		arg0 = wid
	case "receipt":
		command = .WatchStatus
		if len(os.args) > 2 {
			generation, gen_ok := strconv.parse_u64(os.args[2])
			if gen_ok {arg0 = generation}
		}
	case "prove":
		prove = true
	case "fuzz":
		fuzz = true
	case "serve":
		serve = true
	case:
		fmt.eprintf("unknown command %q\n", os.args[1])
		os.exit(2)
	}

	task, service, connected := connect()
	if !connected {os.exit(1)}
	defer gate.gate_mach_port_deallocate(task, service)

	if serve {os.exit(run_serve(task, service))}

	// One-shot commands claim first: an unowned or dead-owner gate (reclaim)
	// accepts this process, a live owner still refuses with 4 below.
	if command != .Hello && !prove && !fuzz {
		if parsed, ok := exchange(task, service, .Hello, 0x53484f4a, 0); ok {
			fmt.printf("pre-hello status=%d owner=%d\n", parsed.status, parsed.data0)
		}
	}

	if fuzz {
		if !run_fuzz(task, service) {os.exit(1)}
		return
	}

	if prove {
		// Scope 0 arms neither hold. This checks ownership across commands
		// without stalling a compositor transaction.
		steps := [4]struct {command: gate.Gate_Command, arg0, arg1: u64}{
			{.Hello, 0x53484f4a, 0},
			{.Status, 0, 0},
			{.Arm, 1, 0},
			{.Release, 0, 0},
		}
		for step in steps {
			parsed, ok := exchange(task, service, step.command, step.arg0, step.arg1)
			if !ok {os.exit(1)}
			report(parsed)
			if !accepted(parsed) {os.exit(1)}
		}
		if !prove_hold_battery(task, service) {os.exit(1)}
		return
	}

	parsed, ok := exchange(task, service, command, arg0, arg1)
	if !ok {os.exit(1)}
	report(parsed)
	if !accepted(parsed) {os.exit(1)}
}
