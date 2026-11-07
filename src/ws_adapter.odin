package shoji

// WindowServer gate adapter (C4). Two layers:
//
//  * Ws_Gate_Probe: read-only reporting for --check-ws. Never claims the gate.
//  * Ws_Adapter: Shoji's own direct-Mach client. Opt-in only; every operation
//    returns `handled`, and an unhandled result means "do today's behavior".
//    Any transport failure, identity mismatch or ownership loss latches the
//    adapter to .Lost so later calls short-circuit to the fallback path. The
//    daemon's default paths never require the adapter, so Shoji works
//    unchanged when the payload is absent, disabled or refuses Shoji.
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"
import gate "windowserver/gate"
import attach "windowserver/attach"

Ws_Gate_Level :: enum {
	Absent, // no payload status artifact
	Installed, // payload resident, no controller serving the gate
	Serving, // a controller answered a status command
}

Ws_Gate_Probe :: struct {
	level:     Ws_Gate_Level,
	owner_pid: u32,
	calls:     u64,
	detail:    string,
}

WS_TGATE_STATUS_PATH :: gate.TGATE_STATUS_PATH
WS_CONTROLLER_REQUEST_PATH :: "/private/tmp/shoji-gate-controller-request"
WS_CONTROLLER_RESPONSE_PATH :: "/private/tmp/shoji-gate-controller-response"
WS_ENABLE_ENV :: "SHOJI_WS_ADAPTER"
WS_DISABLE_ENV :: "SHOJI_WINDOWSERVER_DISABLE"
WS_HELLO_NONCE :: 0x53484f4a

// Pure classification, unit-tested; the level only ever rises with evidence.
ws_gate_classify :: proc(tgate_present, controller_answered: bool) -> Ws_Gate_Level {
	if controller_answered {return .Serving}
	if tgate_present {return .Installed}
	return .Absent
}

ws_tgate_present :: proc() -> bool {
	fd := posix.open(WS_TGATE_STATUS_PATH, {.NOFOLLOW})
	if fd < 0 {return false}
	defer posix.close(fd)
	buffer: [8]u8
	n := posix.read(fd, &buffer[0], len(buffer))
	return n == len(buffer) && string(buffer[:]) == "WSOBTGAT"
}

