package windowserver_payload

// Exact-build WindowServer payload: ordering hook, transaction-table gate and
// the authenticated Mach gate that Shoji drives. Loaded by `shoji --ws-attach`
// (root, pinned sudoers rule); the test harness builds this same source with
// its gate client's CDHash pinned (SHOJI_GATE_CLIENT_CDHASH). The ordering
// callback records a bounded in-memory snapshot and forwards immediately; file
// I/O runs on a separate control thread after installation. There is no live
// unhook path: the payload stays resident until WindowServer exits.
import "base:intrinsics"
import "base:runtime"
import "core:sys/posix"
import mach "core:sys/darwin"
import gate "../../windowserver/gate"
import inject "../../inject"

foreign import system "system:System"

Image_Info :: struct {
	path: cstring,
	base: rawptr,
	symbol: cstring,
	address: rawptr,
}
Region_Info :: struct {
	protection, max_protection: i32,
	share_mode: u8,
}
Ordering_Callback :: proc "c" (connection: rawptr, ids: [^]u32, operations: [^]i32, relative: [^]u32, count: u32, flag: u32) -> i32
Mach_Protect :: proc "c" (task: u32, address, size: u64, maximum, protection: i32) -> i32

OBSERVER_EVENTS :: 256
Observer_Event :: struct {
	sequence, connection, before, after: u64,
	count, flag: u32,
	result: i32,
	captured, held: u32,
	ids: [4]u32,
	operations: [4]i32,
	relative: [4]u32,
}
Observer_Response :: struct {
	magic: [8]u8,
	version, calls: u64,
	entry, branch_word: u64,
	timebase_numer, timebase_denom, torn: u32,
	events: [OBSERVER_EVENTS]Observer_Event,
}
Install_Result :: struct {
	magic: [8]u8,
	version, status: u64,
	uuid: [16]u8,
	slide, candidate, trampoline, relay: u64,
	privatize_code, execute_code, install_code: i64,
	barrier_leave_code, thread_create_code: i64,
	initial_current, initial_max, final_current, final_max: i64,
	setup_code, allocation_code, search_count: i64,
	first_candidate, image_base: u64,
	entry_bytes: [16]u8,
	threads: u64,
	// Last thread the barrier could not park (status 5): Mach run state and
	// suspend count. Appended so older readers of the prefix still work.
	barrier_run_state, barrier_suspend_count: i64,
}

STATUS_PATH :: gate.OBSERVER_STATUS_PATH
STARTED_PATH :: gate.OBSERVER_STARTED_PATH
RESPONSE_PATH :: gate.OBSERVER_RESPONSE_PATH

@(default_calling_convention = "c")
foreign system {
	dladdr :: proc(address: rawptr, info: ^Image_Info) -> i32 ---
	proc_pidpath :: proc(pid: i32, buffer: [^]u8, size: u32) -> i32 ---
	@(link_name = "write") write_fd :: proc "c" (fd: i32, data: rawptr, size: uint) -> int ---
	@(link_name = "close") close_fd :: proc "c" (fd: i32) -> i32 ---
	@(link_name = "rename") rename_file :: proc "c" (from, to: cstring) -> i32 ---
	@(link_name = "mach_timebase_info") mach_timebase_info :: proc "c" (info: ^Timebase_Info) -> i32 ---
	usleep :: proc(microseconds: u32) -> i32 ---
	mach_absolute_time :: proc() -> u64 ---
	mach_vm_region_recurse :: proc(task: u32, address, size: ^u64, depth: ^u32, info: ^u32, count: ^u32) -> i32 ---
}

Timebase_Info :: struct {
	numer, denom: u32,
}

observer_original: Ordering_Callback
observer_start_calls, observer_calls: u64
observer_entry: u64
observer_branch: u32
observer_timebase: Timebase_Info
observer_events: [OBSERVER_EVENTS]Observer_Event

// ===== Transaction table gate (A2) =====
// Static model: PKGTransactionCommit dispatches ops through a
// per-build global table (gate.TABLE_UNSLID), 140 entries of 16 bytes, op
// types 1..0x8c. Handlers are PAC-signed pointers called via blraaz (key A,
// discriminator 0) with a shared PKGTransactionContext* argument.
TGATE_STATUS_PATH :: gate.TGATE_STATUS_PATH
TABLE_UNSLID :: gate.TABLE_UNSLID
TABLE_OP_MAX :: 0x8c
GATED_OPS :: [14]u64{0x01, 0x03, 0x06, 0x0b, 0x18, 0x19, 0x21, 0x22, 0x2a, 0x33, 0x34, 0x35, 0x36, 0x41}
GATE_EVENT_FLAG :: 0x54474154 // 'TGAT'

Gate_Expected_Op :: struct {
	op:     u64,
	unslid: u64,
}
// gate_expected_ops (all 139 named ops) lives in gate_expected.odin.

Tgate_Status :: gate.Tgate_Status

gate_originals: [TABLE_OP_MAX + 1]u64
gate_stubs: u64

// Hold state machine (B2): one bounded slot for both hold scopes. Armed
// only through the control thread (gate Arm or the file fallback); claims
// happen on WindowServer threads in the two forwarding callbacks.
hold: gate.Hold_Slot

// Ordering receipt (C2): once-only completion signal for a watched window's
// order-in, recorded by the forwarding callback without sleeping.
watch: gate.Receipt_Slot

// Mach gate service (B1). WindowServer cannot use the bootstrap server, so
// the root `shoji --ws-attach` helper copies a send right out of this task
// and hands it to the daemon. Commands are accepted only from the owner
// process, identified by audit-token pid + pidversion (first HELLO wins).
gate_mach_port: u32
gate_mach_register_code: i32
gate_owner_pid, gate_owner_pidversion: u32
GATE_CLIENT_CDHASH :: #config(SHOJI_GATE_CLIENT_CDHASH, "")
GATE_CLIENTS_DIR :: "/Library/GPUBundles/ShojiWindowServerProbe"
GATE_CLIENTS_PATH :: GATE_CLIENTS_DIR + "/clients"
gate_clients: [gate.GATE_CLIENTS_LIMIT]u8
gate_clients_len: int

