package shoji

import "core:crypto/sha2"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:time"
import dock "dock"
import health "health"
import ipc "ipc"
import layout "layout"
import service "service"
import support "support"
import attach "windowserver/attach"
import gate "windowserver/gate"

// WindowServer gate adapter (C4): Shoji's own direct-Mach client. The daemon
// connects it only through `--ws-attach`, opted in by `windowserver_gate on`.
// Every operation returns `handled`, and an
// unhandled result means "do today's behavior".
// Any transport failure, identity mismatch or ownership loss latches the
// adapter to .Lost so later calls short-circuit to the fallback path. The
// daemon's default paths never require the adapter, so Shoji works unchanged
// when the payload is absent, disabled or refuses Shoji.

WS_TGATE_STATUS_PATH :: gate.TGATE_STATUS_PATH
WS_HELLO_NONCE :: 0x53484f4a

ws_tgate_present :: proc() -> bool {
	fd := posix.open(WS_TGATE_STATUS_PATH, {.NOFOLLOW})
	if fd < 0 {
		return false
	}
	defer posix.close(fd)
	buffer: [8]u8
	n := posix.read(fd, &buffer[0], len(buffer))
	return n == len(buffer) && string(buffer[:]) == "WSOBTGAT"
}

// ------------------------------------------------------------------------
// Adapter
// ------------------------------------------------------------------------

Ws_Adapter_State :: enum {
	Disabled, // not attached (gate off, or kill switch present)
	Absent, // no payload, or no send right handed off
	Refused, // payload answered but did not accept Shoji as owner
	Serving, // Shoji owns the gate
	Lost, // was serving; transport or ownership failed (latched)
}

// Transport seam: the real one is Mach, tests inject replies.
Ws_Exchange :: #type proc(
	user: rawptr,
	command: gate.Gate_Command,
	arg0, arg1: u64,
	items: []gate.Layout_Item,
) -> (
	gate.Gate_Reply,
	bool,
)