// Ask the serving controller for one status line. The request id derives
// from the clock so the controller's content dedupe never drops it.
ws_controller_status :: proc(timeout: time.Duration) -> (owner: u32, calls: u64, answered: bool) {
	id := time.time_to_unix_nano(time.now()) / 1_000_000
	command := fmt.tprintf("%d status\n", id)
	fd := posix.open(WS_CONTROLLER_REQUEST_PATH, {.WRONLY, .CREAT, .TRUNC}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if fd < 0 {return}
	written := posix.write(fd, raw_data(command), uint(len(command)))
	posix.close(fd)
	if written != len(command) {return}
	deadline := time.time_to_unix_nano(time.now()) + i64(timeout)
	prefix := fmt.tprintf("%d ", id)
	for time.time_to_unix_nano(time.now()) < deadline {
		time.sleep(20 * time.Millisecond)
		rfd := posix.open(WS_CONTROLLER_RESPONSE_PATH, {.NOFOLLOW})
		if rfd < 0 {continue}
		buffer: [128]u8
		n := posix.read(rfd, &buffer[0], len(buffer))
		posix.close(rfd)
		if n <= len(prefix) {continue}
		response := string(buffer[:n])
		if !strings.has_prefix(response, prefix) {continue}
		answered = true
		for field in strings.fields(response[len(prefix):]) {
			if strings.has_prefix(field, "owner=") {
				parsed, _ := strconv.parse_u64(field[len("owner="):])
				owner = u32(parsed)
			}
			if strings.has_prefix(field, "calls=") {
				parsed, _ := strconv.parse_u64(field[len("calls="):])
				calls = parsed
			}
		}
		return
	}
	return
}

ws_gate_probe :: proc(timeout: time.Duration = 1500 * time.Millisecond) -> Ws_Gate_Probe {
	owner, calls, answered := ws_controller_status(timeout)
	probe := Ws_Gate_Probe {
		level     = ws_gate_classify(ws_tgate_present(), answered),
		owner_pid = owner,
		calls     = calls,
	}
	switch probe.level {
	case .Absent:
		probe.detail = "no experimental WindowServer payload artifact"
	case .Installed:
		probe.detail = "payload resident; no controller serving the gate"
	case .Serving:
		probe.detail = "gate controller answered status"
	}
	return probe
}

// ------------------------------------------------------------------------
// Adapter
// ------------------------------------------------------------------------

Ws_Adapter_State :: enum {
	Disabled, // not opted in, or kill switch present
	Absent, // no payload, or no send right handed off
	Refused, // payload answered but did not accept Shoji as owner
	Serving, // Shoji owns the gate
	Lost, // was serving; transport or ownership failed (latched)
}

// Transport seam: the real one is Mach, tests inject replies.
Ws_Exchange :: #type proc(user: rawptr, command: gate.Gate_Command, arg0, arg1: u64) -> (gate.Gate_Reply, bool)

Ws_Adapter :: struct {
	state:    Ws_Adapter_State,
	exchange: Ws_Exchange,
	user:     rawptr,
	owner:    u32, // owner pid reported by a refusing gate
	status:   i32, // last nonzero gate status
	mach:     Ws_Mach,
	marker:   Ws_Marker,
	focus:    Ws_Focus_Receipt,
}

// C2: AXRaise is handled by the owning app after the call returns; on the
// 26A434 guest the order-in landed 15–37 ms later (daemon run 2026-11-05).
// The watch stays armed and is resolved on later loop ticks.
WS_FOCUS_RECEIPT_WINDOW :: 100 * time.Millisecond

Ws_Focus_Receipt :: struct {
	generation: u32,
	window:     u32,
	armed:      time.Time,
}

Ws_Mach :: struct {
	task, service: u32,
}

// Shoji-owned 1×1 transparent trigger window for staged layouts (C1);
// created on first use with the daemon's connection, released on close.
Ws_Marker :: struct {
	connection: i32,
	window:     u32,
}

// Gate status codes shared with the payload.
WS_STATUS_OK :: 0
WS_STATUS_MALFORMED :: 1
WS_STATUS_OWNED :: 3
WS_STATUS_NOT_OWNER :: 4
WS_STATUS_BUSY :: 6
WS_STATUS_STALE :: 7
WS_STATUS_IDLE :: 8

ws_adapter_state_name :: proc(state: Ws_Adapter_State) -> string {
	switch state {
	case .Disabled:
		return "disabled"
	case .Absent:
		return "absent"
	case .Refused:
		return "refused"
	case .Serving:
		return "serving"
	case .Lost:
		return "lost"
	}
	return "unknown"
}

// Pure enablement decision: the kill switch always wins over the opt-in.
ws_adapter_enabled :: proc(opt_in, disable_env, sentinel: bool) -> bool {
	return opt_in && !disable_env && !sentinel
}

ws_adapter_env_enabled :: proc() -> bool {
	opt_in := os.get_env(WS_ENABLE_ENV, context.temp_allocator) == "1"
	disable := os.get_env(WS_DISABLE_ENV, context.temp_allocator) == "1"
	sentinel := os.exists(attach.WS_DISABLE_SENTINEL)
	return ws_adapter_enabled(opt_in, disable, sentinel)
}

// Claim the gate with HELLO through `exchange`. The caller has already
// established the transport (or injected a fake). Never raises above the
// evidence: only an accepted HELLO yields .Serving.
ws_adapter_claim :: proc(a: ^Ws_Adapter) {
	reply, ok := ws_adapter_raw(a, .Hello, WS_HELLO_NONCE, 0)
	if !ok {
		a.state = .Absent
		return
	}
	if reply.status != WS_STATUS_OK {
		a.state = .Refused
		a.status = reply.status
		a.owner = u32(reply.data0)
		return
	}
	a.state = .Serving
}

// Validate identity, version and command echo; a mismatched reply means the
// peer is not the gate we built against and is treated as transport failure.
ws_adapter_raw :: proc(a: ^Ws_Adapter, command: gate.Gate_Command, arg0, arg1: u64) -> (reply: gate.Gate_Reply, ok: bool) {
	if a.exchange == nil {return}
	reply, ok = a.exchange(a.user, command, arg0, arg1)
	if !ok {return}
	if reply.magic != gate.GATE_REPLY_MAGIC || reply.version != gate.GATE_VERSION || reply.command != u32(command) {
		return {}, false
	}
	return reply, true
}

// One gate call while serving. Transport failure or "not owner" latches
// .Lost; every other status is returned to the typed operation.
ws_adapter_call :: proc(a: ^Ws_Adapter, command: gate.Gate_Command, arg0, arg1: u64) -> (reply: gate.Gate_Reply, ok: bool) {
	if a.state != .Serving {return}
	reply, ok = ws_adapter_raw(a, command, arg0, arg1)
	if !ok || reply.status == WS_STATUS_NOT_OWNER {
		a.state = .Lost
		if ok {a.status = reply.status}
		return {}, false
	}
	if reply.status != WS_STATUS_OK {a.status = reply.status}
	return reply, true
}

// Stage a placement that the payload applies when `wid` next passes the
// transaction-table (space) channel. Busy/invalid → unhandled, still serving.
ws_space_place :: proc(a: ^Ws_Adapter, wid: u32, x, y: i32) -> (generation: u32, handled: bool) {
	if !gate.placement_coordinates_valid(u64(wid), i64(x), i64(y)) {return}
	reply, ok := ws_adapter_call(a, .SpacePlace, u64(wid), gate.placement_pack(x, y))
	if !ok || reply.status != WS_STATUS_OK {return}
	return u32(reply.data1), true
}

// SpaceApply: like SpacePlace but applied inside the claiming commit, with
// no Release round trip. For a single-threaded owner whose own (Dock)
// transaction is the trigger.
ws_space_apply :: proc(a: ^Ws_Adapter, wid: u32, x, y: i32) -> (generation: u32, handled: bool) {
	if !gate.placement_coordinates_valid(u64(wid), i64(x), i64(y)) {return}
	reply, ok := ws_adapter_call(a, .SpaceApply, u64(wid), gate.placement_pack(x, y))
	if !ok || reply.status != WS_STATUS_OK {return}
	return u32(reply.data1), true
}

// Synchronous transaction move (Dock Window_To_Space_Transaction). Returns
// "" when the commit returned; the gate applies staged placement inside it.
Ws_Space_Send :: #type proc(user: rawptr, target: u64, wid: u32, source: u64) -> string

Ws_Space_Move :: struct {
	moved:  bool, // the transaction move ran; caller must not move again
	placed: bool, // landing applied inside the move's commit
}

// Stage the landing, move through the gated transaction, then read the
// placement. Never leaves a hold armed: an unclaimed stage is released.
// Unhandled (moved=false) means the caller performs today's move.
ws_space_move :: proc(a: ^Ws_Adapter, wid: u32, target, source: u64, x, y: i32, send: Ws_Space_Send, user: rawptr) -> (result: Ws_Space_Move) {
	if a.state != .Serving || send == nil || target == 0 || target == source {return}
	generation, staged := ws_space_apply(a, wid, x, y)
	if !staged {return}
	if err := send(user, target, wid, source); err != "" {
		ws_release(a, generation)
		return
	}
	result.moved = true
	placement, ok := ws_placement_status(a)
	if ok && placement.generation == generation && placement.status == WS_STATUS_OK {
		result.placed = true
		return
	}
	// Not claimed inside the commit (or a different generation): cancel so
	// the hold cannot catch an unrelated later Space op for this window.
	ws_release(a, generation)
	return
}

Ws_Placement :: struct {
	status:     i32, // 0 applied, 6 pending, 8 idle/timed out
	generation: u32,
	x, y:       i32,
}

ws_placement_status :: proc(a: ^Ws_Adapter) -> (result: Ws_Placement, handled: bool) {
	reply, ok := ws_adapter_call(a, .PlacementStatus, 0, 0)
	if !ok {return}
	result.status = reply.status
	result.generation = u32(reply.data0)
	result.x, result.y = gate.placement_unpack(reply.data1)
	return result, true
}

Ws_Layout_Move :: struct {
	wid:  u32,
	x, y: i32,
}

// Stage a frame-atomic, position-only layout and arm it on `marker`'s next
// ordering. Any rejected step leaves the plan unsealed (never armed) and the
// caller applies the moves itself.
ws_layout_stage :: proc(a: ^Ws_Adapter, moves: []Ws_Layout_Move, marker: u32, budget_us: u64) -> (generation: u32, handled: bool) {
	if a.state != .Serving || len(moves) == 0 || len(moves) > gate.LAYOUT_LIMIT || marker == 0 || budget_us == 0 || budget_us > 8_000 {return}
	for move in moves {
		if move.wid == marker || !gate.placement_coordinates_valid(u64(move.wid), i64(move.x), i64(move.y)) {return}
	}
	reply, ok := ws_adapter_call(a, .LayoutBegin, 0, 0)
	if !ok || reply.status != WS_STATUS_OK {return}
	for move in moves {
		reply, ok = ws_adapter_call(a, .LayoutAdd, u64(move.wid), gate.placement_pack(move.x, move.y))
		if !ok || reply.status != WS_STATUS_OK {return}
	}
	reply, ok = ws_adapter_call(a, .LayoutArm, u64(marker), budget_us)
	if !ok || reply.status != WS_STATUS_OK {return}
	return u32(reply.data1), true
}

Ws_Layout_Result :: struct {
	status:     i32, // 0 applied, 6 pending, 8 idle/cancelled, other = partial failure
	generation: u32,
	applied:    u32,
	elapsed_us: u32,
}

ws_layout_status :: proc(a: ^Ws_Adapter) -> (result: Ws_Layout_Result, handled: bool) {
	reply, ok := ws_adapter_call(a, .LayoutStatus, 0, 0)
	if !ok {return}
	return {reply.status, u32(reply.data0), u32(reply.data1), u32(reply.data1 >> 32)}, true
}

// Release a hold by generation (0 = unconditional). Used to cancel a staged
// placement/layout the caller no longer wants.
ws_release :: proc(a: ^Ws_Adapter, generation: u32) -> bool {
	reply, ok := ws_adapter_call(a, .Release, u64(generation), 0)
	return ok && reply.status == WS_STATUS_OK
}

// Arm a once-only ordering receipt for `wid` (C2). 0 cancels.
ws_watch :: proc(a: ^Ws_Adapter, wid: u32) -> (generation: u32, handled: bool) {
	reply, ok := ws_adapter_call(a, .Watch, u64(wid), 0)
	if !ok || reply.status != WS_STATUS_OK {return}
	return u32(reply.data1), true
}

Ws_Receipt :: enum {
	Fired,
	Pending,
	Stale,
	Idle,
	Unknown,
}

ws_receipt_kind :: proc(status: i32) -> Ws_Receipt {
	switch status {
	case WS_STATUS_OK:
		return .Fired
	case WS_STATUS_BUSY:
		return .Pending
	case WS_STATUS_STALE:
		return .Stale
	case WS_STATUS_IDLE:
		return .Idle
	}
	return .Unknown
}

// Consume a fired receipt bound to `generation`. Unhandled means the caller
// must fall back to its own readback (today's AX polling).
ws_receipt :: proc(a: ^Ws_Adapter, generation: u32) -> (receipt: Ws_Receipt, handled: bool) {
	reply, ok := ws_adapter_call(a, .WatchStatus, u64(generation), 0)
	if !ok {return .Unknown, false}
	return ws_receipt_kind(reply.status), true
}

// ------------------------------------------------------------------------
// Mach transport
// ------------------------------------------------------------------------

Ws_Mach_Buffer :: struct #align (16) {
	bytes: [128]u8,
}