// Reread on every HELLO (gate thread only), so a root installer's update
// takes effect without restarting WindowServer. Any doubt → no runtime list.
gate_clients_reload :: proc() {
	gate_clients_len = 0
	dir: posix.stat_t
	if posix.lstat(GATE_CLIENTS_DIR, &dir) != .OK {return}
	fd := posix.open(GATE_CLIENTS_PATH, {.NOFOLLOW, .CLOEXEC})
	if fd < 0 {return}
	defer posix.close(fd)
	file: posix.stat_t
	if posix.fstat(fd, &file) != .OK {return}
	if !gate.gate_allowlist_trusted(
		u32(file.st_uid), u32(transmute(u16)file.st_mode), i64(file.st_size),
		u32(dir.st_uid), u32(transmute(u16)dir.st_mode),
	) {return}
	n := posix.read(fd, &gate_clients[0], len(gate_clients))
	if i64(n) == i64(file.st_size) {gate_clients_len = int(n)}
}
gate_last_status: Tgate_Status

gate_register_service :: proc(task: u32) {
	if code := gate.gate_mach_port_allocate(task, gate.MACH_PORT_RIGHT_RECEIVE, &gate_mach_port); code != 0 {
		gate_mach_register_code = code
		return
	}
	if code := gate.gate_mach_port_insert_right(task, gate_mach_port, gate_mach_port, gate.MACH_MSG_TYPE_MAKE_SEND); code != 0 {
		gate_mach_register_code = code
		return
	}
	gate_mach_register_code = 0
}

// Reply to a received request. The kernel leaves the send-once right in
// msgh_remote_port; msgh_local_port is the gate's own receive right.
gate_reply :: proc(buffer: ^Gate_Buffer, command: u32, status: i32, data0, data1: u64) {
	reply_right, right_ok := gate.gate_received_reply_right(buffer[:])
	if !right_ok {return}
	n, ok := gate.gate_pack_reply(buffer[:], reply_right, command, status, data0, data1)
	if !ok {return}
	gate.gate_mach_msg(buffer, gate.MACH_MSG_SEND, u32(n), 0, 0, 0, 0)
}

Gate_Buffer :: [gate.GATE_RECEIVE_BUFFER_SIZE]u8

// Seal the staged plan and arm the inline hold on the marker window; the
// ordering callback applies the plan when the marker is ordered in.
gate_layout_arm :: proc(buffer: ^Gate_Buffer, command: u32, marker, budget_us: u64) {
	if observer_timebase.numer == 0 || observer_timebase.denom == 0 {gate_reply(buffer, command, 8, 0, 0); return}
	if !gate.layout_seal(&layout_plan, marker, budget_us) {gate_reply(buffer, command, 1, 0, 0); return}
	layout_budget_us = budget_us
	layout_generation = hold.generation + 1
	if layout_generation == 0 {layout_generation = 1}
	intrinsics.atomic_store_explicit(&layout_complete, 0, .Release)
	generation, _ := gate.hold_arm(&hold, marker, gate.HOLD_SCOPE_INLINE)
	gate_reply(buffer, command, 0, marker, u64(generation))
}

