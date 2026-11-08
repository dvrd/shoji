package tests

import dock "../src/dock"
import gate "../src/windowserver/gate"
import "core:os"
import "core:sys/posix"
import "core:testing"
import inject "../src/inject"

@(test)
windowserver_client_identity_refuses_unconfigured_mismatched_and_failed_queries :: proc(t: ^testing.T) {
	hash: [20]u8
	hash[0], hash[1] = 0xab, 0xcd
	pin := "abcd000000000000000000000000000000000000"
	testing.expect(t, gate.gate_identity_matches(pin, hash[:], 0))
	testing.expect(t, !gate.gate_identity_matches("", hash[:], 0))
	testing.expect(t, !gate.gate_identity_matches(pin, hash[:], -1))
	testing.expect(t, !gate.gate_identity_matches(pin, hash[:19], 0))
	testing.expect(t, !gate.gate_identity_matches("xbcd000000000000000000000000000000000000", hash[:], 0))
	hash[19] = 1
	testing.expect(t, !gate.gate_identity_matches(pin, hash[:], 0))
}

@(test)
windowserver_target_requires_the_exact_system_executable :: proc(
	t: ^testing.T,
) {
	testing.expect(t, gate.valid_path(gate.PATH))
	testing.expect(t, gate.valid_path(gate.CANONICAL_PATH))
	testing.expect(t, !gate.valid_path(gate.CANONICAL_PATH + ".copy"))
	testing.expect(t, !gate.valid_path("/usr/local/bin/WindowServer"))
	testing.expect(t, !gate.valid_path(gate.PATH + ".copy"))
	testing.expect_value(t, gate.validate_target(123, gate.PATH), "")
	testing.expect_value(
		t,
		gate.validate_target(0, gate.PATH),
		"WindowServer injection requires a positive process ID",
	)
	testing.expect_value(
		t,
		gate.validate_target(123, "/tmp/WindowServer"),
		"target process is not the system WindowServer",
	)
	// Reject this test process before task-port acquisition or helper delegation.
	executable, path_error := os.get_executable_path(context.temp_allocator)
	testing.expect_value(t, path_error, nil)
	testing.expect_value(
		t,
		inject.inject_windowserver(executable, i32(posix.getpid())),
		"target process is not the system WindowServer",
	)
}

@(test)
windowserver_ordering_target_requires_exact_identity_range_and_signature :: proc(t: ^testing.T) {
	location := gate.Ordering_Location {
		uuid = gate.ORDERING_IMAGE_UUID,
		slide = 0x46d8000,
		// Keep the entry inside text for whichever build is selected.
		text_start = 0x46d8000 + gate.ORDERING_UNSLID_ENTRY - 0x463260,
		text_size = 0x1000000,
		candidate = 0x46d8000 + gate.ORDERING_UNSLID_ENTRY,
	}
	testing.expect(t, gate.valid_ordering_location(location))
	signature := gate.ORDERING_ENTRY_SIGNATURE
	testing.expect(t, gate.matches_ordering_entry(location, signature[:]))
	changed := location
	changed.uuid[0] ~= 1
	testing.expect(t, !gate.valid_ordering_location(changed))
	changed = location
	changed.candidate += 4
	testing.expect(t, !gate.valid_ordering_location(changed))
	changed = location
	changed.text_size = u64(location.candidate - location.text_start) + 15
	testing.expect(t, !gate.valid_ordering_location(changed))
	changed = location
	changed.text_start = max(u64) - 7
	changed.text_size = max(u64)
	testing.expect(t, !gate.valid_ordering_location(changed))
	testing.expect(t, !gate.matches_ordering_entry(location, signature[:15]))
	signature[15] ~= 1
	testing.expect(t, !gate.matches_ordering_entry(location, signature[:]))
}

@(test)
windowserver_protocol_has_an_independent_versioned_handshake :: proc(
	t: ^testing.T,
) {
	expected := gate.Capabilities{.Load_Probe}
	p: gate.Packet
	gate.encode_handshake(&p, expected)
	caps, ok := gate.decode_handshake(p.data[:p.count])
	testing.expect(t, ok)
	testing.expect_value(t, caps, expected)

	p.data[0] = 'X'
	_, ok = gate.decode_handshake(p.data[:p.count])
	testing.expect(t, !ok)
	gate.encode_handshake(&p, expected)
	_, ok = gate.decode_handshake(p.data[:p.count - 1])
	testing.expect(t, !ok)
}

@(test)
windowserver_protocol_rejects_unknown_and_trailing_requests :: proc(
	t: ^testing.T,
) {
	p := gate.begin(.Handshake)
	data := gate.finish(&p)
	testing.expect_value(t, len(data), 3)
	testing.expect_value(t, data[0], u8(1))
	testing.expect_value(t, data[1], u8(0))
	testing.expect(t, gate.validate(.Handshake, data[3:]))
	testing.expect(t, !gate.validate(.Handshake, []u8{0}))
	testing.expect(t, !gate.validate(gate.Opcode(255), nil))
}