ws_mach_exchange :: proc(user: rawptr, command: gate.Gate_Command, arg0, arg1: u64) -> (reply: gate.Gate_Reply, ok: bool) {
	m := (^Ws_Mach)(user)
	if m == nil || m.service == 0 {return}
	port_type: u32
	if gate.gate_mach_port_type(m.task, m.service, &port_type) != 0 || port_type & gate.MACH_PORT_TYPE_SEND == 0 {return}
	msg: Ws_Mach_Buffer
	n, packed := gate.gate_pack_request(msg.bytes[:], m.service, 1, command, arg0, arg1)
	if !packed {return}
	reply_port: u32
	if gate.gate_mach_port_allocate(m.task, gate.MACH_PORT_RIGHT_RECEIVE, &reply_port) != 0 {return}
	defer gate.gate_mach_port_destroy(m.task, reply_port)
	if !gate.gate_store_u32(msg.bytes[:], 12, reply_port) {return}
	options := u32(gate.MACH_MSG_SEND) | u32(gate.MACH_MSG_RECEIVE) | u32(gate.MACH_RCV_TIMEOUT)
	// A hold serializes all transaction dispatch, so production holds are
	// frame-scale; 250 ms bounds a stuck gate.
	if gate.gate_mach_msg(&msg.bytes[0], options, u32(n), len(msg.bytes), reply_port, 250, 0) != 0 {return}
	return gate.gate_unpack_reply(msg.bytes[:])
}