gate_handle_message :: proc(buffer: ^Gate_Buffer) {
	request, request_ok := gate.gate_unpack_request(buffer[:])
	if !request_ok {
		gate_reply(buffer, 0, 1, 0, 0)
		return
	}
	token, audit_ok := gate.gate_audit_token(buffer[:])
	pid := gate.gate_audit_pid(&token)
	pidversion := gate.gate_audit_pidversion(&token)
	if request.magic != gate.GATE_MAGIC {
		gate_reply(buffer, request.command, 1, 0, 0)
		return
	}
	if request.command == u32(gate.Gate_Command.Hello) {gate_clients_reload()}
	if !audit_ok || !gate.gate_client_identity(&token, GATE_CLIENT_CDHASH, string(gate_clients[:gate_clients_len])) {
		gate_reply(buffer, request.command, 4, 0, 0)
		return
	}
	// Owner-death reclaim: a verified-identity HELLO may take over only when
	// the registered owner is confirmed gone (ESRCH). The new owner starts
	// with no armed hold or watch inherited from the dead one.
	if request.command == u32(gate.Gate_Command.Hello) && gate_owner_pid != 0 &&
	   gate.gate_should_reclaim(gate_owner_pid, gate_owner_pidversion, pid, pidversion, gate_owner_alive(gate_owner_pid)) {
		gate_owner_pid, gate_owner_pidversion = 0, 0
		gate_cancel_staged()
		gate.receipt_cancel(&watch)
	}
	status := gate.gate_decide(&gate_owner_pid, &gate_owner_pidversion, audit_ok, pid, pidversion, request.version, request.command)
	if status != 0 {
		gate_reply(buffer, request.command, status, u64(gate_owner_pid), request.arg0)
		return
	}
	command := request.command
	arg0 := request.arg0
	arg1 := request.arg1
	switch gate.Gate_Command(command) {
	case .Capabilities:
		gate_reply(buffer, command, 0, gate.GATE_FEATURE_LAYOUT_SUBMIT, gate.LAYOUT_LIMIT)
	case .LayoutSubmit:
		if target, generation, busy := gate.hold_busy(&hold); busy {
			gate_reply(buffer, command, 6, target, u64(generation))
			return
		}
		items, count, items_ok := gate.gate_unpack_items(buffer[:])
		if !items_ok {gate_reply(buffer, command, 1, 0, 0); return}
		gate.layout_begin(&layout_plan)
		for item in items[:count] {
			if !gate.layout_add(&layout_plan, u64(item.wid), item.x, item.y) {
				layout_plan = {}
				gate_reply(buffer, command, 1, 0, 0)
				return
			}
		}
		gate_layout_arm(buffer, command, arg0, arg1)
	case .LayoutBegin, .LayoutAdd, .LayoutArm:
		if target, generation, busy := gate.hold_busy(&hold); busy {
			gate_reply(buffer, command, 6, target, u64(generation))
			return
		}
		#partial switch gate.Gate_Command(command) {
		case .LayoutBegin:
			gate.layout_begin(&layout_plan)
			gate_reply(buffer, command, 0, 0, 0)
		case .LayoutAdd:
			x, y := gate.placement_unpack(arg1)
			if !gate.layout_add(&layout_plan, arg0, x, y) {gate_reply(buffer, command, 1, 0, 0); return}
			gate_reply(buffer, command, 0, u64(layout_plan.count), arg0)
		case .LayoutArm:
			gate_layout_arm(buffer, command, arg0, arg1)
		}
	case .LayoutStatus:
		if layout_generation == 0 {gate_reply(buffer, command, 8, 0, 0)} else if intrinsics.atomic_load_explicit(&layout_complete, .Acquire) == 0 {
			gate_reply(buffer, command, 6, u64(layout_generation), 0)
		} else {
			gate_reply(buffer, command, layout_result, u64(layout_generation), u64(layout_elapsed_us) << 32 | u64(layout_applied))
		}
	case .ArmPlace:
		x, y := gate.placement_unpack(arg1)
		if !gate.placement_coordinates_valid(arg0, i64(x), i64(y)) {
			gate_reply(buffer, command, 1, 0, 0)
			return
		}
		if target, generation, busy := gate.hold_busy(&hold); busy {
			gate_reply(buffer, command, 6, target, u64(generation))
			return
		}
		placement_x, placement_y = x, y
		placement_generation = hold.generation + 1
		if placement_generation == 0 {placement_generation = 1}
		intrinsics.atomic_store_explicit(&placement_space_only, 0, .Release)
		intrinsics.atomic_store_explicit(&placement_auto, 0, .Release)
		intrinsics.atomic_store_explicit(&placement_complete, 0, .Release)
		generation, _ := gate.hold_arm(&hold, arg0, gate.HOLD_SCOPE_INLINE)
		gate_reply(buffer, command, 0, arg0, u64(generation))
	case .SpacePlace, .SpaceApply:
		// Same staged placement, claimed by the transaction-table channel
		// (space ops). The shim applies it with the context's connection;
		// SpaceApply applies on claim instead of waiting for Release.
		x, y := gate.placement_unpack(arg1)
		if !gate.placement_coordinates_valid(arg0, i64(x), i64(y)) {
			gate_reply(buffer, command, 1, 0, 0)
			return
		}
		if target, generation, busy := gate.hold_busy(&hold); busy {
			gate_reply(buffer, command, 6, target, u64(generation))
			return
		}
		placement_x, placement_y = x, y
		placement_generation = hold.generation + 1
		if placement_generation == 0 {placement_generation = 1}
		intrinsics.atomic_store_explicit(&placement_space_only, 1, .Release)
		intrinsics.atomic_store_explicit(&placement_auto, command == u32(gate.Gate_Command.SpaceApply) ? 1 : 0, .Release)
		intrinsics.atomic_store_explicit(&placement_complete, 0, .Release)
		generation, _ := gate.hold_arm(&hold, arg0, gate.HOLD_SCOPE_TABLE)
		gate_reply(buffer, command, 0, arg0, u64(generation))
	case .PlacementStatus:
		if placement_generation == 0 {
			gate_reply(buffer, command, 8, 0, 0)
		} else if intrinsics.atomic_load_explicit(&placement_complete, .Acquire) == 0 {
			gate_reply(buffer, command, 6, u64(placement_generation), 0)
		} else {
			gate_reply(buffer, command, placement_result, u64(placement_generation), placement_actual)
		}
	case .Arm:
		if arg1 & 3 == 0 {
			// Scope 0 arms neither hold; ownership probe only.
			gate_reply(buffer, command, 0, arg0, arg1)
			return
		}
		if target, generation, busy := gate.hold_busy(&hold); busy {
			gate_reply(buffer, command, 6, target, u64(generation))
			return
		}
		generation, _ := gate.hold_arm(&hold, arg0, u32(arg1))
		gate_reply(buffer, command, 0, arg0, u64(generation))
	case .Release:
		target, release_status := gate_release(u32(arg0))
		gate_reply(buffer, command, release_status, target, u64(hold.generation))
	case .Status:
		calls := intrinsics.atomic_load_explicit(&observer_calls, .Acquire)
		state := u64(gate_owner_pid)
		gate_reply(buffer, command, 0, calls, state)
	case .Dump:
		write_dump()
		gate_reply(buffer, command, 0, intrinsics.atomic_load_explicit(&observer_calls, .Acquire), 0)
	case .Watch:
		if arg0 == 0 {
			gate.receipt_cancel(&watch)
			gate_reply(buffer, command, 0, 0, u64(watch.generation))
			return
		}
		generation, armed := gate.receipt_arm(&watch, arg0)
		if !armed {
			// A pending watch is busy; cancel it explicitly with Watch 0.
			gate_reply(buffer, command, 6, u64(watch.target), u64(generation))
			return
		}
		gate_reply(buffer, command, 0, arg0, u64(generation))
	case .WatchStatus:
		receipt_status, receipt_result, receipt_ticks := gate.receipt_take(&watch, u32(arg0))
		gate_reply(buffer, command, receipt_status, u64(u32(receipt_result)), receipt_ticks)
	case .Hello:
		gate_reply(buffer, command, 0, u64(gate_owner_pid), arg0)
	}
}