@(test)
windowserver_gate_handshake_includes_the_descriptor_count :: proc(t: ^testing.T) {
	buf: [128]u8
	n, ok := gate.gate_pack_handshake(buf[:], 11, 22)
	testing.expect(t, ok)
	testing.expect_value(t, n, gate.GATE_HANDSHAKE_SIZE)
	count, count_ok := gate.gate_load_u32(buf[:], gate.GATE_DESC_COUNT_OFF)
	testing.expect(t, count_ok)
	testing.expect_value(t, count, u32(1))
	port, port_ok := gate.gate_handshake_send_right(buf[:])
	testing.expect(t, port_ok)
	testing.expect_value(t, port, u32(22))
	buf[gate.GATE_DESC_COUNT_OFF] = 0
	_, missing := gate.gate_handshake_send_right(buf[:])
	testing.expect(t, !missing)
}

@(test)
windowserver_gate_audit_token_starts_after_the_trailer_prefix :: proc(t: ^testing.T) {
	buf: [128]u8
	testing.expect(t, gate.gate_store_u32(buf[:], 4, u32(gate.GATE_MSG_SIZE)))
	testing.expect(t, gate.gate_store_u32(buf[:], gate.GATE_MSG_SIZE + 4, gate.GATE_AUDIT_TRAILER_SIZE))
	// Plant pid and pidversion where mach_msg_audit_trailer_t puts val[5] and val[7].
	off := gate.GATE_MSG_SIZE + gate.GATE_TRAILER_AUDIT_OFF
	testing.expect(t, gate.gate_store_u32(buf[:], off + 5 * 4, 4242))
	testing.expect(t, gate.gate_store_u32(buf[:], off + 7 * 4, 9))
	token, ok := gate.gate_audit_token(buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, gate.gate_audit_pid(&token), u32(4242))
	testing.expect_value(t, gate.gate_audit_pidversion(&token), u32(9))
	// msgh_size below a header is not a trailer anchor, even if the buffer is long.
	testing.expect(t, gate.gate_store_u32(buf[:], 4, 4))
	_, too_small := gate.gate_audit_token(buf[:])
	testing.expect(t, !too_small)
	_, short := gate.gate_audit_token(buf[:8])
	testing.expect(t, !short)
}

@(test)
windowserver_gate_refuses_missing_and_truncated_audit_trailers :: proc(t: ^testing.T) {
	buf: [128]u8
	gate.gate_store_u32(buf[:], 4, gate.GATE_MSG_SIZE)
	// Plausible identity bytes must not authenticate without trailer metadata.
	gate.gate_store_u32(buf[:], gate.GATE_MSG_SIZE + gate.GATE_TRAILER_AUDIT_OFF + 20, 42)
	_, missing := gate.gate_audit_token(buf[:])
	testing.expect(t, !missing)
	gate.gate_store_u32(buf[:], gate.GATE_MSG_SIZE + 4, gate.GATE_AUDIT_TRAILER_SIZE)
	_, truncated := gate.gate_audit_token(buf[:gate.GATE_MSG_SIZE + gate.GATE_AUDIT_TRAILER_SIZE - 1])
	testing.expect(t, !truncated)
	gate.gate_store_u32(buf[:], gate.GATE_MSG_SIZE, 1)
	_, wrong_type := gate.gate_audit_token(buf[:])
	testing.expect(t, !wrong_type)
	gate.gate_store_u32(buf[:], gate.GATE_MSG_SIZE, 0)
	gate.gate_store_u32(buf[:], gate.GATE_MSG_SIZE + 4, 129)
	_, oversized := gate.gate_audit_token(buf[:])
	testing.expect(t, !oversized)
}

@(test)
windowserver_gate_owner_is_the_first_hello :: proc(t: ^testing.T) {
	pid, version: u32
	testing.expect_value(t, gate.gate_decide(&pid, &version, true, 10, 3, gate.GATE_VERSION, u32(gate.Gate_Command.Arm)), i32(4))
	testing.expect_value(t, gate.gate_decide(&pid, &version, true, 10, 3, gate.GATE_VERSION, u32(gate.Gate_Command.Hello)), i32(0))
	testing.expect_value(t, pid, u32(10))
	testing.expect_value(t, version, u32(3))
	testing.expect_value(t, gate.gate_decide(&pid, &version, true, 10, 3, gate.GATE_VERSION, u32(gate.Gate_Command.Arm)), i32(0))
	testing.expect_value(t, gate.gate_decide(&pid, &version, true, 11, 3, gate.GATE_VERSION, u32(gate.Gate_Command.Hello)), i32(3))
	testing.expect_value(t, gate.gate_decide(&pid, &version, true, 10, 4, gate.GATE_VERSION, u32(gate.Gate_Command.Release)), i32(4))
	testing.expect_value(t, gate.gate_decide(&pid, &version, true, 10, 3, 99, u32(gate.Gate_Command.Status)), i32(1))
	testing.expect_value(t, gate.gate_decide(&pid, &version, false, 10, 3, gate.GATE_VERSION, u32(gate.Gate_Command.Dump)), i32(4))
	testing.expect_value(t, gate.gate_decide(&pid, &version, true, 10, 3, gate.GATE_VERSION, 99), i32(1))
}

