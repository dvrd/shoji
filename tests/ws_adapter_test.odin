package tests

import "core:testing"
import "core:time"
import shoji "../src"
import gate "../src/windowserver/gate"

// Scripted gate: answers each command with the queued status, records calls.
Fake_Gate :: struct {
	statuses:  [32]i32,
	data0:     [32]u64,
	data1:     [32]u64,
	count:     int,
	calls:     int,
	commands:  [32]gate.Gate_Command,
	fail_at:   int, // 1-based call index whose transport fails; 0 = never
	bad_magic: bool,
	items:     [32]int, // item count sent with each call
	identity:  bool,
	rejected:  bool,
	uuid:      [16]u8,
	ops:       [gate.GATE_OP_REPORT_MAX]u32,
	op_count:  u32,
}

fake_push :: proc(g: ^Fake_Gate, status: i32, data0: u64 = 0, data1: u64 = 0) {
	g.statuses[g.count] = status
	g.data0[g.count] = data0
	g.data1[g.count] = data1
	g.count += 1
}

fake_exchange :: proc(
	user: rawptr,
	command: gate.Gate_Command,
	arg0, arg1: u64,
	items: []gate.Layout_Item,
) -> (gate.Gate_Reply, bool) {
	g := (^Fake_Gate)(user)
	index := g.calls
	g.commands[index] = command
	g.items[index] = len(items)
	g.calls += 1
	if g.fail_at == g.calls || index >= g.count {return {}, false}
	magic := u32(gate.GATE_REPLY_MAGIC)
	if g.bad_magic {magic = 0}
	reply := gate.Gate_Reply{
		magic = magic,
		version = gate.GATE_VERSION,
		command = u32(command),
		status = g.statuses[index],
		data0 = g.data0[index],
		data1 = g.data1[index],
	}
	if command == .Capabilities {
		reply.identity = g.identity
		reply.rejected = g.rejected
		reply.uuid = g.uuid
		reply.ops = g.ops
		reply.op_count = g.op_count
	}
	return reply, true
}

fake_adapter :: proc(g: ^Fake_Gate) -> shoji.Ws_Adapter {
	a := shoji.Ws_Adapter{exchange = fake_exchange, user = g}
	shoji.ws_adapter_claim(&a)
	return a
}

@(test)
ws_adapter_disabled_does_no_io_and_handles_nothing :: proc(t: ^testing.T) {
	a := shoji.Ws_Adapter{state = .Disabled}
	_, handled := shoji.ws_space_place(&a, 42, 10, 20)
	testing.expect(t, !handled)
	_, handled = shoji.ws_layout_stage(&a, {{1, 0, 0}}, 9, 4000)
	testing.expect(t, !handled)
	_, handled = shoji.ws_watch(&a, 42)
	testing.expect(t, !handled)
	_, handled = shoji.ws_receipt(&a, 1)
	testing.expect(t, !handled)
}

@(test)
ws_adapter_refused_hello_degrades_with_owner :: proc(t: ^testing.T) {
	g: Fake_Gate
	fake_push(&g, shoji.WS_STATUS_OWNED, 777)
	a := fake_adapter(&g)
	testing.expect_value(t, a.state, shoji.Ws_Adapter_State.Refused)
	testing.expect_value(t, a.owner, 777)
	_, handled := shoji.ws_space_place(&a, 42, 10, 20)
	testing.expect(t, !handled)
	testing.expect_value(t, g.calls, 1) // refused adapters never call again
}

@(test)
ws_adapter_identity_mismatch_is_not_serving :: proc(t: ^testing.T) {
	g: Fake_Gate
	g.bad_magic = true
	fake_push(&g, 0)
	a := fake_adapter(&g)
	testing.expect_value(t, a.state, shoji.Ws_Adapter_State.Absent)
}

@(test)
ws_adapter_space_place_round_trip :: proc(t: ^testing.T) {
	g: Fake_Gate
	fake_push(&g, 0) // hello
	fake_push(&g, 0, 42, 5) // space place → generation 5
	fake_push(&g, 0, 5, gate.placement_pack(-600, 400)) // placement status
	a := fake_adapter(&g)
	testing.expect_value(t, a.state, shoji.Ws_Adapter_State.Serving)
	generation, handled := shoji.ws_space_place(&a, 42, -600, 400)
	testing.expect(t, handled)
	testing.expect_value(t, generation, 5)
	testing.expect_value(t, g.commands[1], gate.Gate_Command.SpacePlace)
	placement, ok := shoji.ws_placement_status(&a)
	testing.expect(t, ok)
	testing.expect_value(t, placement.status, 0)
	testing.expect_value(t, placement.generation, 5)
	testing.expect_value(t, placement.x, -600)
	testing.expect_value(t, placement.y, 400)
}