// Release by generation (0 = unconditional). An unclaimed placement or
// layout completes as cancelled (8) so its status never stays pending.
gate_release :: proc(generation: u32) -> (target: u64, status: i32) {
	target, status = gate.hold_release(&hold, generation)
	if _, _, busy := gate.hold_busy(&hold); !busy && status == 0 && placement_generation == hold.generation && intrinsics.atomic_load_explicit(&placement_complete, .Acquire) == 0 {
		finish_placement(8, 0)
	}
	if _, _, busy := gate.hold_busy(&hold); !busy && status == 0 && layout_generation == hold.generation && intrinsics.atomic_load_explicit(&layout_complete, .Acquire) == 0 {
		layout_result = 8
		layout_applied, layout_elapsed_us = 0, 0
		intrinsics.atomic_store_explicit(&layout_complete, 1, .Release)
	}
	return
}

gate_cancel_staged :: proc() {
	gate_release(0)
}

// kill(pid, 0): ESRCH is the only "gone" answer. EPERM (exists, other user)
// and PID reuse both read as alive, so reclaim errs toward refusing.
gate_owner_alive :: proc(pid: u32) -> bool {
	if pid == 0 || pid > 0x7fffffff {return false}
	if posix.kill(posix.pid_t(pid), posix.Signal(0)) == .OK {return true}
	return posix.errno() != .ESRCH
}

write_dump :: proc() {
	response: Observer_Response
	response.magic = {'W', 'S', 'O', 'B', 'S', 'E', 'R', 'V'}
	response.version = 3
	response.calls = intrinsics.atomic_load_explicit(&observer_calls, .Acquire)
	response.entry = observer_entry
	response.branch_word = u64(observer_branch)
	response.timebase_numer = observer_timebase.numer
	response.timebase_denom = observer_timebase.denom
	for index in 0 ..< OBSERVER_EVENTS {
		src := &observer_events[index]
		dst := &response.events[index]
		consistent := false
		for _ in 0 ..< 8 {
			first := intrinsics.atomic_load_explicit(&src.sequence, .Acquire)
			if first == 0 {dst^ = {}; consistent = true; break}
			dst^ = src^
			if intrinsics.atomic_load_explicit(&src.sequence, .Acquire) == first {consistent = true; break}
		}
		if !consistent {
			dst^ = {}
			response.torn += 1
		}
	}
	write_file_atomic(RESPONSE_PATH, &response, size_of(response))
}

// Call a PAC-signed handler (key A, discriminator 0) with the context in x0.
@(enable_target_feature = "pauth")
gate_call_handler :: asm(handler: u64, ctx: rawptr) -> (result: u64) [
	handler = %x8,
	ctx = %x0,
	result = %x10,
	#clobber %x1, #clobber %x2, #clobber %x3, #clobber %x4, #clobber %x5,
	#clobber %x6, #clobber %x7, #clobber %x9, #clobber %x11,
	#clobber %x12, #clobber %x13, #clobber %x14, #clobber %x15,
	#clobber %x16, #clobber %x17, #clobber %x30, #clobber memory, #volatile,
] {
	blraaz handler;
	mov result, ctx;
}

// Authenticate a table pointer the same way blraaz would, yielding the raw
// address; a bad signature poisons the result and fails verification safely.
@(enable_target_feature = "pauth")
auth_ptr :: asm(p: u64) -> (r: u64) {
	mov r, p;
	autiza r;
}

// Peek the first TLV argument (the window id) without touching the context.
// Mirrors the shared reader at 0x187138bf0: tag <= 0x0f encodes sbfx(tag,0,1);
// otherwise tag>>4 bytes, big-endian, sign-filled from tag bit 0.
tlv_peek :: proc "contextless" (ctx: rawptr) -> (value: i64, ok: bool) {
	if ctx == nil {return}
	base := uintptr(ctx)
	cursor := (^u64)(base + 0x10)^
	remaining := (^u64)(base + 0x18)^
	if cursor == 0 || remaining == 0 {return}
	p := ([^]u8)(uintptr(cursor))
	tag := p[0]
	if tag <= 0x0f {
		return -i64(tag & 1), true
	}
	n := u64(tag >> 4)
	if n > 8 || remaining < 1 + n {return}
	acc := i64(0)
	if tag & 1 != 0 {acc = -1}
	for i in 0 ..< n {acc = (acc << 8) | i64(p[1 + i])}
	return acc, true
}

gate_deadline :: proc "contextless" (before: u64) -> u64 {
	if observer_timebase.denom != 0 {
		return before + 3 * 1_000_000_000 * u64(observer_timebase.denom) / u64(observer_timebase.numer)
	}
	return before + 72_000_000
}