gate_test_append_dec :: proc(dst: []u8, n: int, value: u64) -> (out: int, ok: bool) {
	digits: [20]u8
	count := 0
	rest := value
	if rest == 0 {
		digits[0] = '0'
		count = 1
	} else {
		for rest > 0 && count < len(digits) {
			digits[count] = u8('0' + rest % 10)
			count += 1
			rest /= 10
		}
	}
	if n + count + 1 > len(dst) {return n, false}
	pos := n
	for i := count - 1; i >= 0; i -= 1 {
		dst[pos] = digits[i]
		pos += 1
	}
	return pos, true
}

gate_test_name :: proc(dst: []u8, pid: int, stamp: u64) -> (name: cstring, ok: bool) {
	prefix := "com.shoji.gate.test."
	n := 0
	for ch in prefix {
		if n >= len(dst) - 1 {return}
		dst[n] = u8(ch)
		n += 1
	}
	n, ok = gate_test_append_dec(dst, n, u64(pid))
	if !ok || n >= len(dst) - 1 {return}
	dst[n] = '.'
	n += 1
	n, ok = gate_test_append_dec(dst, n, stamp)
	if !ok || n >= len(dst) {return}
	dst[n] = 0
	return cstring(&dst[0]), true
}

@(test)
windowserver_gate_mach_round_trip_reports_this_process :: proc(t: ^testing.T) {
	task := gate.gate_mach_task_self()
	testing.expect(t, task != 0)
	bp, bp_ok := gate.gate_process_bootstrap_port()
	testing.expect(t, bp_ok)
	if task == 0 || !bp_ok {return}

	service: u32
	if code := gate.gate_mach_port_allocate(task, gate.MACH_PORT_RIGHT_RECEIVE, &service); code != 0 {
		testing.expect_value(t, code, i32(0))
		return
	}
	defer gate.gate_mach_port_destroy(task, service)
	if code := gate.gate_mach_port_insert_right(task, service, service, gate.MACH_MSG_TYPE_MAKE_SEND); code != 0 {
		testing.expect_value(t, code, i32(0))
		return
	}
	rendezvous: u32
	if code := gate.gate_mach_port_allocate(task, gate.MACH_PORT_RIGHT_RECEIVE, &rendezvous); code != 0 {
		testing.expect_value(t, code, i32(0))
		return
	}
	defer gate.gate_mach_port_destroy(task, rendezvous)

	name_buf: [96]u8
	stamp := u64(uintptr(&name_buf[0]))
	service_name, name_ok := gate_test_name(name_buf[:], int(posix.getpid()), stamp)
	testing.expect(t, name_ok)
	if !name_ok {return}
	if code := gate.gate_bootstrap_register(bp, service_name, rendezvous); code != 0 {
		testing.expect_value(t, code, i32(0))
		return
	}
	client: u32
	if code := gate.gate_bootstrap_look_up(bp, service_name, &client); code != 0 {
		testing.expect_value(t, code, i32(0))
		return
	}
	defer gate.gate_mach_port_deallocate(task, client)

	Align :: struct #align(16) {bytes: [128]u8}
	handshake: Align
	n, packed := gate.gate_pack_handshake(handshake.bytes[:], client, service)
	testing.expect(t, packed)
	if !packed {return}
	if code := gate.gate_mach_msg(&handshake.bytes[0], gate.MACH_MSG_SEND, u32(n), 0, 0, 0, 0); code != 0 {
		testing.expect_value(t, code, i32(0))
		return
	}
	received: Align
	if code := gate.gate_mach_msg(&received.bytes[0], gate.MACH_MSG_RECEIVE | gate.MACH_RCV_TIMEOUT, 0, len(received.bytes), rendezvous, 1000, 0); code != 0 {
		testing.expect_value(t, code, i32(0))
		return
	}
	got, got_ok := gate.gate_handshake_send_right(received.bytes[:])
	testing.expect(t, got_ok)
	if !got_ok {return}
	defer gate.gate_mach_port_deallocate(task, got)

	reply_port: u32
	if code := gate.gate_mach_port_allocate(task, gate.MACH_PORT_RIGHT_RECEIVE, &reply_port); code != 0 {
		testing.expect_value(t, code, i32(0))
		return
	}
	defer gate.gate_mach_port_destroy(task, reply_port)
	request: Align
	rn, request_ok := gate.gate_pack_request(request.bytes[:], got, reply_port, .Hello, 0x53484f4a, 0)
	testing.expect(t, request_ok)
	if !request_ok {return}
	if code := gate.gate_mach_msg(&request.bytes[0], gate.MACH_MSG_SEND, u32(rn), 0, 0, 0, 0); code != 0 {
		testing.expect_value(t, code, i32(0))
		return
	}
	incoming: Align
	if code := gate.gate_mach_msg(&incoming.bytes[0], gate.gate_receive_audit_options(), 0, len(incoming.bytes), service, 1000, 0); code != 0 {
		testing.expect_value(t, code, i32(0))
		return
	}
	token, token_ok := gate.gate_audit_token(incoming.bytes[:])
	testing.expect(t, token_ok)
	if !token_ok {return}
	testing.expect_value(t, gate.gate_audit_pid(&token), u32(posix.getpid()))
	testing.expect(t, gate.gate_audit_pidversion(&token) != 0)
	identity_hash: [20]u8
	identity_status := gate.csops_audittoken(i32(posix.getpid()), 5, &identity_hash, len(identity_hash), &token)
	testing.expect_value(t, identity_status, i32(0))
	identity_hex: [40]u8
	hex_digits := "0123456789abcdef"
	for byte, i in identity_hash {
		identity_hex[i*2] = hex_digits[byte >> 4]
		identity_hex[i*2+1] = hex_digits[byte & 15]
	}
	testing.expect(t, gate.gate_client_identity(&token, string(identity_hex[:])))
	stale_token := token
	stale_token.val[7] += 1
	testing.expect(t, !gate.gate_client_identity(&stale_token, string(identity_hex[:])))

	reply_right, right_ok := gate.gate_received_reply_right(incoming.bytes[:])
	testing.expect(t, right_ok)
	if !right_ok {return}
	owner_pid := gate.gate_audit_pid(&token)
	owner_version := gate.gate_audit_pidversion(&token)
	status := gate.gate_decide(&owner_pid, &owner_version, true, owner_pid, owner_version, gate.GATE_VERSION, u32(gate.Gate_Command.Hello))
	reply: Align
	reply_n, reply_ok := gate.gate_pack_reply(reply.bytes[:], reply_right, u32(gate.Gate_Command.Hello), status, u64(owner_pid), 0x53484f4a)
	testing.expect(t, reply_ok)
	if !reply_ok {return}
	if code := gate.gate_mach_msg(&reply.bytes[0], gate.MACH_MSG_SEND, u32(reply_n), 0, 0, 0, 0); code != 0 {
		testing.expect_value(t, code, i32(0))
		return
	}
	final: Align
	if code := gate.gate_mach_msg(&final.bytes[0], gate.MACH_MSG_RECEIVE | gate.MACH_RCV_TIMEOUT, 0, len(final.bytes), reply_port, 1000, 0); code != 0 {
		testing.expect_value(t, code, i32(0))
		return
	}
	parsed, parsed_ok := gate.gate_unpack_reply(final.bytes[:])
	testing.expect(t, parsed_ok)
	if !parsed_ok {return}
	testing.expect_value(t, parsed.magic, gate.GATE_REPLY_MAGIC)
	testing.expect_value(t, parsed.status, i32(0))
	testing.expect_value(t, parsed.data0, u64(posix.getpid()))

	// A second command needs a fresh send-once from the same receive right.
	status_req: Align
	sn, status_ok := gate.gate_pack_request(status_req.bytes[:], got, reply_port, .Status, 0, 0)
	testing.expect(t, status_ok)
	if !status_ok {return}
	if code := gate.gate_mach_msg(&status_req.bytes[0], gate.MACH_MSG_SEND, u32(sn), 0, 0, 0, 0); code != 0 {
		testing.expect_value(t, code, i32(0))
		return
	}
	status_in: Align
	if code := gate.gate_mach_msg(&status_in.bytes[0], gate.gate_receive_audit_options(), 0, len(status_in.bytes), service, 1000, 0); code != 0 {
		testing.expect_value(t, code, i32(0))
		return
	}
	status_right, status_right_ok := gate.gate_received_reply_right(status_in.bytes[:])
	testing.expect(t, status_right_ok)
	if !status_right_ok {return}
	status_reply: Align
	srn, status_reply_ok := gate.gate_pack_reply(status_reply.bytes[:], status_right, u32(gate.Gate_Command.Status), 0, 1, 2)
	testing.expect(t, status_reply_ok)
	if !status_reply_ok {return}
	if code := gate.gate_mach_msg(&status_reply.bytes[0], gate.MACH_MSG_SEND, u32(srn), 0, 0, 0, 0); code != 0 {
		testing.expect_value(t, code, i32(0))
		return
	}
	status_final: Align
	if code := gate.gate_mach_msg(&status_final.bytes[0], gate.MACH_MSG_RECEIVE|gate.MACH_RCV_TIMEOUT, 0, len(status_final.bytes), reply_port, 1000, 0); code != 0 {
		testing.expect_value(t, code, i32(0))
		return
	}
	status_parsed, status_parsed_ok := gate.gate_unpack_reply(status_final.bytes[:])
	testing.expect(t, status_parsed_ok)
	if !status_parsed_ok {return}
	testing.expect_value(t, status_parsed.command, u32(gate.Gate_Command.Status))
	testing.expect_value(t, status_parsed.status, i32(0))
	testing.expect_value(t, status_parsed.data0, u64(1))
	testing.expect_value(t, status_parsed.data1, u64(2))
}