@(test)
ws_adapter_busy_falls_back_but_keeps_serving :: proc(t: ^testing.T) {
	g: Fake_Gate
	fake_push(&g, 0)
	fake_push(&g, shoji.WS_STATUS_BUSY, 42, 4)
	a := fake_adapter(&g)
	_, handled := shoji.ws_space_place(&a, 42, 1, 2)
	testing.expect(t, !handled)
	testing.expect_value(t, a.state, shoji.Ws_Adapter_State.Serving)
}

@(test)
ws_adapter_invalid_coordinates_never_reach_the_gate :: proc(t: ^testing.T) {
	g: Fake_Gate
	fake_push(&g, 0)
	a := fake_adapter(&g)
	_, handled := shoji.ws_space_place(&a, 0, 1, 2)
	testing.expect(t, !handled)
	_, handled = shoji.ws_space_place(&a, 42, 2_000_000, 0)
	testing.expect(t, !handled)
	testing.expect_value(t, g.calls, 1)
}

@(test)
ws_adapter_transport_failure_latches_lost :: proc(t: ^testing.T) {
	g: Fake_Gate
	fake_push(&g, 0)
	fake_push(&g, 0)
	fake_push(&g, 0)
	g.fail_at = 2
	a := fake_adapter(&g)
	_, handled := shoji.ws_watch(&a, 42)
	testing.expect(t, !handled)
	testing.expect_value(t, a.state, shoji.Ws_Adapter_State.Lost)
	// Latched: a healthy gate afterwards is not consulted again.
	_, handled = shoji.ws_watch(&a, 42)
	testing.expect(t, !handled)
	testing.expect_value(t, g.calls, 2)
}

@(test)
ws_adapter_ownership_loss_latches_lost :: proc(t: ^testing.T) {
	g: Fake_Gate
	fake_push(&g, 0)
	fake_push(&g, shoji.WS_STATUS_NOT_OWNER)
	a := fake_adapter(&g)
	_, handled := shoji.ws_receipt(&a, 1)
	testing.expect(t, !handled)
	testing.expect_value(t, a.state, shoji.Ws_Adapter_State.Lost)
}

@(test)
ws_adapter_layout_stages_and_arms :: proc(t: ^testing.T) {
	g: Fake_Gate
	fake_push(&g, 0) // hello
	fake_push(&g, 0) // begin
	fake_push(&g, 0, 1, 10) // add
	fake_push(&g, 0, 2, 11) // add
	fake_push(&g, 0, 99, 3) // arm → generation 3
	fake_push(&g, 0, 3, u64(312) << 32 | 2) // status
	a := fake_adapter(&g)
	generation, handled := shoji.ws_layout_stage(&a, {{10, 0, 0}, {11, 800, 0}}, 99, 8000)
	testing.expect(t, handled)
	testing.expect_value(t, generation, 3)
	testing.expect_value(t, g.commands[4], gate.Gate_Command.LayoutArm)
	result, ok := shoji.ws_layout_status(&a)
	testing.expect(t, ok)
	testing.expect_value(t, result.applied, 2)
	testing.expect_value(t, result.elapsed_us, 312)
}

@(test)
ws_adapter_layout_rejects_before_any_call :: proc(t: ^testing.T) {
	g: Fake_Gate
	fake_push(&g, 0)
	a := fake_adapter(&g)
	too_many: [gate.LAYOUT_LIMIT + 1]shoji.Ws_Layout_Move
	for &move, index in too_many {move = {u32(index + 1), 0, 0}}
	cases := []struct {
		moves:  []shoji.Ws_Layout_Move,
		marker: u32,
		budget: u64,
	} {
		{nil, 9, 4000},
		{too_many[:], 99, 4000},
		{{{9, 0, 0}}, 9, 4000}, // marker inside the plan recurses
		{{{1, 0, 0}}, 0, 4000},
		{{{1, 0, 0}}, 9, 0},
		{{{1, 0, 0}}, 9, 8001}, // above the frame budget
	}
	for c in cases {
		_, handled := shoji.ws_layout_stage(&a, c.moves, c.marker, c.budget)
		testing.expect(t, !handled)
	}
	testing.expect_value(t, g.calls, 1)
	testing.expect_value(t, a.state, shoji.Ws_Adapter_State.Serving)
}