gate_shim_impl :: proc "c" (ctx: rawptr, op: u64) -> u64 {
	before := mach_absolute_time()
	held := u32(0)
	wid, wid_ok := tlv_peek(ctx)
	space_armed := intrinsics.atomic_load_explicit(&placement_complete, .Acquire) == 0 &&
		intrinsics.atomic_load_explicit(&placement_space_only, .Acquire) != 0
	claimable := !space_armed || (op >= SPACE_OP_MIN && op <= SPACE_OP_MAX)
	claimed := wid_ok && op <= TABLE_OP_MAX && claimable && gate.hold_try_claim(&hold, u64(wid), false)
	if claimed && placement_generation == hold.generation && intrinsics.atomic_load_explicit(&placement_auto, .Acquire) != 0 {
		// SpaceApply: frame-scale; the owner's own commit is blocked on us.
		// held=3 matches the C1 automatic layout callback.
		held = 3
		connection := (^rawptr)(uintptr(ctx) + 0x8)^
		apply_server_placement(connection, u32(wid))
	} else if claimed {
		held = 1
		deadline := gate_deadline(before)
		for mach_absolute_time() < deadline {
			if gate.hold_released(&hold, false) {break}
			usleep(1_000)
		}
		if !gate.hold_released(&hold, false) {held = 2}
		if placement_generation == hold.generation {
			if held == 1 {
				// The transaction context holds its connection
				// object at +0x08 (the +0x10/+0x18 stream offsets are already
				// live-verified through tlv_peek). Nil fails placement closed.
				connection := (^rawptr)(uintptr(ctx) + 0x8)^
				apply_server_placement(connection, u32(wid))
			} else {
				finish_placement(9, 0)
			}
		}
	}
	result := u64(0)
	if op <= TABLE_OP_MAX && gate_originals[op] != 0 {
		result = gate_call_handler(gate_originals[op], ctx)
	}
	if held != 0 {gate.hold_finish(&hold)}
	after := mach_absolute_time()
	sequence := intrinsics.atomic_add_explicit(&observer_calls, 1, .Relaxed)
	event := &observer_events[sequence % OBSERVER_EVENTS]
	event^ = {}
	event.connection = u64(op)
	event.before = before
	event.after = after
	event.count = 1
	event.flag = GATE_EVENT_FLAG
	event.result = i32(result)
	event.captured = 1
	event.held = held
	if wid_ok {event.ids[0] = u32(wid)}
	event.operations[0] = i32(op)
	intrinsics.atomic_store_explicit(&event.sequence, sequence + 1, .Release)
	return result
}

// Per-op entry stubs: set w1 = op id, then branch to the universal shim.
// Layout per 20-byte slot: movz w1, #op; ldr x16, #8; br x16; .quad impl.
// The ldr sits at +4, so its literal pool entry is at +12 (PC+8), not +16:
// a pad there previously made the stub branch to impl_low32<<32 and crashed
// WindowServer (PID 97568, 2026-11-01 19:30).
gate_write_stub :: proc(slot: u64, op, impl: u64) {
	words := ([^]u32)(uintptr(slot))
	words[0] = 0x52800001 | u32(op << 5) // movz w1, #op
	words[1] = 0x58000050 // ldr x16, #8 → slot+12
	words[2] = 0xD61F0200 // br x16
	(^u64)(uintptr(slot) + 12)^ = impl
}

install_transaction_gate :: proc(task: u32, slide: u64, allocate: proc "c" (_: u32, _: ^u64, _: u64, _: i32) -> i32, deallocate: gate.Deallocate, protect: Mach_Protect, page_size: u64) {
	result := Tgate_Status {
		magic = gate.TGATE_MAGIC,
		version = gate.TGATE_VERSION,
		status = 1,
	}
	result.windowserver_pid = u64(posix.getpid())
	defer gate_last_status = result
	defer write_file(TGATE_STATUS_PATH, &result, size_of(result))
	result.table_unslid = TABLE_UNSLID
	result.slide = slide
	table_live := TABLE_UNSLID + slide
	result.table_live = table_live
	// Runtime gate: authenticate sampled handler pointers and compare with the
	// static op map. Refuse on any mismatch before touching the table.
	for expected in gate_expected_ops {
		entry := ([^]u64)(uintptr(table_live + expected.op * 16))
		raw := auth_ptr(entry[0])
		if raw != expected.unslid + slide {
			result.verify_failed_op = expected.op
			result.expected_raw = expected.unslid + slide
			result.observed_raw = raw
			result.status = 3
			return
		}
	}
	// Exact-build gate for the dispatcher instructions that will be redirected.
	result.dispatch_site = gate.DISPATCH_SITE_UNSLID + slide
	site_words := ([^]u32)(uintptr(result.dispatch_site))
	expected_site := gate.DISPATCH_SITE_WORDS
	if site_words[0] != expected_site[0] || site_words[1] != expected_site[1] {
		result.status = 10
		return
	}
	impl := u64(uintptr(rawptr(gate_shim_impl)))
	stub_page: u64
	if code := allocate(task, &stub_page, page_size, 1); code != 0 {
		result.status = 4
		return
	}
	for op, index in GATED_OPS {
		gate_write_stub(stub_page + u64(index) * 32, op, impl)
	}
	gate.hook_sys_icache_invalidate(rawptr(uintptr(stub_page)), uint(page_size))
	if code := protect(task, stub_page, page_size, 0, 1 | 4); code != 0 {
		result.status = 4
		return
	}
	result.stubs = stub_page
	// The table lives in shared-cache __AUTH_CONST, which this kernel refuses
	// to make writable (R|W and R|W|COPY both fail with KERN_PROTECTION_FAILURE
	// on a 26B123 M1 Max). PKGTransactionCommit loads the table base with one
	// adrp/add pair and calls entries with blraaz (zero discriminator), so a
	// byte copy of the table stays valid. Point that pair at a private copy.
	copy_page, words, prepared := prepare_table_copy(
		task,
		stub_page,
		allocate,
		protect,
		page_size,
		&result,
	)
	if !prepared {
		return
	}
	result.table_copy = copy_page
	if !redirect_dispatch_site(task, words, deallocate, protect, page_size, &result) {
		return
	}
	result.entries_written = len(GATED_OPS)
	result.status = 0
}