// Session-rendezvous fallback, as in the experiment gate client. The root
// helper delivers the right this way when it cannot obtain this task's port
// (task_for_pid returns 5 for the client on a 26B123 M1 Max). It polls the
// rendezvous for 10 s after claiming request.<pid>, so registering after the
// file handoff times out still meets it. Registration fails harmlessly when
// another process holds the name.
WS_RENDEZVOUS_TIMEOUT_MS :: 3000

ws_mach_rendezvous :: proc(task: u32, timeout_ms: u32) -> (service: u32, ok: bool) {
	bootstrap, bootstrap_ok := gate.gate_process_bootstrap_port()
	if !bootstrap_ok {return}
	rendezvous: u32
	if gate.gate_mach_port_allocate(task, gate.MACH_PORT_RIGHT_RECEIVE, &rendezvous) != 0 {return}
	defer gate.gate_mach_port_destroy(task, rendezvous)
	if gate.gate_bootstrap_register(bootstrap, gate.GATE_RENDEZVOUS_NAME, rendezvous) != 0 {return}
	message: Ws_Mach_Buffer
	options := u32(gate.MACH_MSG_RECEIVE) | u32(gate.MACH_RCV_TIMEOUT)
	size := u32(len(message.bytes))
	if gate.gate_mach_msg(&message.bytes[0], options, 0, size, rendezvous, timeout_ms, 0) != 0 {return}
	return gate.gate_handshake_send_right(message.bytes[:])
}