@(test)
windowserver_layout_plan_is_bounded_sealed_and_validated :: proc(t: ^testing.T) {
	plan: gate.Layout_Plan
	testing.expect(t, !gate.layout_add(&plan, 42, 100, 450))
	gate.layout_begin(&plan)
	testing.expect(t, !gate.layout_seal(&plan, 99, 8000))
	testing.expect(t, !gate.layout_add(&plan, 0, 100, 450))
	testing.expect(t, !gate.layout_add(&plan, 42, 1_000_001, 450))
	testing.expect(t, gate.layout_add(&plan, 42, -100, 450))
	testing.expect(t, !gate.layout_add(&plan, 42, 100, 450))
	testing.expect(t, !gate.layout_seal(&plan, 42, 8000))
	testing.expect(t, !gate.layout_seal(&plan, 99, 8001))
	for index in 1 ..< gate.LAYOUT_LIMIT {testing.expect(t, gate.layout_add(&plan, u64(42 + index), 400, 450))}
	testing.expect(t, !gate.layout_add(&plan, 88, 400, 450))
	testing.expect(t, gate.layout_seal(&plan, 99, 8000))
	testing.expect(t, !gate.layout_add(&plan, 88, 400, 450))
	testing.expect(t, !gate.layout_seal(&plan, 99, 8000))
	testing.expect_value(t, plan.count, u32(gate.LAYOUT_LIMIT))
	pid, version := u32(10), u32(3)
	testing.expect_value(t, gate.gate_decide(&pid, &version, true, 11, 3, gate.GATE_VERSION, u32(gate.Gate_Command.LayoutArm)), i32(4))
}