// Copies the dispatch table (op 0 through DISPATCH_OP_LIMIT, as the
// dispatcher indexes it) into a read-only private page, with gated entries
// replaced by signed stub pointers, and encodes the adrp/add pair that loads
// it. Status 4: allocation or protection failed; 9: copy out of adrp range.
// Status 10 (set by the caller or here): dispatcher code differs from the build.
prepare_table_copy :: proc(
	task: u32,
	stub_page: u64,
	allocate: proc "c" (_: u32, _: ^u64, _: u64, _: i32) -> i32,
	protect: Mach_Protect,
	page_size: u64,
	result: ^Tgate_Status,
) -> (copy_page: u64, words: [2]u32, ok: bool) {
	table_bytes := (gate.DISPATCH_OP_LIMIT + 1) * 16
	#assert(gate.DISPATCH_OP_LIMIT >= TABLE_OP_MAX)
	if table_bytes > page_size {
		result.status = 4
		return
	}
	if allocate(task, &copy_page, page_size, 1) != 0 {
		result.status = 4
		return
	}
	table_live := result.table_live
	source := ([^]u64)(uintptr(table_live))
	target := ([^]u64)(uintptr(copy_page))
	for index in 0 ..< table_bytes / 8 {target[index] = source[index]}
	for op, index in GATED_OPS {
		gate_originals[op] = source[op * 2]
		target[op * 2] = inject.sign_function(stub_page + u64(index) * 32)
	}
	encoded, in_range := gate.encode_adrp_add(result.dispatch_site, copy_page, 24)
	if !in_range {
		result.status = 9
		return
	}
	if protect(task, copy_page, page_size, 0, 1) != 0 {
		result.status = 4
		return
	}
	return copy_page, encoded, true
}

// Rewrites the dispatcher's adrp/add pair while no thread sits between the two
// instructions. A thread already past the pair keeps the original table for the
// rest of its commit, which is safe: those ops run ungated. Status 6: barrier;
// 7: the code page could not be privatized (protect_code); 8: write or resume.
redirect_dispatch_site :: proc(
	task: u32,
	words: [2]u32,
	deallocate: gate.Deallocate,
	protect: Mach_Protect,
	page_size: u64,
	result: ^Tgate_Status,
) -> bool {
	site := result.dispatch_site
	expected := gate.DISPATCH_SITE_WORDS
	page := site & ~(page_size - 1)
	initial, region_ok := region_info(page, page_size)
	if !region_ok || initial.protection != 5 {
		result.status = 10
		return false
	}
	barrier: gate.Execution_Barrier
	if !gate.enter_execution_barrier_avoiding(&barrier, deallocate, site, 8, 64) {
		result.status = 6
		result.threads = u64(gate.barrier_last_count)
		return false
	}
	result.threads = u64(barrier.count)
	code := protect(task, page, page_size, 0, 1 | 2 | 16)
	if code != 0 {
		result.status = 7
		result.protect_code = i64(code)
		if !gate.leave_execution_barrier(&barrier) {result.protect_code = -1}
		return false
	}
	// Storing the unchanged words forces the private copy, as the ordering hook does.
	live := ([^]u32)(uintptr(site))
	for index in 0 ..< 2 {intrinsics.volatile_store(&live[index], expected[index])}
	if protect(task, page, page_size, 0, initial.protection) != 0 {
		// Never resume the server into a page that could not be made executable.
		result.status = 7
		write_file(TGATE_STATUS_PATH, result, size_of(result^))
		for {intrinsics.cpu_relax()}
	}
	replacement := words
	written := gate.write_words_via_alias(site, expected[:], replacement[:], deallocate)
	if !gate.leave_execution_barrier(&barrier) || !written {
		result.status = 8
		return false
	}
	return true
}