@(test)
ws_adapter_layout_rejected_add_is_unhandled :: proc(t: ^testing.T) {
	g: Fake_Gate
	fake_push(&g, 0)
	fake_push(&g, 0)
	fake_push(&g, shoji.WS_STATUS_MALFORMED)
	a := fake_adapter(&g)
	_, handled := shoji.ws_layout_stage(&a, {{10, 0, 0}, {11, 0, 0}}, 99, 4000)
	testing.expect(t, !handled)
	testing.expect_value(t, g.calls, 3) // never armed
	testing.expect_value(t, a.state, shoji.Ws_Adapter_State.Serving)
}

@(test)
ws_adapter_receipt_kinds :: proc(t: ^testing.T) {
	testing.expect_value(t, shoji.ws_receipt_kind(0), shoji.Ws_Receipt.Fired)
	testing.expect_value(t, shoji.ws_receipt_kind(6), shoji.Ws_Receipt.Pending)
	testing.expect_value(t, shoji.ws_receipt_kind(7), shoji.Ws_Receipt.Stale)
	testing.expect_value(t, shoji.ws_receipt_kind(8), shoji.Ws_Receipt.Idle)
	testing.expect_value(t, shoji.ws_receipt_kind(99), shoji.Ws_Receipt.Unknown)
}

Fake_Dock :: struct {
	calls:                  int,
	target, source:         u64,
	wid:                    u32,
	err:                    string,
}

fake_dock_send :: proc(user: rawptr, target: u64, wid: u32, source: u64) -> string {
	d := (^Fake_Dock)(user)
	d.calls += 1
	d.target, d.wid, d.source = target, wid, source
	return d.err
}

@(test)
ws_space_move_places_inside_the_commit :: proc(t: ^testing.T) {
	g: Fake_Gate
	fake_push(&g, 0) // hello
	fake_push(&g, 0, 42, 9) // SpaceApply → generation 9
	fake_push(&g, 0, 9, gate.placement_pack(500, 30)) // placement applied
	a := fake_adapter(&g)
	d: Fake_Dock
	move := shoji.ws_space_move(&a, 42, 4, 1, 500, 30, fake_dock_send, &d)
	testing.expect(t, move.moved && move.placed)
	testing.expect_value(t, g.commands[1], gate.Gate_Command.SpaceApply)
	testing.expect_value(t, d.target, 4)
	testing.expect_value(t, d.source, 1)
	testing.expect_value(t, d.wid, 42)
	testing.expect_value(t, g.calls, 3) // no release needed
}

@(test)
ws_space_move_unclaimed_stage_is_released :: proc(t: ^testing.T) {
	g: Fake_Gate
	fake_push(&g, 0)
	fake_push(&g, 0, 42, 9)
	fake_push(&g, shoji.WS_STATUS_BUSY, 9) // commit did not pass the gate
	fake_push(&g, 0) // release
	a := fake_adapter(&g)
	d: Fake_Dock
	move := shoji.ws_space_move(&a, 42, 4, 1, 500, 30, fake_dock_send, &d)
	testing.expect(t, move.moved && !move.placed)
	testing.expect_value(t, g.commands[3], gate.Gate_Command.Release)
}

@(test)
ws_space_move_dock_failure_releases_and_falls_back :: proc(t: ^testing.T) {
	g: Fake_Gate
	fake_push(&g, 0)
	fake_push(&g, 0, 42, 9)
	fake_push(&g, 0) // release
	a := fake_adapter(&g)
	d := Fake_Dock{err = "Dock payload lacks transactional Space moves"}
	move := shoji.ws_space_move(&a, 42, 4, 1, 500, 30, fake_dock_send, &d)
	testing.expect(t, !move.moved && !move.placed)
	testing.expect_value(t, g.commands[2], gate.Gate_Command.Release)
}

@(test)
ws_space_move_not_serving_never_moves :: proc(t: ^testing.T) {
	g: Fake_Gate
	fake_push(&g, shoji.WS_STATUS_OWNED, 7)
	a := fake_adapter(&g)
	d: Fake_Dock
	move := shoji.ws_space_move(&a, 42, 4, 1, 500, 30, fake_dock_send, &d)
	testing.expect(t, !move.moved)
	testing.expect_value(t, d.calls, 0)
	// Same-space and busy gate also stay with today's path.
	g2: Fake_Gate
	fake_push(&g2, 0)
	fake_push(&g2, shoji.WS_STATUS_BUSY, 42, 3)
	b := fake_adapter(&g2)
	move = shoji.ws_space_move(&b, 42, 4, 4, 500, 30, fake_dock_send, &d)
	testing.expect(t, !move.moved)
	move = shoji.ws_space_move(&b, 42, 4, 1, 500, 30, fake_dock_send, &d)
	testing.expect(t, !move.moved)
	testing.expect_value(t, d.calls, 0)
}