@(test)
windowserver_placement_validates_coordinates_and_requires_owner :: proc(t: ^testing.T) {
	packed := gate.placement_pack(-600, 400)
	x, y := gate.placement_unpack(packed)
	testing.expect_value(t, x, i32(-600))
	testing.expect_value(t, y, i32(400))
	testing.expect(t, gate.placement_coordinates_valid(42, i64(x), i64(y)))
	testing.expect(t, !gate.placement_coordinates_valid(0, 600, 400))
	testing.expect(t, !gate.placement_coordinates_valid(u64(max(u32)) + 1, 600, 400))
	testing.expect(t, !gate.placement_coordinates_valid(42, 1_000_001, 400))
	pid, version := u32(10), u32(3)
	testing.expect_value(t, gate.gate_decide(&pid, &version, true, 11, 3, gate.GATE_VERSION, u32(gate.Gate_Command.ArmPlace)), i32(4))
	testing.expect_value(t, gate.gate_decide(&pid, &version, true, 10, 3, gate.GATE_VERSION, u32(gate.Gate_Command.ArmPlace)), i32(0))
}

@(test)
windowserver_claimed_release_stays_busy_until_forward_finishes :: proc(t: ^testing.T) {
	slot: gate.Hold_Slot
	generation, armed := gate.hold_arm(&slot, 42, gate.HOLD_SCOPE_INLINE)
	testing.expect(t, armed)
	testing.expect(t, gate.hold_try_claim(&slot, 42, true))
	gate.hold_release(&slot, generation)
	testing.expect(t, gate.hold_released(&slot, true))
	_, rearmed := gate.hold_arm(&slot, 77, gate.HOLD_SCOPE_INLINE)
	testing.expect(t, !rearmed)
	gate.hold_finish(&slot)
	_, rearmed_after_forward := gate.hold_arm(&slot, 77, gate.HOLD_SCOPE_INLINE)
	testing.expect(t, rearmed_after_forward)
}