Ws_Adapter :: struct {
	state:          Ws_Adapter_State,
	exchange:       Ws_Exchange,
	user:           rawptr,
	owner:          u32, // owner pid reported by a refusing gate
	status:         i32, // last nonzero gate status
	mach:           Ws_Mach,
	marker:         Ws_Marker,
	focus:          Ws_Focus_Receipt,
	// From Capabilities after the claim; zero means a payload that predates
	// it (one LayoutAdd per item, GATE_LEGACY_LAYOUT_LIMIT items).
	features:       u64,
	layout_limit:   int,
	// Set when the trailer names this build's SkyLight UUID and gated ops.
	// A payload that predates the trailer leaves this false and is still used.
	identity_ok:    bool,
	build_uuid:     [16]u8,
	gated_ops:      [gate.GATE_OP_REPORT_MAX]u32,
	gated_op_count: int,
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
ws_adapter_raw :: proc(
	a: ^Ws_Adapter,
	command: gate.Gate_Command,
	arg0, arg1: u64,
	items: []gate.Layout_Item = nil,
) -> (
	reply: gate.Gate_Reply,
	ok: bool,
) {
	if a.exchange == nil {
		return
	}
	reply, ok = a.exchange(a.user, command, arg0, arg1, items)
	if !ok {
		return
	}
	if reply.magic != gate.GATE_REPLY_MAGIC ||
	   reply.version != gate.GATE_VERSION ||
	   reply.command != u32(command) {
		return {}, false
	}
	return reply, true
}

// One gate call while serving. Transport failure or "not owner" latches
// .Lost; every other status is returned to the typed operation.
ws_adapter_call :: proc(
	a: ^Ws_Adapter,
	command: gate.Gate_Command,
	arg0, arg1: u64,
	items: []gate.Layout_Item = nil,
) -> (
	reply: gate.Gate_Reply,
	ok: bool,
) {
	if a.state != .Serving {
		return
	}
	reply, ok = ws_adapter_raw(a, command, arg0, arg1, items)
	if !ok || reply.status == WS_STATUS_NOT_OWNER {
		a.state = .Lost
		if ok {
			a.status = reply.status
		}
		return {}, false
	}
	if reply.status != WS_STATUS_OK {
		a.status = reply.status
	}
	return reply, true
}

// Arm PresentApply when this payload advertises it. A payload that does not
// is left unstaged; the Dock transaction still runs, just ungated.
ws_present_stage :: proc(
	a: ^Ws_Adapter,
	wid: u32,
	alpha, event, transform, clip: bool,
) -> (
	generation: u32,
	handled: bool,
) {
	if a.state != .Serving || wid == 0 || a.features & gate.GATE_FEATURE_PRESENT == 0 {
		return
	}
	mask := gate.present_stage_mask(alpha, event, transform, clip)
	if mask == 0 {
		return
	}
	reply, ok := ws_adapter_call(a, .PresentApply, u64(wid), u64(mask))
	if !ok || reply.status != WS_STATUS_OK {
		return
	}
	return u32(reply.data1), true
}

// Stage the presentation, run `send` (the synchronous Dock transaction), then
// release the hold. The shim finishes a claimed op itself; this release frees
// a hold that nothing claimed, which would otherwise block layout. `staged`
// is false when the payload has no PresentApply; the send still runs.
ws_present :: proc(
	a: ^Ws_Adapter,
	wid: u32,
	alpha, event, transform, clip: bool,
	send: proc() -> string,
) -> (
	staged: bool,
	err: string,
) {
	if send == nil || wid == 0 || (!alpha && !event && !transform && !clip) {
		return false, "invalid presentation"
	}
	generation, armed := ws_present_stage(a, wid, alpha, event, transform, clip)
	staged = armed
	err = send()
	if staged {
		ws_release(a, generation)
	}
	return staged, err
}

// Stage a placement that the payload applies when `wid` next passes the
// transaction-table (space) channel. Busy/invalid → unhandled, still serving.
ws_space_place :: proc(a: ^Ws_Adapter, wid: u32, x, y: i32) -> (generation: u32, handled: bool) {
	if !gate.placement_coordinates_valid(u64(wid), i64(x), i64(y)) {
		return
	}
	reply, ok := ws_adapter_call(a, .SpacePlace, u64(wid), gate.placement_pack(x, y))
	if !ok || reply.status != WS_STATUS_OK {
		return
	}
	return u32(reply.data1), true
}

// SpaceApply: like SpacePlace but applied inside the claiming commit, with
// no Release round trip. For a single-threaded owner whose own (Dock)
// transaction is the trigger.
ws_space_apply :: proc(a: ^Ws_Adapter, wid: u32, x, y: i32) -> (generation: u32, handled: bool) {
	if !gate.placement_coordinates_valid(u64(wid), i64(x), i64(y)) {
		return
	}
	reply, ok := ws_adapter_call(a, .SpaceApply, u64(wid), gate.placement_pack(x, y))
	if !ok || reply.status != WS_STATUS_OK {
		return
	}
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
ws_space_move :: proc(
	a: ^Ws_Adapter,
	wid: u32,
	target, source: u64,
	x, y: i32,
	send: Ws_Space_Send,
	user: rawptr,
) -> (
	result: Ws_Space_Move,
) {
	if a.state != .Serving || send == nil || target == 0 || target == source {
		return
	}
	generation, staged := ws_space_apply(a, wid, x, y)
	if !staged {
		return
	}
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
	if !ok {
		return
	}
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
ws_layout_stage :: proc(
	a: ^Ws_Adapter,
	moves: []Ws_Layout_Move,
	marker: u32,
	budget_us: u64,
) -> (
	generation: u32,
	handled: bool,
) {
	if a.state != .Serving ||
	   len(moves) == 0 ||
	   len(moves) > ws_layout_limit(a) ||
	   marker == 0 ||
	   budget_us == 0 ||
	   budget_us > 8_000 {
		return
	}
	for move in moves {
		if move.wid == marker ||
		   !gate.placement_coordinates_valid(u64(move.wid), i64(move.x), i64(move.y)) {
			return
		}
	}
	if a.features & gate.GATE_FEATURE_LAYOUT_SUBMIT != 0 {
		items: [gate.LAYOUT_LIMIT]gate.Layout_Item
		for move, index in moves {items[index] = {move.wid, move.x, move.y}}
		reply, ok := ws_adapter_call(a, .LayoutSubmit, u64(marker), budget_us, items[:len(moves)])
		if !ok || reply.status != WS_STATUS_OK {
			return
		}
		return u32(reply.data1), true
	}
	reply, ok := ws_adapter_call(a, .LayoutBegin, 0, 0)
	if !ok || reply.status != WS_STATUS_OK {
		return
	}
	for move in moves {
		reply, ok = ws_adapter_call(
			a,
			.LayoutAdd,
			u64(move.wid),
			gate.placement_pack(move.x, move.y),
		)
		if !ok || reply.status != WS_STATUS_OK {
			return
		}
	}
	reply, ok = ws_adapter_call(a, .LayoutArm, u64(marker), budget_us)
	if !ok || reply.status != WS_STATUS_OK {
		return
	}
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
	if !ok {
		return
	}
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
	if !ok || reply.status != WS_STATUS_OK {
		return
	}
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
	if !ok {
		return .Unknown, false
	}
	return ws_receipt_kind(reply.status), true
}

// ------------------------------------------------------------------------
// Mach transport
// ------------------------------------------------------------------------

Ws_Mach_Buffer :: struct #align (16) {
	bytes: [gate.GATE_RECEIVE_BUFFER_SIZE]u8,
}

ws_mach_exchange :: proc(
	user: rawptr,
	command: gate.Gate_Command,
	arg0, arg1: u64,
	items: []gate.Layout_Item,
) -> (
	reply: gate.Gate_Reply,
	ok: bool,
) {
	m := (^Ws_Mach)(user)
	if m == nil || m.service == 0 {
		return
	}
	port_type: u32
	if gate.gate_mach_port_type(m.task, m.service, &port_type) != 0 ||
	   port_type & gate.MACH_PORT_TYPE_SEND == 0 {
		return
	}
	msg: Ws_Mach_Buffer
	n, packed := gate.gate_pack_request(msg.bytes[:], m.service, 1, command, arg0, arg1, items)
	if !packed {
		return
	}
	reply_port: u32
	if gate.gate_mach_port_allocate(m.task, gate.MACH_PORT_RIGHT_RECEIVE, &reply_port) != 0 {
		return
	}
	defer gate.gate_mach_port_destroy(m.task, reply_port)
	if !gate.gate_store_u32(msg.bytes[:], 12, reply_port) {
		return
	}
	options := u32(gate.MACH_MSG_SEND) | u32(gate.MACH_MSG_RECEIVE) | u32(gate.MACH_RCV_TIMEOUT)
	// A hold serializes all transaction dispatch, so production holds are
	// frame-scale; 250 ms bounds a stuck gate.
	if gate.gate_mach_msg(&msg.bytes[0], options, u32(n), len(msg.bytes), reply_port, 250, 0) !=
	   0 {
		return
	}
	return gate.gate_unpack_reply(msg.bytes[:])
}

// Takes ownership of `service` (a send right to the gate) and claims it.
ws_adapter_connect :: proc(a: ^Ws_Adapter, task, service: u32) {
	a.mach.task = task
	a.mach.service = service
	a.exchange = ws_mach_exchange
	a.user = &a.mach
	ws_adapter_claim(a)
	ws_adapter_capabilities(a)
}

// Ask a serving gate what it supports. A payload that predates the command
// answers status 1; that, or any failure, keeps the legacy protocol. It does
// not mark the adapter Lost or record a status: legacy is a normal state.
// A trailer whose SkyLight UUID or gated-op set is not this build turns the
// gate features off. Dock capabilities stay on the Dock handshake; a caller
// that needs both (a transactional Space move) checks that handshake itself.
ws_adapter_capabilities :: proc(a: ^Ws_Adapter) {
	a.features, a.layout_limit = 0, 0
	a.identity_ok = false
	a.gated_op_count = 0
	if a.state != .Serving {
		return
	}
	reply, ok := ws_adapter_raw(a, .Capabilities, 0, 0)
	if !ok || reply.status != WS_STATUS_OK {
		return
	}
	// The payload reports the SkyLight UUID it validated in the loaded image;
	// it must name a build this release supports.
	_, known := gate.target_by_uuid(reply.uuid)
	if reply.rejected ||
	   (reply.identity && (!known || !gate.gated_ops_match(reply.ops[:reply.op_count]))) {
		return
	}
	if reply.identity {
		a.build_uuid = reply.uuid
		a.gated_op_count = int(reply.op_count)
		for i in 0 ..< reply.op_count {a.gated_ops[i] = reply.ops[i]}
		a.identity_ok = true
	}
	a.features = reply.data0
	a.layout_limit = int(min(reply.data1, u64(gate.LAYOUT_LIMIT)))
}

// Items one staged layout may hold with this payload.
ws_layout_limit :: proc(a: ^Ws_Adapter) -> int {
	return a.layout_limit > 0 ? a.layout_limit : gate.GATE_LEGACY_LAYOUT_LIMIT
}

ws_adapter_close :: proc(a: ^Ws_Adapter) {
	if a.state == .Serving {
		ws_focus_cancel(a)
	}
	if a.marker.window != 0 {
		SLSReleaseWindow(a.marker.connection, a.marker.window)
	}
	if a.mach.service != 0 {
		gate.gate_mach_port_deallocate(a.mach.task, a.mach.service)
	}
	a^ = {
		state = .Disabled,
	}
}

ws_adapter_describe :: proc(a: ^Ws_Adapter) -> string {
	switch a.state {
	case .Disabled:
		return "WindowServer adapter disabled; using native paths"
	case .Absent:
		return(
			"WindowServer adapter: no gate connection (payload absent or not attached); using native paths" \
		)
	case .Refused:
		return fmt.tprintf(
			"WindowServer adapter refused (status %d, owner pid %d); using native paths",
			a.status,
			a.owner,
		)
	case .Serving:
		protocol :=
			a.features & gate.GATE_FEATURE_LAYOUT_SUBMIT != 0 ? "layout submit" : "legacy layout"
		identity := a.identity_ok ? "identity ok" : "identity unchecked"
		return fmt.tprintf(
			"WindowServer adapter serving (%s, %d items, %s)",
			protocol,
			ws_layout_limit(a),
			identity,
		)
	case .Lost:
		return fmt.tprintf("WindowServer adapter lost (status %d); using native paths", a.status)
	}
	return ""
}

// ------------------------------------------------------------------------
// Engine hooks (C1 layout batch, C2 focus receipt)
// ------------------------------------------------------------------------

// Created like present.odin surface_create, minus the drawing context: a raw
// SkyLight window at alpha 0. Proven as a C1 trigger (c1c2-foreign-20261105).
ws_marker :: proc(a: ^Ws_Adapter, connection: i32) -> u32 {
	if a.marker.window != 0 {
		return a.marker.window
	}
	frame := Rect{0, 0, 1, 1}
	region: Ref
	if CGSNewRegionWithRect(&frame, &region) != 0 || region == nil {
		return 0
	}
	defer CFRelease(region)
	empty := CGRegionCreateEmptyRegion()
	if empty == nil {
		return 0
	}
	defer CFRelease(empty)
	tags: u64
	id: u32
	if SLSNewWindowWithOpaqueShapeAndContext(
		   connection,
		   2,
		   region,
		   empty,
		   0,
		   &tags,
		   0,
		   0,
		   64,
		   &id,
		   nil,
	   ) !=
		   0 ||
	   id == 0 {
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
	if a.state != .Serving || len(moves) == 0 || len(moves) > ws_layout_limit(a) {
		return false
	}
	for move in moves {
		if _, animating := state.animations[move.window]; animating {
			return false
		}
	}
	marker := ws_marker(a, state.connection)
	if marker == 0 {
		return false
	}
	items := make([]Ws_Layout_Move, len(moves), context.temp_allocator)
	for move, i in moves {
		items[i] = {move.window, i32(math.round(move.x)), i32(math.round(move.y))}
	}
	started := time.tick_now()
	applied := ws_layout_run(a, items, marker, state.connection)
	motion_trace_record(
		&state.manager.motion_trace,
		{
			kind = applied ? "ws-layout-batch-applied" : "ws-layout-batch-fallback",
			window = moves[0].window,
			value = f64(len(moves)),
			duration_ms = f64(time.tick_since(started)) / 1e6,
		},
	)
	return applied
}

// The Dock send does not close over the request: Odin nested procs do not
// capture locals. Clip sync calls this only when the rect changes.
@(thread_local)
present_req: dock.Present_Request

viewport_present_send :: proc() -> string {
	return addition_present(present_req)
}

viewport_present :: proc(user: rawptr, req: dock.Present_Request) -> string {
	state := (^State)(user)
	present_req = req
	_, err := ws_present(
		&state.ws,
		req.window,
		false,
		req.mask & dock.PRESENT_EVENT != 0,
		false,
		req.mask & dock.PRESENT_CLIP != 0,
		viewport_present_send,
	)
	return err
}

Ws_Order :: #type proc "c" (cid: i32, window: u32, order: i32, relative: u32) -> i32

ws_layout_run :: proc(
	a: ^Ws_Adapter,
	items: []Ws_Layout_Move,
	marker: u32,
	connection: i32,
	order: Ws_Order = SLSOrderWindow,
) -> bool {
	generation, staged := ws_layout_stage(a, items, marker, 8_000)
	if !staged {
		return false
	}
	order(connection, marker, 1, 0)
	order(connection, marker, 0, 0)
	result, ok := ws_layout_status(a)
	if ok &&
	   result.generation == generation &&
	   result.status == WS_STATUS_OK &&
	   result.applied == u32(len(items)) {
		return true
	}
	if ok && result.status == WS_STATUS_BUSY {
		ws_release(a, generation)
	}
	return false
}

// C2: after a raise whose native status was an error, wait briefly for the
// ordering receipt bound to `generation`. Fired → the window was ordered in.
ws_receipt_wait :: proc(a: ^Ws_Adapter, generation: u32, timeout: time.Duration) -> bool {
	deadline := time.time_add(time.now(), timeout)
	for {
		receipt, handled := ws_receipt(a, generation)
		if !handled {
			return false
		}
		if receipt == .Fired {
			return true
		}
		if receipt != .Pending || time.diff(time.now(), deadline) <= 0 {
			return false
		}
		time.sleep(5 * time.Millisecond)
	}
}

ws_focus_pending :: proc(a: ^Ws_Adapter, generation, window: u32, now: time.Time) {
	a.focus = {generation, window, now}
}

// Drop an unresolved focus receipt; returns its window (0 when none).
ws_focus_cancel :: proc(a: ^Ws_Adapter) -> (window: u32) {
	if a.focus.generation == 0 {
		return 0
	}
	window = a.focus.window
	a.focus = {}
	ws_watch(a, 0)
	return
}

// Non-blocking: resolved once the receipt fired, the gate stopped answering
// Pending, or the window elapsed. Unresolved receipts stay armed.
ws_focus_tick :: proc(
	a: ^Ws_Adapter,
	now: time.Time,
) -> (
	window: u32,
	outcome: Ws_Receipt,
	waited: time.Duration,
	resolved: bool,
) {
	f := a.focus
	if f.generation == 0 {
		return
	}
	waited = time.diff(f.armed, now)
	receipt, handled := ws_receipt(a, f.generation)
	if !handled {
		receipt = .Unknown
	}
	if receipt == .Pending && waited < WS_FOCUS_RECEIPT_WINDOW {
		return
	}
	a.focus = {}
	ws_watch(a, 0)
	return f.window, receipt, waited, true
}

// D2: ask the payload to write its event-ring snapshot (WS_RING_PATH).
ws_dump :: proc(a: ^Ws_Adapter) -> (calls: u64, ok: bool) {
	reply, sent := ws_adapter_call(a, .Dump, 0, 0)
	if !sent || reply.status != WS_STATUS_OK {
		return
	}
	return reply.data0, true
}

// Daemon side of `debug ws status|dump`: the daemon may own the gate, so
// diagnostics go through it instead of a second claimant.
ws_debug :: proc(user: rawptr, dump: bool) -> string {
	state := (^State)(user)
	text := ws_adapter_describe(&state.ws)
	if !dump {
		return text
	}
	if calls, ok := ws_dump(&state.ws); ok {
		return fmt.tprintf("%s; calls=%d ring=%s", text, calls, WS_RING_PATH)
	}
	return fmt.tprintf("%s; ring unavailable", text)
}

// Daemon side of the WindowServer gate. `config windowserver_gate on`
// (normally from shojirc) only records the request; the main loop then runs
// `sudo -n shoji --ws-attach` in the background and receives the gate's send
// right on the session rendezvous, so the config run is never blocked.
//
// Lifetime: the rendezvous receive right is registered on the first attempt
// and kept until shutdown. A WindowServer restart ends the login session and
// with it this daemon, so a served gate is never re-attached in place.


WS_ATTACH_ATTEMPTS :: 5
WS_ATTACH_RETRY_FIRST :: 2 * time.Second
WS_ATTACH_RETRY_MAX :: 30 * time.Second
// Covers injection (≤5 s), delivery (≤3 s) and sudo itself.
WS_ATTACH_CHILD_LIMIT :: 15 * time.Second

Ws_Attach_State :: enum {
	Off,
	Waiting, // requested; next attempt pending
	Attaching, // child running
	Serving,
	Failed, // attempts exhausted or refused; `config windowserver_gate on` retries
}

Ws_Attach_Runtime :: struct {
	ws:           ^Ws_Adapter,
	manager:      ^Manager,
	state:        Ws_Attach_State,
	child:        i32,
	child_start:  time.Time,
	killed:       bool,
	output:       health.Output_Tail,
	output_fd:    i32,
	output_open:  bool,
	rendezvous:   u32,
	attempts:     u32,
	retry_delay:  time.Duration,
	next_attempt: time.Time,
	cause:        health.Bounded_Text(health.HEALTH_TEXT_BYTES),
	failed_event: bool, // Failed transition not yet notified.
}

Ws_Attach_Outcome :: enum {
	Connected,
	Retry,
	Give_Up,
}

ws_attach_runtime_start :: proc(r: ^Ws_Attach_Runtime, adapter: ^Ws_Adapter, m: ^Manager) {
	r^ = {
		ws        = adapter,
		manager   = m,
		output_fd = -1,
	}
	m.ws_gate_control = ws_attach_control
	m.ws_gate_user = r
}

ws_attach_runtime_stop :: proc(r: ^Ws_Attach_Runtime) {
	if r.child != 0 {
		posix.kill(posix.pid_t(r.child), .SIGKILL)
	}
	ws_attach_close_output(r)
	if r.rendezvous != 0 {
		gate.gate_mach_port_destroy(gate.gate_mach_task_self(), r.rendezvous)
		r.rendezvous = 0
	}
}

ws_attach_state_name :: proc(state: Ws_Attach_State) -> string {
	switch state {
	case .Off:
		return "off"
	case .Waiting:
		return "waiting"
	case .Attaching:
		return "attaching"
	case .Serving:
		return "serving"
	case .Failed:
		return "failed"
	}
	return "off"
}

ws_attach_control :: proc(user: rawptr, value: string) -> Response {
	r := (^Ws_Attach_Runtime)(user)
	switch value {
	case "":
		return success(ws_attach_state_name(r.state))
	case "on":
		if r.state == .Off || r.state == .Failed {
			r.state = .Waiting
			r.attempts, r.retry_delay, r.next_attempt = 0, 0, {}
			health.bounded_set(&r.cause, "")
		}
	case "off":
		ws_attach_disconnect(r)
		r.state = .Off
	}
	return success()
}

ws_attach_disconnect :: proc(r: ^Ws_Attach_Runtime) {
	if r.manager.layout_batch == ws_layout_batch {
		r.manager.layout_batch = nil
	}
	ws_adapter_close(r.ws)
}

ws_attach_tick :: proc(r: ^Ws_Attach_Runtime, now: time.Time) {
	if r.output_open && !health.output_tail_drain(&r.output, r.output_fd) {
		ws_attach_close_output(r)
	}
	if r.state == .Attaching {
		if ws_attach_receive(r) {
			return
		}
		if !r.killed && time.diff(r.child_start, now) > WS_ATTACH_CHILD_LIMIT {
			posix.kill(posix.pid_t(r.child), .SIGKILL)
			r.killed = true
		}
		return
	}
	if r.state != .Waiting || time.diff(now, r.next_attempt) > 0 {
		return
	}
	if err := ws_attach_spawn(r, now); err != "" {
		ws_attach_failed_attempt(r, err, false, now)
	}
}

ws_attach_spawn :: proc(r: ^Ws_Attach_Runtime, now: time.Time) -> string {
	if r.ws.state == .Serving {
		r.state = .Serving
		return ""
	}
	if r.rendezvous == 0 {
		if err := ws_attach_register(r); err != "" {
			return err
		}
	}
	binary, err := os.get_executable_path(context.temp_allocator)
	if err != nil {
		return "cannot resolve the shoji executable"
	}
	binary_c := fmt.ctprintf("%s", binary)
	args := [5]cstring{"/usr/bin/sudo", "-n", binary_c, "--ws-attach", nil}
	pid, output_fd, spawn_err := spawn_with_stderr_pipe(args[:])
	if spawn_err != "" {
		return spawn_err
	}
	ws_attach_close_output(r)
	r.output = {}
	r.output_fd, r.output_open = output_fd, output_fd >= 0
	r.child, r.child_start, r.killed = pid, now, false
	r.attempts += 1
	r.state = .Attaching
	return ""
}

// The receive right lives as long as the daemon, so the name is registered once.
ws_attach_register :: proc(r: ^Ws_Attach_Runtime) -> string {
	bootstrap, ok := gate.gate_process_bootstrap_port()
	if !ok {
		return "no session bootstrap port; run the daemon in the login session"
	}
	task := gate.gate_mach_task_self()
	port: u32
	if gate.gate_mach_port_allocate(task, gate.MACH_PORT_RIGHT_RECEIVE, &port) != 0 {
		return "cannot allocate the gate rendezvous port"
	}
	if code := gate.gate_bootstrap_register(bootstrap, gate.GATE_RENDEZVOUS_NAME, port);
	   code != 0 {
		gate.gate_mach_port_destroy(task, port)
		return fmt.tprintf("gate rendezvous name is in use (%d)", code)
	}
	r.rendezvous = port
	return ""
}

// Non-blocking: takes a delivered gate right if one is queued.
ws_attach_receive :: proc(r: ^Ws_Attach_Runtime) -> bool {
	if r.rendezvous == 0 {
		return false
	}
	message: Ws_Mach_Buffer
	options := u32(gate.MACH_MSG_RECEIVE) | u32(gate.MACH_RCV_TIMEOUT)
	size := u32(len(message.bytes))
	if gate.gate_mach_msg(&message.bytes[0], options, 0, size, r.rendezvous, 0, 0) != 0 {
		return false
	}
	service, ok := gate.gate_handshake_send_right(message.bytes[:])
	if !ok {
		return false
	}
	ws_adapter_close(r.ws)
	ws_adapter_connect(r.ws, gate.gate_mach_task_self(), service)
	fmt.eprintln("shoji:", ws_adapter_describe(r.ws))
	if r.ws.state != .Serving {
		return false
	}
	r.manager.layout_batch = ws_layout_batch
	r.manager.ws_debug = ws_debug
	r.state = .Serving
	health.bounded_set(&r.cause, "")
	return true
}

// Pure retry policy, unit-tested.
ws_attach_exit_outcome :: proc(
	exit: health.Child_Exit,
	connected: bool,
	attempts: u32,
) -> Ws_Attach_Outcome {
	if connected {
		return .Connected
	}
	if exit.kind == .Exited && exit.code == attach.WS_ATTACH_EXIT_REFUSED {
		return .Give_Up
	}
	if attempts >= WS_ATTACH_ATTEMPTS {
		return .Give_Up
	}
	return .Retry
}

// Routes a reaped child; false when `pid` is not the attach child.
ws_attach_child_finished :: proc(r: ^Ws_Attach_Runtime, pid, status: i32, now: time.Time) -> bool {
	if r.child == 0 || pid != r.child {
		return false
	}
	r.child = 0
	if r.output_open {
		health.output_tail_drain(&r.output, r.output_fd)
	}
	ws_attach_close_output(r)
	exit := health.child_exit_from_status(status)
	if r.state == .Off {
		return true
	}
	connected := r.state == .Serving || ws_attach_receive(r)
	if connected {
		return true
	}
	cause := health.output_tail_last_line(&r.output)
	if cause == "" {
		cause = health.child_exit_text(exit)
	}
	give_up := ws_attach_exit_outcome(exit, false, r.attempts) == .Give_Up
	ws_attach_failed_attempt(r, cause, give_up, now)
	return true
}

ws_attach_failed_attempt :: proc(
	r: ^Ws_Attach_Runtime,
	cause: string,
	give_up: bool,
	now: time.Time,
) {
	health.bounded_set(&r.cause, cause)
	// The child already prefixes its own message; spawn errors are bare.
	fmt.eprintf("shoji: gate: %s\n", cause)
	if give_up || r.attempts >= WS_ATTACH_ATTEMPTS {
		r.state = .Failed
		r.failed_event = true
		return
	}
	r.retry_delay = min(max(r.retry_delay * 2, WS_ATTACH_RETRY_FIRST), WS_ATTACH_RETRY_MAX)
	r.next_attempt = time.time_add(now, r.retry_delay)
	r.state = .Waiting
}

ws_attach_close_output :: proc(r: ^Ws_Attach_Runtime) {
	if r.output_fd >= 0 {
		posix.close(posix.FD(r.output_fd))
	}
	r.output_fd, r.output_open = -1, false
}

// D2: user-facing WindowServer diagnostics. `shoji --ws-report [DIR]` prints
// an install report and, when the gate can be reached, exports the
// observer's event ring (raw + decoded JSON) for bug reports. Read-only
// except for the gate's own Dump, which only writes the ring snapshot.


WS_RING_PATH :: gate.OBSERVER_RESPONSE_PATH

// ------------------------------------------------------------------------
// Event ring (observer V3 snapshot; mirrors lifecycle/report.py)
// ------------------------------------------------------------------------

WS_RING_EVENTS :: 256
WS_RING_HEADER :: 56
WS_RING_STRIDE :: 104
WS_RING_SIZE :: WS_RING_HEADER + WS_RING_EVENTS * WS_RING_STRIDE

Ws_Ring_Event :: struct {
	sequence:    u64,
	count:       u32,
	flag:        u32,
	result:      i32,
	held:        u32,
	duration_us: f64,
	ids:         []u32,
	ops:         []i32,
}

Ws_Ring :: struct {
	schema:           int,
	observer_version: u64,
	calls:            u64,
	retained:         int,
	events:           []Ws_Ring_Event,
}

@(private = "file")
le :: proc(data: []u8, offset: int, $T: typeid) -> T {
	value: T
	for i in 0 ..< size_of(T) {
		value |= T(data[offset + i]) << (8 * uint(i))
	}
	return value
}

// Refuses anything but a complete, untorn, internally consistent snapshot.
ws_ring_decode :: proc(
	data: []u8,
	allocator := context.temp_allocator,
) -> (
	ring: Ws_Ring,
	err: string,
) {
	if len(data) != WS_RING_SIZE || string(data[:8]) != "WSOBSERV" {
		return {}, "not a complete V3 observer ring"
	}
	version, calls := le(data, 8, u64), le(data, 16, u64)
	numer, denom, torn := le(data, 40, u32), le(data, 44, u32), le(data, 48, u32)
	if version != 3 || numer == 0 || denom == 0 || torn != 0 {
		return {}, "unsupported version, invalid timebase or torn snapshot"
	}
	events := make([dynamic]Ws_Ring_Event, 0, WS_RING_EVENTS, allocator)
	for index in 0 ..< WS_RING_EVENTS {
		off := WS_RING_HEADER + index * WS_RING_STRIDE
		sequence := le(data, off, u64)
		if sequence == 0 {
			continue
		}
		before, after := le(data, off + 16, u64), le(data, off + 24, u64)
		captured := le(data, off + 44, u32)
		if sequence > calls || after < before || captured > 4 {
			return {}, "inconsistent ring event"
		}
		for e in events {
			if e.sequence == sequence {
				return {}, "duplicate ring sequence"
			}
		}
		event := Ws_Ring_Event {
			sequence    = sequence,
			count       = le(data, off + 32, u32),
			flag        = le(data, off + 36, u32),
			result      = le(data, off + 40, i32),
			held        = le(data, off + 48, u32),
			duration_us = f64(after - before) * f64(numer) / f64(denom) / 1000,
			ids         = make([]u32, captured, allocator),
			ops         = make([]i32, captured, allocator),
		}
		for i in 0 ..< int(captured) {
			event.ids[i] = le(data, off + 52 + 4 * i, u32)
			event.ops[i] = le(data, off + 68 + 4 * i, i32)
		}
		append(&events, event)
	}
	// Ring slots are reused modulo 256: order by sequence.
	for i in 1 ..< len(events) {
		for j := i; j > 0 && events[j - 1].sequence > events[j].sequence; j -= 1 {
			events[j - 1], events[j] = events[j], events[j - 1]
		}
	}
	return {1, version, calls, len(events), events[:]}, ""
}

// ------------------------------------------------------------------------
// Runtime allowlist evaluation (same predicate as the payload)
// ------------------------------------------------------------------------

Ws_Clients_Report :: struct {
	present, trusted, listed: bool,
	entries:                  int,
}

ws_clients_evaluate :: proc(
	content: string,
	file_uid, file_mode: u32,
	file_size: i64,
	dir_uid, dir_mode: u32,
	self_cdhash: []u8,
) -> Ws_Clients_Report {
	r := Ws_Clients_Report {
		present = true,
	}
	r.trusted = gate.gate_allowlist_trusted(file_uid, file_mode, file_size, dir_uid, dir_mode)
	start := 0
	for i in 0 ..= len(content) {
		if i == len(content) || gate.gate_allowlist_separator(content[i]) {
			if i - start == 40 {
				r.entries += 1
			}
			start = i + 1
		}
	}
	r.listed =
		r.trusted &&
		len(self_cdhash) == 20 &&
		gate.gate_identity_matches_any(content, self_cdhash, 0)
	return r
}

// ------------------------------------------------------------------------
// CLI
// ------------------------------------------------------------------------


// Ask a running daemon (which may own the gate) before claiming directly.
@(private = "file")
daemon_request :: proc(args: []string) -> (text: string, reached: bool) {
	data, ok := ipc.encode_message(args)
	if !ok {
		return
	}
	defer delete(data)
	fd := connect_socket(ipc.socket_path())
	if fd < 0 {
		return
	}
	defer close(fd)
	if !write_all(fd, data) {
		return
	}
	shutdown(fd, 1)
	deadline := time.time_add(time.now(), 5 * time.Second)
	b := strings.builder_make(context.temp_allocator)
	buffer: [4096]u8
	for wait_socket(fd, 1, deadline) {
		n := recv(fd, &buffer[0], len(buffer), 0)
		if n <= 0 {
			break
		}
		strings.write_bytes(&b, buffer[:n])
	}
	text = strings.to_string(b)
	if len(text) > 0 && text[0] == 7 {
		text = text[1:]
	} // failure marker
	return strings.trim_space(text), true
}

ws_report_cli :: proc(args: []string) -> int {
	out_dir := len(args) > 0 ? args[0] : ""
	started := time.now()
	build := attach.os_build()
	fmt.printf(
		"macOS build: %s (payload supports %s: %s)\n",
		build,
		gate.supported_builds(),
		attach.gate_supports(build) ? "yes" : "no",
	)

	sentinel := os.exists(attach.WS_DISABLE_SENTINEL)
	fmt.printf("kill switch: %s (%s)\n", sentinel ? "ON" : "off", attach.WS_DISABLE_SENTINEL)

	if payload, _, ok := attach.read_limited(attach.WS_PAYLOAD_PATH, 64 << 20); ok {
		ctx: sha2.Context_256
		sha2.init_256(&ctx)
		sha2.update(&ctx, payload)
		digest: [32]u8
		sha2.final(&ctx, digest[:])
		fmt.printf("payload: installed sha256=%s\n", attach.hex(digest[:]))
	} else {
		fmt.println("payload: not installed")
	}
	fmt.printf("payload resident: %v (status file %s)\n", ws_tgate_present(), WS_TGATE_STATUS_PATH)

	self: [20]u8
	self_ok := attach.csops(i32(posix.getpid()), 5, &self, len(self)) == 0
	fmt.printf(
		"this binary CDHash: %s\n",
		self_ok ? attach.hex(self[:]) : "unavailable (unsigned?)",
	)
	dir: posix.stat_t
	content, file, clients_ok := attach.read_limited(
		attach.WS_CLIENTS_PATH,
		gate.GATE_CLIENTS_LIMIT,
	)
	if clients_ok && posix.lstat(attach.WS_PAYLOAD_DIR, &dir) == .OK {
		r := ws_clients_evaluate(
			string(content),
			u32(file.st_uid),
			u32(transmute(u16)file.st_mode),
			i64(file.st_size),
			u32(dir.st_uid),
			u32(transmute(u16)dir.st_mode),
			self_ok ? self[:] : nil,
		)
		fmt.printf(
			"clients file: %d entries, %s, this binary %s\n",
			r.entries,
			r.trusted ? "root-owned" : "UNTRUSTED (must be root-owned, not group/world-writable)",
			r.listed ? "listed" : "NOT listed (the daemon's --ws-attach adds it)",
		)
	} else {
		fmt.println("clients file: absent (only build-time pins can claim the gate)")
	}

	dumped := false
	if text, reached := daemon_request({"debug", "ws", "dump"}); reached {
		fmt.printf("daemon: %s\n", text)
		dumped = strings.contains(text, "ring=")
	} else {
		// Only the daemon holds the gate (through --ws-attach); the report never
		// claims it, so it cannot disturb a later attach.
		fmt.println("gate: not contacted (no running daemon)")
	}

	if out_dir == "" {
		return 0
	}
	if !dumped {
		fmt.println("event ring: not exported (needs a daemon serving the gate)")
		return 1
	}
	raw, st, ok := attach.read_limited(WS_RING_PATH, WS_RING_SIZE)
	// The Dump above rewrote the snapshot; an older file is a previous run's.
	written_ns := i64(st.st_mtim.tv_sec) * 1_000_000_000 + i64(st.st_mtim.tv_nsec)
	if !ok || written_ns < time.to_unix_nanoseconds(started) - 1_000_000_000 {
		fmt.println("event ring: snapshot missing or stale")
		return 1
	}
	ring, err := ws_ring_decode(raw)
	if err != "" {
		fmt.printf("event ring: %s\n", err)
		return 1
	}
	_ = os.make_directory_all(out_dir)
	bin_path := fmt.tprintf("%s/ws-ring.bin", out_dir)
	json_path := fmt.tprintf("%s/ws-ring.json", out_dir)
	encoded, merr := json.marshal(ring, {pretty = true}, context.temp_allocator)
	if merr != nil ||
	   os.write_entire_file(bin_path, raw) != nil ||
	   os.write_entire_file(json_path, encoded) != nil {
		fmt.printf("event ring: cannot write to %s\n", out_dir)
		return 1
	}
	fmt.printf(
		"event ring: %d calls, %d retained → %s, %s\n",
		ring.calls,
		ring.retained,
		bin_path,
		json_path,
	)
	return 0
}

// Scripting-addition protocol client
// ------------------------------------------------------------------------

addition_connect :: proc() -> i32 {
	return connect_socket(fmt.tprintf("/tmp/shoji-sa_%d.socket", getuid()))
}

addition_exchange :: proc(
	packet: ^dock.Packet,
	handshake: bool = false,
	created_space: ^u64 = nil,
) -> (
	dock.Capabilities,
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

	if !write_all(fd, dock.finish(packet)) {
		return {}, "could not send scripting-addition request"
	}

	status: [1]u8
	if !read_exact(fd, status[:]) {
		return {}, "scripting addition did not acknowledge request"
	}

	if status[0] == u8(dock.Status.Native_Error) {
		data: [5]u8
		if !read_exact(fd, data[:]) {
			return {}, "incomplete scripting-addition native error"
		}
		r := dock.reader(data[:])
		stage := dock.unpack(&r, dock.Native_Stage)
		code := dock.unpack(&r, i32)
		return {}, fmt.tprintf("scripting addition failed at %v (native error %d)", stage, code)
	}

	if status[0] != u8(dock.Status.OK) {
		return {}, fmt.tprintf("scripting addition returned %v", dock.Status(status[0]))
	}

	if handshake {
		data: [len(dock.VERSION) + 5]u8
		if !read_exact(fd, data[:]) {
			return {}, "incomplete scripting-addition handshake"
		}

		caps, ok := dock.handshake(data[:]); if !ok {
			return {}, "incompatible scripting-addition protocol"
		}

		return caps, ""
	}

	if created_space != nil {
		data: [8]u8
		if !read_exact(fd, data[:]) {
			return {}, "incomplete tracked Space creation response"
		}

		r := dock.reader(data[:]); created_space^ = dock.unpack(&r, u64)
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

	packet := dock.begin(.Space_Create_Tracked)
	dock.pack(&packet, anchor)

	id: u64
	_, err = addition_exchange(&packet, created_space = &id)
	return id, err
}

addition_check :: proc() -> (dock.Capabilities, string) {
	packet := dock.begin(.Handshake)
	return addition_exchange(&packet, true)
}

// Gated Space move (C4): Window_To_Space_Transaction commits synchronously
// through the transaction table so the WindowServer gate can apply a staged
// landing. Matches Ws_Space_Send; refuses payloads without the capability.
addition_space_transaction :: proc(_: rawptr, target: u64, wid: u32, source: u64) -> string {
	caps, err := addition_check()
	if err != "" {
		return err
	}
	if .Space_Transaction not_in caps {
		return "Dock payload lacks transactional Space moves"
	}
	packet := dock.begin(.Window_To_Space_Transaction)
	dock.pack(&packet, target)
	dock.pack(&packet, wid)
	dock.pack(&packet, source)
	_, err = addition_exchange(&packet)
	return err
}

addition_cached_valid: bool
addition_cached_caps: dock.Capabilities

addition_capabilities :: proc() -> (dock.Capabilities, string) {
	if addition_cached_valid {
		return addition_cached_caps, ""
	}
	caps, err := addition_check()
	if err != "" {
		return {}, err
	}
	addition_cached_valid, addition_cached_caps = true, caps
	return caps, ""
}

// Buffer size for a scaled resize. WindowServer bounds follow the app's
// committed size, not the presentation transform.
resize_window_bounds :: proc(user: rawptr, id: u32) -> (Rect, bool) {
	state := (^State)(user)
	r: Rect
	if SLSGetWindowBounds(state.connection, id, &r) != 0 {
		return {}, false
	}
	return r, true
}

resize_transform_swept_at: f64
resize_transform_noted: bool

// WindowServer keeps a set transform and shifts it by each later move, so a
// reset sent just before the app's own move leaves the window drawn off its
// bounds (and off the focus ring). Re-check windows that just settled, and
// sweep every managed window once a second for older drift.
resize_transform_tick :: proc(state: ^State) {
	m := &state.manager
	if m.scale_present == nil || m.suspended || m.gesture_active {
		return
	}
	now := m.scroll_time
	sweep := now - resize_transform_swept_at >= 1
	if sweep {
		resize_transform_swept_at = now
	}
	for id, w in m.windows {
		recent := now - w.resize_settled_at < 1
		if !(recent || sweep) ||
		   !managed(w) ||
		   w.concealed ||
		   w.resize_scaled ||
		   w.opening.phase != .Admitted ||
		   id in state.animations ||
		   id in state.resize_covers {
			continue
		}
		s := space_by_id(m, w.space)
		if s == nil ||
		   !s.visible ||
		   s.view.scroll.dragging ||
		   s.view.scroll.motion.active ||
		   s.view.scroll.geometry_active {
			continue
		}
		t: Animation_Transform
		r: Rect
		if SLSGetWindowTransform(state.connection, id, &t) != 0 ||
		   SLSGetWindowBounds(state.connection, id, &r) != 0 {
			continue
		}
		// Only a translation drift is ours to repair. Any other transform
		// belongs to an animation in flight.
		if t.b != 0 || t.c != 0 || math.abs(t.a - 1) > 1e-6 || math.abs(t.d - 1) > 1e-6 {
			continue
		}
		if math.abs(t.tx + r.x) < 0.5 && math.abs(t.ty + r.y) < 0.5 {
			continue
		}
		req := dock.Present_Request {
			window = id,
			mask   = dock.PRESENT_TRANSFORM,
			a      = 1,
			d      = 1,
			tx     = -r.x,
			ty     = -r.y,
		}
		if err := resize_scale_present(state, req); err != "" && !resize_transform_noted {
			resize_transform_noted = true
			fmt.eprintln("shoji: transform repair:", err)
		}
	}
}

resize_scale_present :: proc(_: rawptr, req: dock.Present_Request) -> string {
	return addition_present(req)
}

// One Dock transaction for the subset of presentation fields in `req`.
addition_present :: proc(req: dock.Present_Request) -> string {
	caps, err := addition_capabilities()
	if err != "" {
		return err
	}
	if .Window_Present not_in caps {
		return "Dock payload lacks window presentation"
	}
	if !dock.present_valid(req) {
		return "invalid presentation"
	}
	packet := dock.begin(.Window_Present)
	dock.pack(&packet, req.window)
	dock.pack(&packet, req.mask)
	dock.pack(&packet, req.event_kind)
	dock.pack(&packet, req.alpha)
	dock.pack(&packet, req.x)
	dock.pack(&packet, req.y)
	dock.pack(&packet, req.w)
	dock.pack(&packet, req.h)
	dock.pack(&packet, req.p0)
	dock.pack(&packet, req.p1)
	dock.pack(&packet, req.a)
	dock.pack(&packet, req.b)
	dock.pack(&packet, req.c)
	dock.pack(&packet, req.d)
	dock.pack(&packet, req.tx)
	dock.pack(&packet, req.ty)
	_, err = addition_exchange(&packet)
	// A dead Dock socket must not keep the previous handshake.
	if err != "" {
		addition_cached_valid = false
	}
	return err
}

addition_action :: proc(action: Action) -> string {
	caps, err := addition_check(); if err != "" {
		return err
	}

	packet: dock.Packet

	#partial switch action.kind {
	case .Conceal:
		if .Window_Conceal not_in caps {
			return "Dock payload lacks window concealment; restart Dock and the Shoji service"
		}
		packet = dock.begin(.Window_Conceal); dock.pack(&packet, action.window)
		dock.pack(&packet, u8(action.flag ? 1 : 0))
	case .Order:
		packet = dock.begin(.Window_Order); dock.pack(&packet, action.window)
		dock.pack(&packet, i32(action.value))
		dock.pack(&packet, action.relative)
	case .Scale:
		packet = dock.begin(.Window_Scale); dock.pack(&packet, action.window)
		dock.pack(&packet, f32(action.frame.x))
		dock.pack(&packet, f32(action.frame.y))
		dock.pack(&packet, f32(action.frame.w))
		dock.pack(&packet, f32(action.frame.h))
	case .Focus_Without_Raise:
		packet = dock.begin(.Window_Focus)
		dock.pack(&packet, action.window)
	case .Space_Focus, .Space_Create, .Space_Destroy:
		op := dock.Opcode.Space_Focus

		if action.kind == .Space_Create {
			op = .Space_Create
		}

		if action.kind == .Space_Destroy {
			op = .Space_Destroy
		}
		packet = dock.begin(op); dock.pack(&packet, action.space)
	case .Space_Move:
		packet = dock.begin(.Space_Move); dock.pack(&packet, action.space)
		dock.pack(&packet, action.destination)
		dock.pack(&packet, u64(0))
		dock.pack(&packet, false)
	case .Space:
		packet = dock.begin(.Window_To_Space); dock.pack(&packet, action.space)
		dock.pack(&packet, action.window)
	case .Opacity:
		packet = dock.begin(
			action.duration > 0 ? dock.Opcode.Window_Opacity_Fade : dock.Opcode.Window_Opacity,
		)
		dock.pack(&packet, action.window)
		dock.pack(&packet, f32(action.value))
		if action.duration > 0 {
			dock.pack(&packet, f32(action.duration))
		}
	case .Layer:
		level := dock.window_layer_key(action.value, caps)
		packet = dock.begin(.Window_Layer); dock.pack(&packet, action.window)
		dock.pack(&packet, level)
	case .Sticky, .Shadow:
		packet = dock.begin(
			action.kind == .Sticky ? dock.Opcode.Window_Sticky : dock.Opcode.Window_Shadow,
		)
		dock.pack(&packet, action.window)
		dock.pack(&packet, action.flag)
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
Addition_Reload_Spawn :: proc(
	user: rawptr,
	phase: Addition_Reload_Phase,
	binary, payload: string,
) -> (
	pid: i32,
	output_fd: i32,
	err: string, // Nonblocking read end of the child's stderr, or -1.
)
Addition_Reload :: struct {
	binary, payload:         string,
	dock, child, child_dock: i32,
	phase:                   Addition_Reload_Phase,
	healthy, loaded:         bool,
	next_attempt:            time.Time,
	retry_delay:             time.Duration,
	spawn:                   Addition_Reload_Spawn,
	user:                    rawptr,
	// The child's stderr is captured so failures report their real cause.
	output_fd:               i32,
	output_open:             bool, // output_fd is owned only while this is set.
	output:                  health.Output_Tail,
	spawned_at:              time.Time,
	payload_health:          health.Payload_Health,
	// Set by a state change; consumed once by the notification owner.
	transition:              health.Health_Transition,
	crash_directory:         string, // Overrides the user's crash reports for tests.
}

ADDITION_PAYLOAD_NAME :: "shoji-sa.dylib"

// The Dock payload ships beside the executable: Contents/Resources in the app
// bundle, or the same directory in a development build (bin/).
addition_payload_path :: proc() -> (path: string, err: string) {
	binary, binary_err := os.get_executable_path(context.temp_allocator)
	if binary_err != nil {
		return "", "cannot resolve shoji executable path"
	}
	dir := filepath.dir(binary)
	contents := filepath.dir(dir)
	candidates := [2]string {
		fmt.tprintf("%s/Resources/%s", contents, ADDITION_PAYLOAD_NAME),
		fmt.tprintf("%s/%s", dir, ADDITION_PAYLOAD_NAME),
	}
	for candidate in candidates {
		if os.is_file(candidate) {
			return candidate, ""
		}
	}
	return "", fmt.tprintf("Dock payload %s not found beside %s", ADDITION_PAYLOAD_NAME, binary)
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
	addition_reload_close_output(r)
	delete(r.payload); delete(r.binary)
	r^ = {}
}
addition_reload_close_output :: proc(r: ^Addition_Reload) {
	if r.output_open {
		posix.close(posix.FD(r.output_fd))
	}
	r.output_open = false
	r.output_fd = -1
}

// The other file-action bindings are declared with the process helpers.
@(default_calling_convention = "c")
foreign _ {
	posix_spawn_file_actions_addclose :: proc(actions: ^rawptr, fd: i32) -> posix.Errno ---
}

// Starts argv with stderr redirected to a new pipe. The read end is
// nonblocking and close-on-exec; the caller owns it.
spawn_with_stderr_pipe :: proc(argv: []cstring) -> (pid: i32, output_fd: i32, err: string) {
	assert(len(argv) > 0 && argv[len(argv) - 1] == nil)
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK {
		return 0, -1, "cannot create recovery output pipe"
	}
	actions: rawptr
	if support.posix_spawn_file_actions_init(&actions) != .NONE {
		posix.close(fds[0]); posix.close(fds[1])
		return 0, -1, "cannot prepare recovery subprocess"
	}
	defer support.posix_spawn_file_actions_destroy(&actions)
	support.posix_spawn_file_actions_adddup2(&actions, i32(fds[1]), 2)
	posix_spawn_file_actions_addclose(&actions, i32(fds[0]))
	posix_spawn_file_actions_addclose(&actions, i32(fds[1]))
	child: posix.pid_t
	code := posix.posix_spawn(&child, argv[0], &actions, nil, raw_data(argv), _NSGetEnviron()^)
	posix.close(fds[1])
	if code != nil {
		posix.close(fds[0])
		return 0, -1, "cannot start scripting-addition recovery subprocess"
	}
	posix.fcntl(fds[0], .SETFL, posix.O_NONBLOCK)
	posix.fcntl(fds[0], .SETFD, posix.FD_CLOEXEC)
	return i32(child), i32(fds[0]), ""
}

addition_reload_spawn :: proc(
	user: rawptr,
	phase: Addition_Reload_Phase,
	binary, payload: string,
) -> (
	i32,
	i32,
	string,
) {
	binary_c := strings.clone_to_cstring(binary, context.temp_allocator)
	if phase == .Load {
		// The root side resolves the payload itself, so the sudoers rule can
		// pin `shoji --load-sa` exactly.
		args := [5]cstring{"/usr/bin/sudo", "-n", binary_c, "--load-sa", nil}
		return spawn_with_stderr_pipe(args[:])
	}
	args := [3]cstring{binary_c, "--check-sa", nil}
	return spawn_with_stderr_pipe(args[:])
}
addition_reload_backoff :: proc(r: ^Addition_Reload, now: time.Time) {
	r.retry_delay = r.retry_delay == 0 ? time.Second : min(r.retry_delay * 2, 30 * time.Second)
	r.next_attempt = time.time_add(now, r.retry_delay)
}
addition_reload_tick :: proc(r: ^Addition_Reload, dock_pid: i32, now: time.Time) {
	if r.payload == "" {
		return
	}
	if r.output_open && !health.output_tail_drain(&r.output, r.output_fd) {
		addition_reload_close_output(r)
	}
	if dock_pid != r.dock {
		r.dock = dock_pid
		r.healthy, r.loaded = false, false
		r.phase = .Check
		r.next_attempt = now
		r.retry_delay = 0
	}
	if dock_pid == 0 || r.child != 0 || r.healthy || time.diff(now, r.next_attempt) > 0 {
		return
	}
	spawn := r.spawn
	if spawn == nil {
		spawn = addition_reload_spawn
	}
	pid, output_fd, err := spawn(r.user, r.phase, r.binary, r.payload)
	if err != "" || pid <= 0 {
		if output_fd >= 0 {
			posix.close(posix.FD(output_fd))
		}
		cause := fmt.tprintf("Dock payload recovery: %s", err)
		fmt.eprintln("shoji:", cause)
		addition_reload_record_failure(r, cause, "", now)
		addition_reload_backoff(r, now)
		return
	}
	addition_reload_close_output(r)
	r.output = {}
	r.output_fd = output_fd
	r.output_open = output_fd >= 0
	r.spawned_at = now
	r.child, r.child_dock = pid, dock_pid
}

addition_reload_record_failure :: proc(
	r: ^Addition_Reload,
	cause, crash_report: string,
	now: time.Time,
) {
	transition := health.payload_health_failure(&r.payload_health, cause, crash_report, now)
	if transition != .None {
		r.transition = transition
	}
}

// Collects the finished child's output, forwards it to the log, and returns
// the evidence-based cause plus any crash report written since the spawn.
addition_reload_collect :: proc(
	r: ^Addition_Reload,
	exit: health.Child_Exit,
) -> (
	cause, crash_report: string,
) {
	if r.output_open {
		health.output_tail_drain(&r.output, r.output_fd)
		addition_reload_close_output(r)
	}
	output := health.output_tail_text(&r.output)
	if output != "" {
		fmt.eprint(output)
		if !strings.has_suffix(output, "\n") {
			fmt.eprintln()
		}
	}
	action := r.phase == .Load ? "Dock payload load failed" : "Dock payload check failed"
	cause = health.payload_failure_cause(action, exit, output)
	directory := r.crash_directory
	if directory == "" {
		directory = health.user_crash_report_directory()
	}
	if directory != "" {
		crash_report = health.crash_report_newest(
			directory,
			health.CRASH_REPORT_PREFIX,
			r.spawned_at,
		)
	}
	return
}

addition_reload_finished :: proc(
	r: ^Addition_Reload,
	child: i32,
	exit: health.Child_Exit,
	now: time.Time,
) -> bool {
	if child == 0 || child != r.child {
		return false
	}
	r.child = 0
	success := health.child_exit_ok(exit)
	cause, crash_report := "", ""
	if !success {
		cause, crash_report = addition_reload_collect(r, exit)
	} else {
		addition_reload_close_output(r)
	}
	// A subprocess completing for an old Dock cannot establish current health.
	if r.child_dock != r.dock {
		return true
	}
	if r.phase == .Check {
		addition_reload_check_finished(r, success, cause, crash_report, now)
	} else {
		addition_reload_load_finished(r, success, cause, crash_report, now)
	}
	return true
}

addition_reload_check_finished :: proc(
	r: ^Addition_Reload,
	success: bool,
	cause, crash_report: string,
	now: time.Time,
) {
	if success {
		r.healthy = true
		r.retry_delay = 0
		if transition := health.payload_health_success(&r.payload_health, now);
		   transition != .None {
			r.transition = transition
		}
		fmt.eprintln("shoji: Dock payload is ready")
	} else if !r.loaded {
		// Expected before the first load: the payload is not resident yet.
		r.phase = .Load
		r.next_attempt = now
	} else {
		fmt.eprintln("shoji: loaded payload handshake failed; retrying verification:", cause)
		addition_reload_record_failure(r, cause, crash_report, now)
		addition_reload_backoff(r, now)
	}
}

addition_reload_load_finished :: proc(
	r: ^Addition_Reload,
	success: bool,
	cause, crash_report: string,
	now: time.Time,
) {
	r.phase = .Check
	if success {
		r.loaded = true
		r.next_attempt = now
		return
	}
	if crash_report != "" {
		fmt.eprintf("shoji: %s; crash report: %s; retrying\n", cause, crash_report)
	} else {
		fmt.eprintf("shoji: %s; retrying\n", cause)
	}
	addition_reload_record_failure(r, cause, crash_report, now)
	addition_reload_backoff(r, now)
}

// One capability per line, absent ones included, so a missing bit is as
// visible as a present one.
addition_print_capabilities :: proc(caps: dock.Capabilities) {
	style := service.Status_Style {
		color = service.stdout_color(),
	}
	fmt.printf(
		"Dock scripting addition: %d of %d capabilities\n",
		card(caps),
		len(dock.Capability),
	)
	for capability in dock.Capability {
		mark :=
			capability in caps \
				? service.paint(style, service.GREEN, "✓") \
				: service.paint(style, service.RED, "✗")
		fmt.printf("  %s %v\n", mark, capability)
	}
}

// Accepted-size feedback
// ------------------------------------------------------------------------

// A settled observation applies to one intent/context, not a learned universal
// minimum or maximum. Explicit retries and changed layout contexts invalidate it.
Size_Intent :: struct {
	w, h:                            f64,
	width_revision, height_revision: u64,
	viewport:                        Rect,
	space:                           u64,
	display:                         u32,
	pid:                             i32,
	zoomed, tabbed:                  bool,
}
Size_Feedback :: struct {
	intent:                               Size_Intent,
	accepted:                             Rect,
	width_valid, height_valid:            bool,
	pending:                              bool,
	generation:                           u64,
	expected, sample:                     Rect,
	requested_at, checked_at, sampled_at: f64,
	observations:                         int,
}
size_feedback_invalidate :: proc(w: ^Window) {
	f := &w.size_feedback
	i := w.size_intent
	context_changed :=
		f.intent.viewport != i.viewport ||
		f.intent.space != i.space ||
		f.intent.display != i.display ||
		f.intent.pid != i.pid ||
		f.intent.zoomed != i.zoomed ||
		f.intent.tabbed != i.tabbed
	width_changed :=
		context_changed || f.intent.w != i.w || f.intent.width_revision != i.width_revision
	height_changed :=
		context_changed || f.intent.h != i.h || f.intent.height_revision != i.height_revision
	if width_changed || height_changed {
		// Application constraints may couple width and height (for example an
		// aspect ratio), so changing either intent invalidates both adjustments.
		f.width_valid, f.height_valid = false, false
		f.pending = false; f.generation += 1; f.observations = 0
	}
	f.intent = i
}
size_feedback_request :: proc(w: ^Window, requested, previous: Rect, now: f64) {
	size_feedback_invalidate(w)
	f := &w.size_feedback
	if math.abs(requested.w - previous.w) <= 1 && math.abs(requested.h - previous.h) <= 1 {
		return
	}
	if f.pending &&
	   math.abs(f.expected.w - requested.w) <= 1 &&
	   math.abs(f.expected.h - requested.h) <= 1 {
		return
	}
	f.generation += 1
	f.expected, f.requested_at, f.checked_at = requested, now, now
	f.pending, f.observations = true, 0
}
size_feedback_duplicate :: proc(w: ^Window, requested: Rect) -> bool {
	f := &w.size_feedback
	return(
		f.pending &&
		math.abs(f.expected.w - requested.w) <= 1 &&
		math.abs(f.expected.h - requested.h) <= 1 \
	)
}
size_feedback_observe :: proc(w: ^Window, generation: u64, observed: Rect, now: f64) -> bool {
	f := &w.size_feedback
	if generation != f.generation ||
	   !f.pending ||
	   now - f.requested_at < 0.15 ||
	   now - f.checked_at < 0.06 {
		return false
	}
	f.checked_at = now
	if math.is_nan(observed.w) ||
	   math.is_nan(observed.h) ||
	   math.is_inf(observed.w) ||
	   math.is_inf(observed.h) ||
	   observed.w <= 0 ||
	   observed.h <= 0 {
		return false
	}
	if f.observations == 0 ||
	   math.abs(f.sample.w - observed.w) > 1 ||
	   math.abs(f.sample.h - observed.h) > 1 {
		f.sample, f.sampled_at, f.observations = observed, now, 1
		return false
	}
	if now - f.sampled_at < 0.06 {
		return false
	}
	f.pending = false
	changed := false
	if math.abs(observed.w - f.intent.w) <= 1 {
		if f.width_valid {
			f.width_valid, changed = false, true
		}
	} else if math.abs(observed.w - f.expected.w) > 1 {
		f.accepted.w, f.width_valid, changed = observed.w, true, true
	}
	if math.abs(observed.h - f.intent.h) <= 1 {
		if f.height_valid {
			f.height_valid, changed = false, true
		}
	} else if math.abs(observed.h - f.expected.h) > 1 {
		f.accepted.h, f.height_valid, changed = observed.h, true, true
	}
	if changed {
		w.size_feedback_reflow = true
	}
	return changed
}
// A late client response that matches the original intent supersedes a
// provisional adjustment. This never fabricates a minimum from a failed read.
size_feedback_late_result :: proc(w: ^Window, observed: Rect) -> bool {
	f := &w.size_feedback
	if f.pending {
		return false
	}
	changed := false
	if f.width_valid && observed.w > 0 && math.abs(observed.w - f.intent.w) <= 1 {
		f.width_valid, changed = false, true
	}
	if f.height_valid && observed.h > 0 && math.abs(observed.h - f.intent.h) <= 1 {
		f.height_valid, changed = false, true
	}
	if changed {
		w.size_feedback_reflow = true
	}
	return changed
}

scroll_feedback_prepare :: proc(m: ^Manager, s: ^Space) {
	v := &s.view
	for n := layout.first(v.root); n != nil; n = layout.next(n) {
		n.column_observed = 0
		any_observed := false
		footprint: f64
		for i in 0 ..< n.count {
			w := m.windows[n.windows[i]]
			if w == nil {
				continue
			}
			width, height := n.column_width, n.row_heights[i]
			if n.column_tabbed {
				height = n.frame.h
				if v.tab_indicator_top {
					height = max(1, height - layout.tab_indicator_gutter(v, n))
				} else {
					width = max(1, width - layout.tab_indicator_gutter(v, n))
				}
			}
			if n.zoom != nil {
				width, height = v.scroll.viewport.w, v.scroll.viewport.h
			}
			w.size_intent = {
				w               = width,
				h               = height,
				width_revision  = n.column_revision,
				height_revision = w.row_revision,
				viewport        = v.scroll.viewport,
				space           = s.id,
				display         = s.display,
				pid             = w.pid,
				tabbed          = n.column_tabbed,
				zoomed          = n.zoom != nil,
			}
			size_feedback_invalidate(w)
			if w.size_feedback.width_valid && n.zoom == nil {
				gutter := v.tab_indicator_top ? f64(0) : layout.tab_indicator_gutter(v, n)
				footprint = max(footprint, w.size_feedback.accepted.w + gutter)
				any_observed = true
			} else {
				footprint = max(footprint, n.column_width)
			}
		}
		if any_observed {
			n.column_observed = footprint
		}
	}
}

size_feedback_frame :: proc(w: ^Window, frame: Rect) -> Rect {
	r := frame
	if w.size_feedback.width_valid {
		r.w = w.size_feedback.accepted.w
	}
	if w.size_feedback.height_valid {
		r.h = w.size_feedback.accepted.h
	}
	return r
}


// Accepted-size feedback
// ------------------------------------------------------------------------

frame_size_feedback_tick :: proc(state: ^State, now: time.Time) {
	seconds := time.duration_seconds(time.diff(time.Time{}, now))
	m := &state.manager
	for id, w in m.windows {
		f := &w.size_feedback
		if !managed(w) {
			if f.pending || f.width_valid || f.height_valid {
				f.pending, f.width_valid, f.height_valid = false, false, false
				f.generation += 1
			}
			continue
		}
		if !f.pending ||
		   seconds - f.requested_at < 0.15 ||
		   seconds - f.checked_at < (seconds - f.requested_at > 3 ? f64(0.5) : f64(0.06)) {
			continue
		}
		s := space_by_id(m, w.space)
		if s == nil ||
		   !s.visible ||
		   s.view.layout != .Scroll ||
		   s.view.scroll.dragging ||
		   s.view.scroll.motion.active ||
		   s.view.scroll.geometry_active ||
		   m.suspended ||
		   m.gesture_active ||
		   w.grabbed ||
		   m.native_resize_window == id {
			continue
		}
		generation := f.generation
		owner, known := animation_recovery_query_owner(state.connection, id)
		pid: i32
		if !known || SLSConnectionGetPID(owner, &pid) != 0 {
			f.checked_at = seconds; continue
		}
		if pid != w.pid {
			f.pending, f.width_valid, f.height_valid = false, false, false
			state.dirty = true; continue
		}
		observed: Rect
		if SLSGetWindowBounds(state.connection, id, &observed) != 0 {
			f.checked_at = seconds; continue
		}
		if size_feedback_observe(w, generation, observed, seconds) {
			// The app is already at its accepted size. Correct layout occupancy
			// immediately instead of animating neighbors through that native frame.
			w.frame = observed
			if err := flush(m, s, true); err != "" {
				fmt.eprintln("shoji: accepted size:", err)
			}
			state.dirty = true
		}
	}
}

// Owned-window size validation
// ------------------------------------------------------------------------

// A separate controller process using Shoji's existing signed executable. It
// creates no daemon/socket and rejects every window outside the named fixture.
validate_window_sizes :: proc(pid: i32, swipe: bool = false) -> int {
	if !AXIsProcessTrusted() {
		fmt.eprintln("size validation requires Shoji's existing Accessibility access"); return 3
	}
	pool := pool_push(); defer pool_pop(pool)
	state: State
	state_init(&state); defer state_destroy(&state)
	state.validation_pid = pid
	if state.connection == 0 {
		fmt.eprintln("size validation requires the logged-in GUI session")
		return 3
	}
	app := AXUIElementCreateApplication(pid)
	if app == nil {
		return 3
	}
	state.applications[pid] = {
		element = app,
		name    = strings.clone("Shoji size fixture"),
	}
	array := attribute(app, "AXWindows")
	if array == nil {
		fmt.eprintln("size fixture has no accessible windows"); return 3
	}
	defer CFRelease(array)
	bounds := CGDisplayBounds(CGMainDisplayID())
	area := Rect{80, 80, min(1280, bounds.w - 160), min(800, bounds.h - 160)}
	if area.w < 1000 || area.h < 600 {
		fmt.eprintln("display is too small for this size fixture"); return 3
	}
	append(
		&state.manager.displays,
		Display{id = 1, index = 1, active_space = 1, frame = area, usable = area},
	)
	s := add_space(&state.manager, 1, 1, 1, area)
	s.visible = true; s.view.gap = 16; state.manager.active_space = 1
	a, b := u32(0), u32(0)
	count := CFArrayGetCount(array)
	if count != 2 {
		fmt.eprintln("expected exactly two disposable size fixture windows")
		return 3
	}
	for i in 0 ..< count {
		element := CFArrayGetValueAtIndex(array, i)
		title := attribute_text(element, "AXTitle")
		if !strings.has_prefix(title, "Shoji size fixture ") {
			fmt.eprintln("refusing a non-fixture window"); return 3
		}
		id: u32
		if _AXUIElementGetWindow(element, &id) != 0 || id == 0 {
			return 3
		}
		owner, known := animation_recovery_query_owner(state.connection, id)
		actual_pid: i32
		if !known || SLSConnectionGetPID(owner, &actual_pid) != 0 || actual_pid != pid {
			return 3
		}
		state.windows[id] = CFRetain(element)
		frame: Rect
		if SLSGetWindowBounds(state.connection, id, &frame) != 0 {
			return 3
		}
		add_window(
			&state.manager,
			{
				id = id,
				pid = pid,
				app = "Shoji size fixture",
				title = title,
				frame = frame,
				space = 1,
				display = 1,
				role = "AXWindow",
				subrole = "AXStandardWindow",
				opacity = 1,
			},
		)
		if strings.has_prefix(title, "Shoji size fixture A") {
			a = id
		}
		if strings.has_prefix(title, "Shoji size fixture B") {
			b = id
		}
	}
	if a == 0 || b == 0 {
		return 3
	}
	if swipe {
		return validate_fixture_swipe(&state, s, a, b)
	}
	set_layout(&state.manager, s, .Scroll)
	focus_window(&state.manager, b)
	state.manager.scroll_time = size_validation_seconds()
	if response := execute(
		&state.manager,
		{"window", fmt.tprintf("%d", a), "--column-width", "abs:300"},
	); response.failed {
		fmt.eprintln(response.text); return 1
	}
	if !size_validation_settle(&state, 1.2) {
		return 1
	}
	actual_a, actual_b: Rect
	if SLSGetWindowBounds(state.connection, a, &actual_a) != 0 ||
	   SLSGetWindowBounds(state.connection, b, &actual_b) != 0 {
		return 1
	}
	aw := state.manager.windows[a]
	if !aw.size_feedback.width_valid ||
	   actual_a.w < 699 ||
	   math.abs(aw.frame.w - actual_a.w) > 1 ||
	   actual_b.x - actual_a.x - actual_a.w < 14 {
		size_validation_print("clamped-width-failed", &state, a, b)
		return 1
	}
	size_validation_print("clamped-width-adapted", &state, a, b)
	if layout.find(s.view.root, a).column_size.value != 300 {
		return 1
	}
	state.manager.animation_duration = 0.5
	state.manager.scroll_time = size_validation_seconds()
	if response := execute(
		&state.manager,
		{"window", fmt.tprintf("%d", a), "--column-width", "abs:1000"},
	); response.failed {
		fmt.eprintln(response.text); return 1
	}
	intermediate := false
	focused_x := actual_b.x
	deadline := time.time_add(time.now(), time.Second)
	for time.diff(time.now(), deadline) > 0 {
		state.manager.scroll_time = size_validation_seconds()
		scroll_native_tick(&state, time.now())
		CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false)
		if SLSGetWindowBounds(state.connection, a, &actual_a) != 0 ||
		   SLSGetWindowBounds(state.connection, b, &actual_b) != 0 {
			return 1
		}
		if actual_a.w > 702 && actual_a.w < 998 {
			intermediate = true
		}
		size_validation_print("resize-sample", &state, a, b)
		if math.abs(actual_b.x - focused_x) > 2 {
			size_validation_print("focused-neighbor-moved", &state, a, b)
			return 1
		}
		frame_size_feedback_tick(&state, time.now())
		if !s.view.scroll.geometry_active && !s.view.scroll.motion.active {
			break
		}
	}
	if !intermediate || !size_validation_settle(&state, 0.4) {
		return 1
	}
	if SLSGetWindowBounds(state.connection, a, &actual_a) != 0 || math.abs(actual_a.w - 1000) > 2 {
		return 1
	}
	size_validation_print("coordinated-width-settled", &state, a, b)
	state.manager.animation_duration = 0
	if response := execute(
		&state.manager,
		{"window", fmt.tprintf("%d", a), "--column-width", "abs:1600"},
	); response.failed {
		return 1
	}
	if !size_validation_settle(&state, 0.6) {
		return 1
	}
	if SLSGetWindowBounds(state.connection, a, &actual_a) != 0 ||
	   math.abs(actual_a.w - 1200) > 1 ||
	   !aw.size_feedback.width_valid {
		return 1
	}
	if layout.find(s.view.root, a).column_size.value != 1600 ||
	   math.abs(layout.find(s.view.root, a).column_width - 1200) > 1 {
		return 1
	}
	size_validation_print("maximum-width-adapted", &state, a, b)
	if response := execute(
		&state.manager,
		{"window", fmt.tprintf("%d", a), "--stack", fmt.tprintf("%d", b)},
	); response.failed {
		return 1
	}
	if response := execute(
		&state.manager,
		{"window", fmt.tprintf("%d", a), "--row-height", "abs:200"},
	); response.failed {
		return 1
	}
	if !size_validation_settle(&state, 0.8) {
		return 1
	}
	if SLSGetWindowBounds(state.connection, a, &actual_a) != 0 ||
	   SLSGetWindowBounds(state.connection, b, &actual_b) != 0 {
		return 1
	}
	if !aw.size_feedback.height_valid ||
	   math.abs(actual_a.h - 280) > 1 ||
	   actual_b.y - actual_a.y - actual_a.h < 14 ||
	   aw.row_fixed != 200 {
		size_validation_print("row-height-adaptation-failed", &state, a, b)
		return 1
	}
	size_validation_print("row-height-adapted", &state, a, b)
	fmt.println(
		"PASS: foreign AX minimum/maximum width and row-height adaptation, retained requests and coordinated resize with stationary focused neighbor",
	)
	return 0
}
validate_fixture_swipe :: proc(state: ^State, s: ^Space, a, b: u32) -> int {
	m := &state.manager
	m.resize_fade = false
	set_layout(m, s, .Scroll)
	focus_window(m, a)
	m.animation_duration, m.scroll_animate = 0, true
	if flush(m, s) != "" || !size_validation_settle(state, .5) {
		return 1
	}
	if execute(m, {"window", fmt.tprintf("%d", a), "--column-width", "abs:1000"}).failed ||
	   !size_validation_settle(state, .5) {
		return 1
	}
	frame_a, frame_b: Rect
	if SLSGetWindowBounds(state.connection, a, &frame_a) != 0 ||
	   SLSGetWindowBounds(state.connection, b, &frame_b) != 0 {
		return 1
	}
	base_gap := frame_b.x - frame_a.x - frame_a.w
	start_x := frame_a.x
	maximum_error: f64
	scroll_begin_pan(m, s)
	for i in 0 ..< 30 {
		m.scroll_time = size_validation_seconds()
		if err := scroll_gesture_pan(m, s.id, i < 5 ? 60 : 0); err != "" {
			fmt.eprintln(err); return 1
		}
		if SLSGetWindowBounds(state.connection, a, &frame_a) != 0 ||
		   SLSGetWindowBounds(state.connection, b, &frame_b) != 0 {
			return 1
		}
		gap := frame_b.x - frame_a.x - frame_a.w
		maximum_error = max(maximum_error, math.abs(gap - base_gap))
		fmt.printf("sample=%d a_x=%.1f gap=%.1f baseline=%.1f\n", i, frame_a.x, gap, base_gap)
		CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.016, false)
	}
	s.view.scroll.dragging = false
	fmt.printf("maximum transient native-bounds gap error: %.1f points\n", maximum_error)
	return maximum_error <= 16 && math.abs(frame_a.x - start_x) >= 100 ? 0 : 1
}
size_validation_seconds :: proc() -> f64 {
	return time.duration_seconds(time.diff(time.Time{}, time.now()))
}
size_validation_settle :: proc(state: ^State, seconds: f64) -> bool {
	deadline := time.time_add(time.now(), time.Duration(seconds * 1e9))
	for time.diff(time.now(), deadline) > 0 {
		CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false)
		state.manager.scroll_time = size_validation_seconds()
		scroll_native_tick(state, time.now())
		frame_size_feedback_tick(state, time.now())
		for s in state.manager.spaces {
			if flush(&state.manager, s) != "" {
				return false
			}
		}
	}
	return true
}
size_validation_print :: proc(step: string, state: ^State, a, b: u32) {
	for id in ([2]u32{a, b}) {
		actual: Rect
		code := SLSGetWindowBounds(state.connection, id, &actual)
		w := state.manager.windows[id]
		data, err := json.marshal(struct {
			at:               f64,
			readback_status:  i32,
			step:             string,
			window:           u32,
			actual, expected: Rect,
			requested_width:  f64,
			adjusted:         bool,
		} {
			size_validation_seconds(),
			code,
			step,
			id,
			actual,
			w.frame,
			w.size_intent.w,
			w.size_feedback.width_valid,
		})
		if err == nil {
			fmt.println(string(data)); delete(data)
		}
	}
}