@(thread_local) order_calls: [4][2]i32
@(thread_local) order_count: int
fake_order :: proc "c" (cid: i32, window: u32, order: i32, relative: u32) -> i32 {
	if order_count < len(order_calls) {order_calls[order_count] = {i32(window), order}}
	order_count += 1
	return 0
}

@(test)
ws_layout_run_orders_marker_and_requires_full_application :: proc(t: ^testing.T) {
	g: Fake_Gate
	fake_push(&g, 0) // hello
	fake_push(&g, 0) // begin
	fake_push(&g, 0, 1, 10)
	fake_push(&g, 0, 2, 11)
	fake_push(&g, 0, 99, 5) // arm gen 5
	fake_push(&g, 0, 5, 2) // status: applied 2
	a := fake_adapter(&g)
	order_count = 0
	ok := shoji.ws_layout_run(&a, {{10, 0, 0}, {11, 800, 0}}, 99, 7, fake_order)
	testing.expect(t, ok)
	testing.expect_value(t, order_count, 2)
	testing.expect_value(t, order_calls[0], [2]i32{99, 1})
	testing.expect_value(t, order_calls[1], [2]i32{99, 0})
}

@(test)
ws_layout_run_unclaimed_plan_is_released :: proc(t: ^testing.T) {
	g: Fake_Gate
	fake_push(&g, 0)
	fake_push(&g, 0)
	fake_push(&g, 0, 1, 10)
	fake_push(&g, 0, 99, 5)
	fake_push(&g, shoji.WS_STATUS_BUSY, 5) // never claimed
	fake_push(&g, 0) // release
	a := fake_adapter(&g)
	order_count = 0
	testing.expect(t, !shoji.ws_layout_run(&a, {{10, 0, 0}}, 99, 7, fake_order))
	testing.expect_value(t, g.commands[5], gate.Gate_Command.Release)
	// Partial application is not success either.
	g2: Fake_Gate
	fake_push(&g2, 0)
	fake_push(&g2, 0)
	fake_push(&g2, 0, 1, 10)
	fake_push(&g2, 0, 2, 11)
	fake_push(&g2, 0, 99, 6)
	fake_push(&g2, 0, 6, 1) // applied 1 of 2
	b := fake_adapter(&g2)
	testing.expect(t, !shoji.ws_layout_run(&b, {{10, 0, 0}, {11, 5, 5}}, 99, 7, fake_order))
}

@(test)
ws_receipt_wait_polls_until_fired_or_deadline :: proc(t: ^testing.T) {
	g: Fake_Gate
	fake_push(&g, 0)
	fake_push(&g, shoji.WS_STATUS_BUSY)
	fake_push(&g, shoji.WS_STATUS_BUSY)
	fake_push(&g, 0) // fired
	a := fake_adapter(&g)
	testing.expect(t, shoji.ws_receipt_wait(&a, 3, 200 * time.Millisecond))
	g2: Fake_Gate
	fake_push(&g2, 0)
	for _ in 0 ..< 30 {fake_push(&g2, shoji.WS_STATUS_BUSY)}
	b := fake_adapter(&g2)
	start := time.now()
	testing.expect(t, !shoji.ws_receipt_wait(&b, 3, 30 * time.Millisecond))
	testing.expect(t, time.since(start) < 500 * time.Millisecond)
	g3: Fake_Gate
	fake_push(&g3, 0)
	fake_push(&g3, shoji.WS_STATUS_STALE)
	c := fake_adapter(&g3)
	testing.expect(t, !shoji.ws_receipt_wait(&c, 3, 200 * time.Millisecond))
}