@(test)
windowserver_receipt_is_once_only_and_generation_bound :: proc(t: ^testing.T) {
	slot: gate.Receipt_Slot
	take_status :: proc(slot: ^gate.Receipt_Slot, generation: u32) -> i32 {
		status, _, _ := gate.receipt_take(slot, generation)
		return status
	}
	// Nothing armed: idle.
	testing.expect_value(t, take_status(&slot, 0), i32(8))
	// Arm: generation 1, pending until the matching order-in forwards.
	gen, ok := gate.receipt_arm(&slot, 42)
	testing.expect(t, ok)
	testing.expect_value(t, gen, u32(1))
	testing.expect_value(t, take_status(&slot, 1), i32(6)) // pending
	// A busy arm is refused and reports the live generation.
	gen2, ok2 := gate.receipt_arm(&slot, 77)
	testing.expect(t, !ok2)
	testing.expect_value(t, gen2, u32(1))
	testing.expect_value(t, slot.target, u64(42))
	// A non-matching window does not fire.
	testing.expect(t, !gate.receipt_fire(&slot, 43, 0, 100))
	testing.expect_value(t, take_status(&slot, 1), i32(6))
	// The matching order-in fires exactly once; a stale generation is refused.
	testing.expect(t, gate.receipt_fire(&slot, 42, -17, 12345))
	testing.expect(t, !gate.receipt_fire(&slot, 42, 0, 12346))
	testing.expect_value(t, take_status(&slot, 99), i32(7))
	status, result, ticks := gate.receipt_take(&slot, 1)
	testing.expect_value(t, status, i32(0))
	testing.expect_value(t, result, i32(-17))
	testing.expect_value(t, ticks, u64(12345))
	// Consumed: the next read is idle.
	testing.expect_value(t, take_status(&slot, 1), i32(8))
	// Cancel before fire: pending work is dropped and a re-arm bumps the
	// generation so the canceled receipt cannot be replayed.
	_, ok3 := gate.receipt_arm(&slot, 55)
	testing.expect(t, ok3)
	gate.receipt_cancel(&slot)
	testing.expect_value(t, take_status(&slot, 2), i32(8))
	gen4, ok4 := gate.receipt_arm(&slot, 55)
	testing.expect(t, ok4)
	testing.expect_value(t, gen4, u32(3))
}

@(test)
windowserver_gate_accepts_watch_commands :: proc(t: ^testing.T) {
	pid, version: u32
	// Watch (12) and WatchStatus (13) are in the accepted command range.
	testing.expect_value(
		t,
		gate.gate_decide(&pid, &version, true, 10, 3, gate.GATE_VERSION, u32(gate.Gate_Command.Watch)),
		i32(4), // unowned: not the owner, but well-formed
	)
	testing.expect_value(
		t,
		gate.gate_decide(&pid, &version, true, 10, 3, gate.GATE_VERSION, u32(gate.Gate_Command.WatchStatus)),
		i32(4),
	)
}
@(test)
windowserver_hold_slot_transitions_are_bounded_and_generation_checked :: proc(t: ^testing.T) {
	slot: gate.Hold_Slot
	// Busy arm is rejected and keeps the original target and generation.
	gen, ok := gate.hold_arm(&slot, 42, gate.HOLD_SCOPE_INLINE)
	testing.expect(t, ok)
	testing.expect_value(t, gen, u32(1))
	_, _, busy := gate.hold_busy(&slot)
	testing.expect(t, busy)
	gen2, ok2 := gate.hold_arm(&slot, 77, gate.HOLD_SCOPE_TABLE)
	testing.expect(t, !ok2)
	testing.expect_value(t, gen2, u32(1))
	testing.expect_value(t, slot.target, u64(42))
	// Scope: table claim is refused, wrong window is refused.
	testing.expect(t, !gate.hold_try_claim(&slot, 42, false))
	testing.expect(t, !gate.hold_try_claim(&slot, 43, true))
	// Exactly one inline claim wins.
	testing.expect(t, gate.hold_try_claim(&slot, 42, true))
	testing.expect(t, !gate.hold_try_claim(&slot, 42, true))
	// Finish returns the slot to free; the consumed claim flag stays consumed.
	gate.hold_finish(&slot)
	_, _, busy2 := gate.hold_busy(&slot)
	testing.expect(t, !busy2)
	gen3, ok3 := gate.hold_arm(&slot, 42, gate.HOLD_SCOPE_INLINE)
	testing.expect(t, ok3)
	testing.expect_value(t, gen3, u32(2))
	// Stale generation release is rejected and leaves the slot armed.
	target7, status7 := gate.hold_release(&slot, 99)
	testing.expect_value(t, status7, i32(7))
	testing.expect_value(t, target7, u64(42))
	_, _, busy3 := gate.hold_busy(&slot)
	testing.expect(t, busy3)
	// Current generation releases; a second release is an idempotent no-op.
	target0, status0 := gate.hold_release(&slot, 2)
	testing.expect_value(t, status0, i32(0))
	testing.expect_value(t, target0, u64(42))
	target_again, status_again := gate.hold_release(&slot, 2)
	testing.expect_value(t, status_again, i32(0))
	testing.expect_value(t, target_again, u64(0))
	// Release before any claim cancels the arm: no claim afterwards.
	gen4, ok4 := gate.hold_arm(&slot, 55, gate.HOLD_SCOPE_INLINE | gate.HOLD_SCOPE_TABLE)
	testing.expect(t, ok4)
	testing.expect_value(t, gen4, u32(3))
	gate.hold_release(&slot, 0)
	testing.expect(t, !gate.hold_try_claim(&slot, 55, true))
	testing.expect(t, !gate.hold_try_claim(&slot, 55, false))
	// Table scope arms and claims independently.
	_, ok5 := gate.hold_arm(&slot, 66, gate.HOLD_SCOPE_TABLE)
	testing.expect(t, ok5)
	testing.expect(t, !gate.hold_try_claim(&slot, 66, true))
	testing.expect(t, gate.hold_try_claim(&slot, 66, false))
	testing.expect(t, !gate.hold_released(&slot, false))
	gate.hold_release(&slot, 4)
	testing.expect(t, gate.hold_released(&slot, false))
	testing.expect(t, gate.hold_released(&slot, true))
}