write_file :: proc(path: cstring, data: rawptr, size: int) {
	fd := posix.open(path, {.WRONLY, .CREAT, .TRUNC}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if fd < 0 {return}
	bytes := ([^]u8)(data)
	written := 0
	for written < size {
		code := write_fd(i32(fd), &bytes[written], uint(size - written))
		if code <= 0 {break}
		written += code
	}
	close_fd(i32(fd))
}

// Publish through a temporary sibling so readers never observe a truncated
// response; the WindowServer process owns both names in the sticky directory.
write_file_atomic :: proc(path: cstring, data: rawptr, size: int) {
	temporary: [128]u8
	n := 0
	for c in string(path) {
		temporary[n] = u8(c)
		n += 1
	}
	suffix := ".tmp"
	for i in 0 ..< len(suffix) {
		temporary[n] = suffix[i]
		n += 1
	}
	temporary[n] = 0
	write_file(cstring(&temporary[0]), data, size)
	rename_file(cstring(&temporary[0]), path)
}

region_info :: proc(page, page_size: u64) -> (info: Region_Info, ok: bool) {
	depth: u32
	for _ in 0 ..< 16 {
		address := page
		size: u64
		words: [19]u32
		count := u32(len(words))
		code := mach_vm_region_recurse(inject.mach_task_self(), &address, &size, &depth, &words[0], &count)
		if code != 0 || count < 13 || address > page || page - address > size ||
		   page_size > size - (page - address) {return {}, false}
		if words[12] == 0 {return {i32(words[0]), i32(words[1]), u8(words[11] >> 24)}, true}
		depth += 1
	}
	return {}, false
}

running_in_windowserver :: proc() -> bool {
	buffer: [4096]u8
	if proc_pidpath(i32(posix.getpid()), &buffer[0], u32(len(buffer))) <= 0 {return false}
	return gate.valid_path(string(cstring(&buffer[0])))
}

ordering_observer :: proc "c" (connection: rawptr, ids: [^]u32, operations: [^]i32, relative: [^]u32, count: u32, flag: u32) -> i32 {
	before := mach_absolute_time()
	held := u32(0)
	// Claim exactly once: a concurrent matching call must not double-hold.
	if count > 0 && ids != nil && operations != nil && operations[0] == 1 &&
	   gate.hold_try_claim(&hold, u64(ids[0]), true) {
		if layout_generation == hold.generation {
			// held=3 is an automatic bounded layout callback, distinct from
			// external release (1) and fail-open timeout (2).
			held = 3
			apply_server_layout(connection)
		} else {
			held = 1
			// Bound by the Mach clock, not by usleep iterations; the guest
			// oversleeps (3,000 ms of requested sleeps measured 4.8 s).
			deadline := before
			if observer_timebase.denom != 0 {
				deadline += 3 * 1_000_000_000 * u64(observer_timebase.denom) / u64(observer_timebase.numer)
			} else {
				deadline += 72_000_000
			}
			for mach_absolute_time() < deadline {
				if gate.hold_released(&hold, true) {break}
				usleep(1_000)
			}
			if !gate.hold_released(&hold, true) {held = 2}
			if placement_generation == hold.generation {
				if held == 1 {apply_server_placement(connection, ids[0])} else {finish_placement(9, 0)}
			}
		}
	}
	result := observer_original(connection, ids, operations, relative, count, flag)
	if held != 0 {gate.hold_finish(&hold)}
	after := mach_absolute_time()
	// The receipt fires on the forwarded order-in, never delaying it.
	if count > 0 && ids != nil && operations != nil && operations[0] == 1 {
		gate.receipt_fire(&watch, u64(ids[0]), result, after)
	}
	sequence := intrinsics.atomic_add_explicit(&observer_calls, 1, .Relaxed)
	event := &observer_events[sequence % OBSERVER_EVENTS]
	event^ = {}
	event.connection = u64(uintptr(connection))
	event.before = before
	event.after = after
	event.count = count
	event.flag = flag
	event.result = result
	event.held = held
	if ids != nil && operations != nil && relative != nil {
		captured := min(count, 4)
		event.captured = captured
		for index in 0 ..< captured {
			event.ids[index] = ids[index]
			event.operations[index] = operations[index]
			event.relative[index] = relative[index]
		}
	}
	intrinsics.atomic_store_explicit(&event.sequence, sequence + 1, .Release)
	return result
}

control_thread :: proc "c" (_: rawptr) -> rawptr {
	context = runtime.default_context()
	// Control enters only through authenticated Mach messages. The retired
	// file channel must not bypass the signed-client identity policy.
	buffer: struct #align(16) {bytes: Gate_Buffer}
	for {
		if gate_mach_port != 0 {
			code := gate.gate_mach_msg(&buffer.bytes[0], gate.gate_receive_audit_options(), 0, len(buffer.bytes), gate_mach_port, 10, 0)
			if code == 0 {
				gate_handle_message(&buffer.bytes)
			}
		}
		if gate_mach_port == 0 {usleep(1_000)}
	}
}

install_observer :: proc() {
	result := Install_Result {
		magic = {'W', 'S', 'O', 'B', 'I', 'N', 'S', 'T'},
		version = 1,
		status = 1,
	}
	defer write_file(STATUS_PATH, &result, size_of(result))
	if !running_in_windowserver() {return}
	mach_timebase_info(&observer_timebase)
	handle := inject.dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", 2)
	if handle == nil {result.status = 20; return}
	server := inject.raw_symbol(handle, "SLXServer")
	if server == nil {result.status = 21; return}
	info: Image_Info
	if dladdr(server, &info) == 0 {result.status = 22; return}
	result.image_base = u64(uintptr(info.base))
	location, image_ok := gate.inspect_ordering_image(info.base)
	if !image_ok {result.status = 23; return}
	entry := location.candidate
	bytes := ([^]u8)(uintptr(entry))
	result.uuid = location.uuid
	result.slide = location.slide
	result.candidate = entry
	for index in 0 ..< 16 {result.entry_bytes[index] = bytes[index]}
	if !gate.matches_ordering_entry(location, bytes[:16]) {result.status = 24; return}
	if !verify_placement_helpers(location.slide) {result.status = 25; return}
	page_size := mach.vm_page_size
	if page_size == 0 || page_size & (page_size - 1) != 0 {result.status = 3; return}
	page := entry & ~(page_size - 1)
	initial, region_ok := region_info(page, page_size)
	if !region_ok || initial.protection != 5 || initial.max_protection != 5 {result.status = 3; return}
	result.initial_current = i64(initial.protection)
	result.initial_max = i64(initial.max_protection)

	kernel := inject.dlopen("/usr/lib/system/libsystem_kernel.dylib", 2)
	if kernel == nil {result.status = 3; return}
	allocate := cast(proc "c" (_: u32, _: ^u64, _: u64, _: i32) -> i32)inject.raw_symbol(kernel, "mach_vm_allocate")
	deallocate := cast(gate.Deallocate)inject.raw_symbol(kernel, "mach_vm_deallocate")
	protect := cast(Mach_Protect)inject.raw_symbol(kernel, "mach_vm_protect")
	if allocate == nil || deallocate == nil || protect == nil {result.status = 3; return}

	task := inject.mach_task_self()
	entry_words := ([^]u32)(uintptr(entry))
	expected: [4]u32
	for index in 0 ..< 4 {expected[index] = entry_words[index]}
	trampoline: u64
	allocate_code := allocate(task, &trampoline, page_size, 1)
	result.allocation_code = i64(allocate_code)
	if allocate_code != 0 {
		result.setup_code = 1
		result.status = 4
		return
	}
	replacement := inject.strip_function(u64(uintptr(rawptr(ordering_observer))))
	plan, plan_ok := gate.plan_inline(entry, trampoline, replacement, expected)
	if !plan_ok {
		deallocate(task, trampoline, page_size)
		result.setup_code = 2
		result.status = 4
		return
	}
	trampoline_code := ([^]u32)(uintptr(trampoline))
	for index in 0 ..< 4 {
		trampoline_code[index] = plan.displaced[index]
		trampoline_code[4 + index] = plan.resume_jump[index]
	}
	gate.hook_sys_icache_invalidate(rawptr(uintptr(trampoline)), uint(page_size))
	region_protect_code := protect(task, trampoline, page_size, 0, 1 | 4)
	result.allocation_code = i64(region_protect_code)
	if region_protect_code != 0 {
		deallocate(task, trampoline, page_size)
		result.setup_code = 3
		result.status = 4
		return
	}
	result.trampoline = trampoline
	result.relay = 0
	observer_entry = entry
	observer_branch = plan.entry_jump[0]
	observer_original = transmute(Ordering_Callback)uintptr(trampoline)
	hold = {}
	watch = {}

	barrier: gate.Execution_Barrier
	state: gate.Inline_State
	parked := false
	for _ in 0 ..< 64 {
		entered := false
		for _ in 0 ..< 64 {
			if gate.enter_execution_barrier(&barrier, deallocate) {entered = true; break}
			usleep(10_000)
		}
		if !entered {
			result.status = 5
			result.threads = u64(gate.barrier_last_count)
			result.setup_code = i64(gate.barrier_last_failure)
			result.barrier_run_state = i64(gate.barrier_last_run_state)
			result.barrier_suspend_count = i64(gate.barrier_last_suspend_count)
			return
		}
		result.threads = u64(barrier.count)
		result.privatize_code = i64(protect(task, page, page_size, 0, 1 | 2 | 16))
		if result.privatize_code != 0 {
			result.status = 6
			if !gate.leave_execution_barrier(&barrier) {result.barrier_leave_code = 1}
			return
		}
		for index in 0 ..< 4 {intrinsics.volatile_store(&entry_words[index], expected[index])}
		result.execute_code = i64(protect(task, page, page_size, 0, initial.protection))
		if result.execute_code != 0 {
			// Never resume the server into a page that could not be made executable.
			result.status = 7
			write_file(STATUS_PATH, &result, size_of(result))
			for {intrinsics.cpu_relax()}
		}
		if !gate.write_inline_loop_via_alias(entry, expected, deallocate) {
			result.install_code = 1
			if !gate.leave_execution_barrier(&barrier) {result.barrier_leave_code = 1}
			result.status = 8
			return
		}
		if !gate.leave_execution_barrier(&barrier) {
			result.barrier_leave_code = 1
			write_file(STATUS_PATH, &result, size_of(result))
			for {intrinsics.cpu_relax()}
		}
		for _ in 0 ..< 100_000 {intrinsics.cpu_relax()}
		reentered := false
		for _ in 0 ..< 64 {
			if gate.enter_execution_barrier(&barrier, deallocate) {reentered = true; break}
			usleep(10_000)
		}
		if !reentered {
			if !gate.restore_inline_loop_via_alias(entry, expected, deallocate) {
				write_file(STATUS_PATH, &result, size_of(result))
				for {intrinsics.cpu_relax()}
			}
			result.status = 5
			result.threads = u64(gate.barrier_last_count)
			result.setup_code = i64(gate.barrier_last_failure)
			result.barrier_run_state = i64(gate.barrier_last_run_state)
			result.barrier_suspend_count = i64(gate.barrier_last_suspend_count)
			return
		}
		inside, checked := gate.barrier_has_pc_in_range(&barrier, entry + 4, gate.INLINE_PATCH_BYTES - 4)
		if checked && !inside {
			parked = true
			break
		}
		if !gate.restore_inline_loop_via_alias(entry, expected, deallocate) {
			write_file(STATUS_PATH, &result, size_of(result))
			for {intrinsics.cpu_relax()}
		}
		if !gate.leave_execution_barrier(&barrier) {
			result.barrier_leave_code = 1
			write_file(STATUS_PATH, &result, size_of(result))
			for {intrinsics.cpu_relax()}
		}
	}
	if !parked {
		result.install_code = 2
		result.status = 8
		return
	}
	if gate.install_inline_after_loop(&state, entry, replacement, expected, deallocate) {
		result.install_code = 0
	} else {
		result.install_code = 3
		gate.teardown_inline_quiescent(&state)
		if !gate.restore_inline_loop_via_alias(entry, expected, deallocate) {
			write_file(STATUS_PATH, &result, size_of(result))
			for {intrinsics.cpu_relax()}
		}
	}
	final, final_ok := region_info(page, page_size)
	if final_ok {
		result.final_current = i64(final.protection)
		result.final_max = i64(final.max_protection)
	}
	if !gate.leave_execution_barrier(&barrier) {result.barrier_leave_code = 1}
	if barrier.active {
		write_file(STATUS_PATH, &result, size_of(result))
		for {intrinsics.cpu_relax()}
	}
	if result.install_code != 0 {result.status = 8; return}
	if result.barrier_leave_code != 0 || !final_ok || final.protection != 5 {
		result.status = 9
		return
	}
	install_transaction_gate(task, location.slide, allocate, deallocate, protect, page_size)
	gate_register_service(task)
	gate_last_status.mach_port = u64(gate_mach_port)
	gate_last_status.mach_code = i64(gate_mach_register_code)
	write_file(TGATE_STATUS_PATH, &gate_last_status, size_of(gate_last_status))
	thread: posix.pthread_t
	worker := transmute(proc "c" (rawptr) -> rawptr)uintptr(inject.sign_function(u64(uintptr(rawptr(control_thread)))))
	thread_result := posix.pthread_create(&thread, nil, worker, nil)
	result.thread_create_code = i64(thread_result)
	if thread_result != nil {
		result.status = 10
		return
	}
	result.status = 0
}

@(export)
shoji_ws_observer_start :: proc "c" () {
	if intrinsics.atomic_add_explicit(&observer_start_calls, 1, .Acquire) != 0 {return}
	context = runtime.default_context()
	marker := [16]u8{'W', 'S', 'O', 'B', 'S', 'T', 'A', 'R', 'T', 0, 0, 0, 0, 0, 0, 1}
	write_file(STARTED_PATH, &marker, size_of(marker))
	install_observer()
}