@(test)
ws_focus_receipt_resolves_on_later_ticks_without_blocking :: proc(t: ^testing.T) {
	g: Fake_Gate
	fake_push(&g, 0)                       // hello
	fake_push(&g, shoji.WS_STATUS_BUSY)    // tick 1: pending, inside window
	fake_push(&g, 0)                       // tick 2: fired
	fake_push(&g, 0)                       // watch 0
	a := fake_adapter(&g)
	start := time.now()
	shoji.ws_focus_pending(&a, 7, 42, start)
	_, _, _, resolved := shoji.ws_focus_tick(&a, time.time_add(start, 10 * time.Millisecond))
	testing.expect(t, !resolved)
	window, outcome, waited, done := shoji.ws_focus_tick(&a, time.time_add(start, 30 * time.Millisecond))
	testing.expect(t, done)
	testing.expect_value(t, window, 42)
	testing.expect_value(t, outcome, shoji.Ws_Receipt.Fired)
	testing.expect_value(t, waited, 30 * time.Millisecond)
	testing.expect_value(t, g.commands[3], gate.Gate_Command.Watch) // watch cancelled
	_, _, _, again := shoji.ws_focus_tick(&a, time.time_add(start, 40 * time.Millisecond))
	testing.expect(t, !again) // nothing armed: no gate call
	testing.expect_value(t, g.calls, 4)
}

@(test)
ws_focus_receipt_times_out_and_cancel_supersedes :: proc(t: ^testing.T) {
	g: Fake_Gate
	fake_push(&g, 0)                    // hello
	fake_push(&g, shoji.WS_STATUS_BUSY) // still pending past the window
	fake_push(&g, 0)                    // watch 0
	fake_push(&g, 0)                    // watch 0 from cancel
	a := fake_adapter(&g)
	start := time.now()
	shoji.ws_focus_pending(&a, 7, 42, start)
	_, outcome, _, done := shoji.ws_focus_tick(&a, time.time_add(start, shoji.WS_FOCUS_RECEIPT_WINDOW))
	testing.expect(t, done)
	testing.expect_value(t, outcome, shoji.Ws_Receipt.Pending)
	testing.expect_value(t, shoji.ws_focus_cancel(&a), 0) // nothing left
	shoji.ws_focus_pending(&a, 8, 43, start)
	testing.expect_value(t, shoji.ws_focus_cancel(&a), 43)
	testing.expect_value(t, g.commands[3], gate.Gate_Command.Watch)
}

@(test)
ws_adapter_capabilities_select_single_message_layout :: proc(t: ^testing.T) {
	g: Fake_Gate
	fake_push(&g, 0) // hello
	fake_push(&g, 0, gate.GATE_FEATURE_LAYOUT_SUBMIT, 32) // capabilities
	fake_push(&g, 0, 99, 7) // submit → generation 7
	a := fake_adapter(&g)
	shoji.ws_adapter_capabilities(&a)
	testing.expect_value(t, shoji.ws_layout_limit(&a), 32)
	moves: [12]shoji.Ws_Layout_Move
	for &move, index in moves {move = {u32(index + 10), i32(index) * 100, 0}}
	generation, handled := shoji.ws_layout_stage(&a, moves[:], 99, 8000)
	testing.expect(t, handled)
	testing.expect_value(t, generation, 7)
	// Twelve moves cost one round trip instead of fourteen.
	testing.expect_value(t, g.calls, 3)
	testing.expect_value(t, g.commands[2], gate.Gate_Command.LayoutSubmit)
	testing.expect_value(t, g.items[2], 12)
}

@(test)
ws_adapter_capabilities_reject_a_foreign_build :: proc(t: ^testing.T) {
	g: Fake_Gate
	fake_push(&g, 0)
	fake_push(&g, 0, gate.GATE_FEATURE_LAYOUT_SUBMIT, 32)
	g.identity = true
	g.rejected = false
	g.uuid = gate.ORDERING_IMAGE_UUID
	g.uuid[0] ~= 0xff
	g.op_count = u32(len(gate.GATED_OPS))
	for op, i in gate.GATED_OPS {g.ops[i] = u32(op)}
	a := fake_adapter(&g)
	shoji.ws_adapter_capabilities(&a)
	testing.expect_value(t, a.state, shoji.Ws_Adapter_State.Serving)
	testing.expect(t, !a.identity_ok)
	testing.expect_value(t, a.features, u64(0))
	testing.expect_value(t, a.layout_limit, 0)
}