@(test)
gate_space_apply_is_owner_only_and_bounds_the_command_set :: proc(t: ^testing.T) {
	pid, version: u32
	testing.expect_value(t, gate.gate_decide(&pid, &version, true, 10, 3, gate.GATE_VERSION, u32(gate.Gate_Command.Hello)), i32(0))
	testing.expect_value(t, gate.gate_decide(&pid, &version, true, 10, 3, gate.GATE_VERSION, u32(gate.Gate_Command.SpaceApply)), i32(0))
	testing.expect_value(t, gate.gate_decide(&pid, &version, true, 11, 3, gate.GATE_VERSION, u32(gate.Gate_Command.SpaceApply)), i32(4))
	testing.expect_value(t, gate.gate_decide(&pid, &version, true, 10, 3, gate.GATE_VERSION, u32(gate.Gate_Command.LayoutSubmit) + 1), i32(1))
}

@(test)
gate_reclaim_only_from_a_confirmed_dead_owner :: proc(t: ^testing.T) {
	testing.expect(t, !gate.gate_should_reclaim(0, 0, 20, 1, false)) // unowned: normal claim
	testing.expect(t, !gate.gate_should_reclaim(10, 3, 20, 1, true)) // live owner keeps it
	testing.expect(t, !gate.gate_should_reclaim(10, 3, 10, 3, false)) // owner re-hello
	testing.expect(t, gate.gate_should_reclaim(10, 3, 20, 1, false))
	testing.expect(t, gate.gate_should_reclaim(10, 3, 10, 4, false)) // reused pid, new process
	// After reclaim the predicate's caller clears the owner; first HELLO wins.
	pid, version := u32(0), u32(0)
	testing.expect_value(t, gate.gate_decide(&pid, &version, true, 20, 1, gate.GATE_VERSION, u32(gate.Gate_Command.Hello)), i32(0))
	testing.expect_value(t, pid, 20)
}

@(test)
dock_space_transaction_opcode_is_fixed_size :: proc(t: ^testing.T) {
	data: [20]u8
	testing.expect(t, dock.validate(.Window_To_Space_Transaction, data[:]))
	testing.expect(t, !dock.validate(.Window_To_Space_Transaction, data[:12]))
}

@(test)
dock_conceal_opcode_is_window_and_flag :: proc(t: ^testing.T) {
	data: [5]u8
	testing.expect(t, dock.validate(.Window_Conceal, data[:]))
	testing.expect(t, !dock.validate(.Window_Conceal, data[:4]))
	testing.expect(t, !dock.validate(dock.Opcode(u8(dock.Opcode.Window_Conceal) + 1), data[:]))
}

@(test)
gate_allowlist_accepts_newline_and_comma_lists :: proc(t: ^testing.T) {
	a :: "0123456789abcdef0123456789abcdef01234567"
	b :: "89abcdef89abcdef89abcdef89abcdef89abcdef"
	pattern := [4]u8{0x89, 0xab, 0xcd, 0xef}
	hash: [20]u8
	for i in 0 ..< 20 {hash[i] = pattern[i % 4]}
	testing.expect(t, gate.gate_identity_matches_any(b, hash[:], 0))
	for list in ([]string{a + "\n" + b + "\n", a + "," + b, "\n\n" + b, a + "\r\n" + b + "\r\n"}) {
		testing.expect(t, gate.gate_identity_matches_any(list, hash[:], 0))
	}
	for list in ([]string{a, "", "\n", b[:39], b + "x", "89ABCDEF89ABCDEF89ABCDEF89ABCDEF89ABCDEF"}) {
		testing.expect(t, !gate.gate_identity_matches_any(list, hash[:], 0))
	}
	testing.expect(t, !gate.gate_identity_matches_any(b, hash[:], 1)) // kernel query failed
}