// Task-port handoff: publish request.<pid>; the root helper inserts a send
// right and answers response.<pid> with "<pid> <name>". Bounded by `timeout`.
ws_mach_handoff :: proc(task: u32, timeout: time.Duration) -> (service: u32, ok: bool) {
	pid := posix.getpid()
	request_path := fmt.tprintf("%s.%d", gate.GATE_HANDOFF_REQUEST_PATH, pid)
	response_path := fmt.tprintf("%s.%d", gate.GATE_HANDOFF_RESPONSE_PATH, pid)
	defer posix.unlink(strings.unsafe_string_to_cstring(request_path))
	line := fmt.tprintf("%d\n", pid)
	fd := posix.open(strings.unsafe_string_to_cstring(request_path), {.WRONLY, .CREAT, .TRUNC, .NOFOLLOW}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if fd < 0 {return}
	written := posix.write(fd, raw_data(line), uint(len(line)))
	posix.close(fd)
	if written != len(line) {return}
	deadline := time.time_add(time.now(), timeout)
	for time.diff(time.now(), deadline) > 0 {
		time.sleep(50 * time.Millisecond)
		buffer: [64]u8
		rfd := posix.open(strings.unsafe_string_to_cstring(response_path), {.NOFOLLOW})
		if rfd < 0 {continue}
		info: posix.stat_t
		valid := posix.fstat(rfd, &info) == nil && posix.S_ISREG(info.st_mode)
		count := posix.read(rfd, &buffer[0], len(buffer))
		posix.close(rfd)
		if !valid || count <= 0 {continue}
		name, parsed := ws_handoff_parse(string(buffer[:count]), u32(pid))
		if !parsed {continue}
		port_type: u32
		if gate.gate_mach_port_type(task, name, &port_type) != 0 || port_type & gate.MACH_PORT_TYPE_SEND == 0 {continue}
		return name, true
	}
	return
}

// "<pid> <port-name>[...]": the pid must be ours so a stale response for a
// recycled per-pid channel cannot hand us someone else's right.
ws_handoff_parse :: proc(line: string, pid: u32) -> (name: u32, ok: bool) {
	fields := strings.fields(line, context.temp_allocator)
	if len(fields) < 2 {return}
	owner, owner_ok := strconv.parse_u64(fields[0], 10)
	port, port_ok := strconv.parse_u64(fields[1], 10)
	if !owner_ok || !port_ok || owner != u64(pid) || port == 0 || port > u64(max(u32)) {return}
	return u32(port), true
}

// Daemon entry point. Bounded; on any failure the adapter stays below
// .Serving and every typed operation returns unhandled.
ws_adapter_open :: proc(a: ^Ws_Adapter, enabled: bool, timeout: time.Duration = 2 * time.Second) {
	a^ = {}
	if !enabled {
		a.state = .Disabled
		return
	}
	if !ws_tgate_present() {
		a.state = .Absent
		return
	}
	task := gate.gate_mach_task_self()
	service, ok := ws_mach_handoff(task, timeout)
	if !ok {
		service, ok = ws_mach_rendezvous(task, WS_RENDEZVOUS_TIMEOUT_MS)
	}
	if !ok {
		a.state = .Absent
		return
	}
	ws_adapter_connect(a, task, service)
}

// Takes ownership of `service` (a send right to the gate) and claims it.
ws_adapter_connect :: proc(a: ^Ws_Adapter, task, service: u32) {
	a.mach.task = task
	a.mach.service = service
	a.exchange = ws_mach_exchange
	a.user = &a.mach
	ws_adapter_claim(a)
}

ws_adapter_close :: proc(a: ^Ws_Adapter) {
	if a.state == .Serving {ws_focus_cancel(a)}
	if a.marker.window != 0 {
		SLSReleaseWindow(a.marker.connection, a.marker.window)
	}
	if a.mach.service != 0 {
		gate.gate_mach_port_deallocate(a.mach.task, a.mach.service)
	}
	a^ = {state = .Disabled}
}

ws_adapter_describe :: proc(a: ^Ws_Adapter) -> string {
	switch a.state {
	case .Disabled:
		return "WindowServer adapter disabled; using native paths"
	case .Absent:
		return "WindowServer adapter: no gate connection (payload absent or no handoff); using native paths"
	case .Refused:
		return fmt.tprintf("WindowServer adapter refused (status %d, owner pid %d); using native paths", a.status, a.owner)
	case .Serving:
		return "WindowServer adapter serving"
	case .Lost:
		return fmt.tprintf("WindowServer adapter lost (status %d); using native paths", a.status)
	}
	return ""
}

// Live probe of the daemon's gated Space move without a window manager
// session (no Accessibility needed): same ws_space_move + Dock transaction
// path perform_native uses. Exit 0 placed, 3 moved unplaced, 4 fell back
// (adapter not serving or move not handled), 2 usage.
ws_space_move_cli :: proc(args: []string) -> int {
	wid, wid_ok := strconv.parse_u64(args[0])
	space, space_ok := strconv.parse_u64(args[1])
	x, x_ok := strconv.parse_i64(args[2])
	y, y_ok := strconv.parse_i64(args[3])
	if !wid_ok || !space_ok || !x_ok || !y_ok || space == 0 || !gate.placement_coordinates_valid(wid, x, y) {
		fmt.eprintln("--ws-space-move: invalid arguments")
		return 2
	}
	state: State
	state.connection = SLSMainConnectionID()
	a: Ws_Adapter
	ws_adapter_open(&a, ws_adapter_env_enabled())
	defer ws_adapter_close(&a)
	fmt.println(ws_adapter_describe(&a))
	source := window_space(&state, u32(wid))
	start := time.now()
	move := ws_space_move(&a, u32(wid), space, source, i32(x), i32(y), addition_space_transaction, nil)
	fmt.printf(
		"source=%d target=%d moved=%v placed=%v elapsed_ms=%.3f state=%s\n",
		source, space, move.moved, move.placed,
		time.duration_milliseconds(time.since(start)), ws_adapter_state_name(a.state),
	)
	if move.placed {return 0}
	if move.moved {return 3}
	return 4
}

// ------------------------------------------------------------------------
// Engine hooks (C1 layout batch, C2 focus receipt)
// ------------------------------------------------------------------------

// Created like motion.odin surface_create, minus the drawing context: a raw
// SkyLight window at alpha 0. Proven as a C1 trigger (c1c2-foreign-20261105).
ws_marker :: proc(a: ^Ws_Adapter, connection: i32) -> u32 {
	if a.marker.window != 0 {return a.marker.window}
	frame := Rect{0, 0, 1, 1}
	region: Ref
	if CGSNewRegionWithRect(&frame, &region) != 0 || region == nil {return 0}
	defer CFRelease(region)
	empty := CGRegionCreateEmptyRegion()
	if empty == nil {return 0}
	defer CFRelease(empty)
	tags: u64
	id: u32
	if SLSNewWindowWithOpaqueShapeAndContext(connection, 2, region, empty, 0, &tags, 0, 0, 64, &id, nil) != 0 || id == 0 {
		return 0
	}
	SLSSetWindowAlpha(connection, id, 0)
	a.marker = {connection, id}
	return id
}

// Layout_Batch for the daemon (user = ^State). Stage, order the marker in
// (SLSOrderWindow returns after WindowServer ran the claim), read the result.
// An unclaimed plan is released so it cannot fire on a later order-in.
ws_layout_batch :: proc(user: rawptr, moves: []Layout_Move) -> bool {
	state := (^State)(user)
	a := &state.ws
	if a.state != .Serving || len(moves) == 0 || len(moves) > LAYOUT_BATCH_LIMIT {return false}
	for move in moves {
		if _, animating := state.animations[move.window]; animating {return false}
	}
	marker := ws_marker(a, state.connection)
	if marker == 0 {return false}
	items := make([]Ws_Layout_Move, len(moves), context.temp_allocator)
	for move, i in moves {
		items[i] = {move.window, i32(math.round(move.x)), i32(math.round(move.y))}
	}
	applied := ws_layout_run(a, items, marker, state.connection)
	motion_trace_record(&state.manager.motion_trace, {kind = applied ? "ws-layout-batch-applied" : "ws-layout-batch-fallback", window = moves[0].window})
	return applied
}

Ws_Order :: #type proc "c" (cid: i32, window: u32, order: i32, relative: u32) -> i32

ws_layout_run :: proc(a: ^Ws_Adapter, items: []Ws_Layout_Move, marker: u32, connection: i32, order: Ws_Order = SLSOrderWindow) -> bool {
	generation, staged := ws_layout_stage(a, items, marker, 8_000)
	if !staged {return false}
	order(connection, marker, 1, 0)
	order(connection, marker, 0, 0)
	result, ok := ws_layout_status(a)
	if ok && result.generation == generation && result.status == WS_STATUS_OK && result.applied == u32(len(items)) {
		return true
	}
	if ok && result.status == WS_STATUS_BUSY {ws_release(a, generation)}
	return false
}

// C2: after a raise whose native status was an error, wait briefly for the
// ordering receipt bound to `generation`. Fired → the window was ordered in.
ws_receipt_wait :: proc(a: ^Ws_Adapter, generation: u32, timeout: time.Duration) -> bool {
	deadline := time.time_add(time.now(), timeout)
	for {
		receipt, handled := ws_receipt(a, generation)
		if !handled {return false}
		if receipt == .Fired {return true}
		if receipt != .Pending || time.diff(time.now(), deadline) <= 0 {return false}
		time.sleep(5 * time.Millisecond)
	}
}

ws_focus_pending :: proc(a: ^Ws_Adapter, generation, window: u32, now: time.Time) {
	a.focus = {generation, window, now}
}

// Drop an unresolved focus receipt; returns its window (0 when none).
ws_focus_cancel :: proc(a: ^Ws_Adapter) -> (window: u32) {
	if a.focus.generation == 0 {return 0}
	window = a.focus.window
	a.focus = {}
	ws_watch(a, 0)
	return
}

// Non-blocking: resolved once the receipt fired, the gate stopped answering
// Pending, or the window elapsed. Unresolved receipts stay armed.
ws_focus_tick :: proc(a: ^Ws_Adapter, now: time.Time) -> (window: u32, outcome: Ws_Receipt, waited: time.Duration, resolved: bool) {
	f := a.focus
	if f.generation == 0 {return}
	waited = time.diff(f.armed, now)
	receipt, handled := ws_receipt(a, f.generation)
	if !handled {receipt = .Unknown}
	if receipt == .Pending && waited < WS_FOCUS_RECEIPT_WINDOW {return}
	a.focus = {}
	ws_watch(a, 0)
	return f.window, receipt, waited, true
}

// D2: ask the payload to write its event-ring snapshot (WS_RING_PATH).
ws_dump :: proc(a: ^Ws_Adapter) -> (calls: u64, ok: bool) {
	reply, sent := ws_adapter_call(a, .Dump, 0, 0)
	if !sent || reply.status != WS_STATUS_OK {return}
	return reply.data0, true
}

// Daemon side of `debug ws status|dump`: the daemon may own the gate, so
// diagnostics go through it instead of a second claimant.
ws_debug :: proc(user: rawptr, dump: bool) -> string {
	state := (^State)(user)
	text := ws_adapter_describe(&state.ws)
	if !dump {return text}
	if calls, ok := ws_dump(&state.ws); ok {
		return fmt.tprintf("%s; calls=%d ring=%s", text, calls, WS_RING_PATH)
	}
	return fmt.tprintf("%s; ring unavailable", text)
}