@(test)
ws_adapter_capabilities_accept_this_build :: proc(t: ^testing.T) {
	g: Fake_Gate
	fake_push(&g, 0)
	fake_push(&g, 0, gate.GATE_FEATURE_LAYOUT_SUBMIT, u64(gate.LAYOUT_LIMIT))
	g.identity = true
	g.uuid = gate.ORDERING_IMAGE_UUID
	g.op_count = u32(len(gate.GATED_OPS))
	for op, i in gate.GATED_OPS {g.ops[i] = u32(op)}
	a := fake_adapter(&g)
	shoji.ws_adapter_capabilities(&a)
	testing.expect(t, a.identity_ok)
	testing.expect_value(t, a.build_uuid, gate.ORDERING_IMAGE_UUID)
	testing.expect_value(t, a.features, gate.GATE_FEATURE_LAYOUT_SUBMIT)
	testing.expect_value(t, a.layout_limit, gate.LAYOUT_LIMIT)
	testing.expect_value(t, a.gated_op_count, len(gate.GATED_OPS))
}

@(test)
ws_adapter_capabilities_malformed_trailer_leaves_features_off :: proc(t: ^testing.T) {
	g: Fake_Gate
	fake_push(&g, 0)
	fake_push(&g, 0, gate.GATE_FEATURE_LAYOUT_SUBMIT, 32)
	g.rejected = true
	a := fake_adapter(&g)
	shoji.ws_adapter_capabilities(&a)
	testing.expect_value(t, a.state, shoji.Ws_Adapter_State.Serving)
	testing.expect(t, !a.identity_ok)
	testing.expect_value(t, a.features, u64(0))
	testing.expect_value(t, a.layout_limit, 0)
}

@(thread_local) present_send_err: string
present_send :: proc() -> string {return present_send_err}

@(test)
ws_present_stages_when_the_payload_advertises_it :: proc(t: ^testing.T) {
	g: Fake_Gate
	fake_push(&g, 0)
	fake_push(&g, 0, gate.GATE_FEATURE_LAYOUT_SUBMIT | gate.GATE_FEATURE_PRESENT, u64(gate.LAYOUT_LIMIT))
	fake_push(&g, 0, 0, 9) // PresentApply → generation 9
	fake_push(&g, 0) // Release after the send returns
	a := fake_adapter(&g)
	shoji.ws_adapter_capabilities(&a)
	present_send_err = ""
	staged, err := shoji.ws_present(&a, 4, true, false, true, false, present_send)
	testing.expect(t, staged && err == "")
	testing.expect_value(t, g.commands[2], gate.Gate_Command.PresentApply)
	testing.expect_value(t, g.commands[3], gate.Gate_Command.Release)
	testing.expect_value(t, g.calls, 4)
}

@(test)
ws_present_skips_the_gate_when_the_feature_is_absent :: proc(t: ^testing.T) {
	g: Fake_Gate
	fake_push(&g, 0)
	fake_push(&g, 0, gate.GATE_FEATURE_LAYOUT_SUBMIT, 32)
	a := fake_adapter(&g)
	shoji.ws_adapter_capabilities(&a)
	present_send_err = ""
	staged, err := shoji.ws_present(&a, 4, true, false, false, false, present_send)
	testing.expect(t, !staged && err == "")
	testing.expect_value(t, g.calls, 2)
}

@(test)
ws_present_releases_when_the_dock_send_fails :: proc(t: ^testing.T) {
	g: Fake_Gate
	fake_push(&g, 0)
	fake_push(&g, 0, gate.GATE_FEATURE_PRESENT, 32)
	fake_push(&g, 0, 0, 3)
	fake_push(&g, 0) // Release
	a := fake_adapter(&g)
	shoji.ws_adapter_capabilities(&a)
	present_send_err = "dock down"
	staged, err := shoji.ws_present(&a, 4, true, false, false, false, present_send)
	testing.expect(t, staged)
	testing.expect_value(t, err, "dock down")
	testing.expect_value(t, g.commands[3], gate.Gate_Command.Release)
}

@(test)
ws_adapter_old_payload_keeps_legacy_layout :: proc(t: ^testing.T) {
	g: Fake_Gate
	fake_push(&g, 0) // hello
	fake_push(&g, 1) // capabilities: unknown command on an older payload
	a := fake_adapter(&g)
	shoji.ws_adapter_capabilities(&a)
	testing.expect_value(t, a.state, shoji.Ws_Adapter_State.Serving)
	testing.expect_value(t, a.status, i32(0))
	testing.expect_value(t, shoji.ws_layout_limit(&a), gate.GATE_LEGACY_LAYOUT_LIMIT)
	nine: [9]shoji.Ws_Layout_Move
	for &move, index in nine {move = {u32(index + 10), 0, 0}}
	_, handled := shoji.ws_layout_stage(&a, nine[:], 99, 8000)
	testing.expect(t, !handled)
	testing.expect_value(t, g.calls, 2)
}