@(test)
gate_allowlist_file_trusted_only_when_root_owned_and_unwritable :: proc(t: ^testing.T) {
	file, dir := u32(0o100644), u32(0o040755)
	testing.expect(t, gate.gate_allowlist_trusted(0, file, 41, 0, dir))
	testing.expect(t, !gate.gate_allowlist_trusted(501, file, 41, 0, dir))          // user-owned file
	testing.expect(t, !gate.gate_allowlist_trusted(0, 0o100664, 41, 0, dir))        // group-writable
	testing.expect(t, !gate.gate_allowlist_trusted(0, 0o100646, 41, 0, dir))        // world-writable
	testing.expect(t, !gate.gate_allowlist_trusted(0, 0o120644, 41, 0, dir))        // symlink
	testing.expect(t, !gate.gate_allowlist_trusted(0, file, 0, 0, dir))             // empty
	testing.expect(t, !gate.gate_allowlist_trusted(0, file, gate.GATE_CLIENTS_LIMIT + 1, 0, dir))
	testing.expect(t, !gate.gate_allowlist_trusted(0, file, 41, 501, dir))          // user-owned dir
	testing.expect(t, !gate.gate_allowlist_trusted(0, file, 41, 0, 0o040777))       // writable dir: swap
	testing.expect(t, !gate.gate_allowlist_trusted(0, file, 41, 0, 0o120755))       // dir is a symlink
}

@(test)
dispatch_redirect_encoder_reproduces_skylight_instructions :: proc(t: ^testing.T) {
	// 26B123 and 26A434 PKGTransactionCommit table loads, from the build models.
	cases := [2]struct {
		pc, table: u64,
		words: [2]u32,
	}{
		{0x182a57f04, 0x1e22470a8, {0x902fbf98, 0x9102a318}},
		{0x187451678, 0x1e873d430, {0x90309778, 0x9110c318}},
	}
	for c in cases {
		words, ok := gate.encode_adrp_add(c.pc, c.table, 24)
		testing.expect(t, ok)
		testing.expect_value(t, words, c.words)
	}
	backward, back_ok := gate.encode_adrp_add(0x199ee7f04, 0x11d9b4000, 24)
	testing.expect(t, back_ok)
	testing.expect_value(t, backward[1], u32(0x91000318))
	_, far_ok := gate.encode_adrp_add(0x199ee7f04, 0x299ee8000, 24)
	testing.expect(t, !far_ok)
	_, register_ok := gate.encode_adrp_add(0x1000, 0x2000, 31)
	testing.expect(t, !register_ok)
}

@(test)
gate_layout_submit_round_trips_items_and_rejects_bad_sizes :: proc(t: ^testing.T) {
	buffer: [gate.GATE_RECEIVE_BUFFER_SIZE]u8
	items := []gate.Layout_Item{{10, -1200, 25}, {11, 0, 0}, {12, 3000, 900}}
	n, ok := gate.gate_pack_request(buffer[:], 1, 2, .LayoutSubmit, 99, 8000, items)
	testing.expect(t, ok)
	testing.expect_value(t, n, gate.GATE_ITEMS_OFF + 3 * gate.GATE_ITEM_SIZE)
	request, request_ok := gate.gate_unpack_request(buffer[:])
	testing.expect(t, request_ok)
	testing.expect_value(t, request.command, u32(gate.Gate_Command.LayoutSubmit))
	testing.expect_value(t, request.arg0, u64(99))
	decoded, count, decoded_ok := gate.gate_unpack_items(buffer[:])
	testing.expect(t, decoded_ok)
	testing.expect_value(t, count, 3)
	for item, index in items {testing.expect_value(t, decoded[index], item)}
	// A count that disagrees with msgh_size is refused, never read past.
	gate.gate_store_u32(buffer[:], gate.GATE_ITEMS_HEADER_OFF, 4)
	_, _, mismatch_ok := gate.gate_unpack_items(buffer[:])
	testing.expect(t, !mismatch_ok)
	plain, plain_ok := gate.gate_pack_request(buffer[:], 1, 2, .Status, 0, 0)
	testing.expect(t, plain_ok)
	testing.expect_value(t, plain, gate.GATE_MSG_SIZE)
	_, _, empty_ok := gate.gate_unpack_items(buffer[:])
	testing.expect(t, !empty_ok)
	too_many: [gate.LAYOUT_LIMIT + 1]gate.Layout_Item
	_, over_ok := gate.gate_pack_request(buffer[:], 1, 2, .LayoutSubmit, 99, 8000, too_many[:])
	testing.expect(t, !over_ok)
}

@(test)
gate_accepts_capabilities_and_submit_from_the_owner :: proc(t: ^testing.T) {
	pid, version: u32 = 10, 3
	for command in ([2]gate.Gate_Command{.Capabilities, .LayoutSubmit}) {
		testing.expect_value(t, gate.gate_decide(&pid, &version, true, 10, 3, gate.GATE_VERSION, u32(command)), i32(0))
		testing.expect_value(t, gate.gate_decide(&pid, &version, true, 11, 3, gate.GATE_VERSION, u32(command)), i32(4))
	}
	testing.expect_value(t, gate.gate_decide(&pid, &version, true, 10, 3, gate.GATE_VERSION, u32(gate.Gate_Command.LayoutSubmit) + 1), i32(1))
}
