package main

// Disposable exact-build WindowServer ordering observer. The callback records a
// bounded in-memory snapshot and forwards immediately; all file I/O runs on a
// separate control thread after installation. There is no live unhook path.
import "base:intrinsics"
import "base:runtime"
import "core:sys/posix"
import mach "core:sys/darwin"
import loader "../../../src/dock"
import hook "../../../src/experimental/window_server"

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
}

STATUS_PATH :: "/private/tmp/shoji-ws-observer-status-26A434.bin"
STARTED_PATH :: "/private/tmp/shoji-ws-observer-started-26A434.bin"
REQUEST_PATH :: "/private/tmp/shoji-ws-observer-request"
RESPONSE_PATH :: "/private/tmp/shoji-ws-observer-response-26A434.bin"

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
observer_hold_remaining, observer_hold_release: u32
observer_hold_target: u64
observer_entry: u64
observer_branch: u32
observer_timebase: Timebase_Info
observer_events: [OBSERVER_EVENTS]Observer_Event

// ===== Transaction table gate (A2) =====
// Static model (DISPATCH.md): PKGTransactionCommit dispatches ops through a
// global table at unslid 0x1e873d430, 140 entries of 16 bytes, op types
// 1..0x8c. Handlers are PAC-signed pointers called via blraaz (key A,
// discriminator 0) with a shared PKGTransactionContext* argument.
TGATE_STATUS_PATH :: "/private/tmp/shoji-ws-observer-tgate-26A434.bin"
TABLE_UNSLID :: 0x1e873d430
TABLE_OP_MAX :: 0x8c
GATED_OPS :: [14]u64{0x01, 0x03, 0x06, 0x0b, 0x18, 0x19, 0x21, 0x22, 0x2a, 0x33, 0x34, 0x35, 0x36, 0x41}
GATE_EVENT_FLAG :: 0x54474154 // 'TGAT'

Gate_Expected_Op :: struct {
	op:     u64,
	unslid: u64,
}
// gate_expected_ops (all 139 named ops) lives in gate_expected.odin.

Tgate_Status :: struct {
	magic:                                        [8]u8,
	version, status:                              u64,
	table_unslid, table_live, slide:              u64,
	verify_failed_op, expected_raw, observed_raw: u64,
	entries_written, threads, stubs:              u64,
	protect_code:                                 i64,
}

gate_originals: [TABLE_OP_MAX + 1]u64
gate_stubs: u64
gate_hold_target: u64
gate_hold_remaining, gate_hold_release: u32

// Call a PAC-signed handler (key A, discriminator 0) with the context in x0.
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
	if wid_ok && op <= TABLE_OP_MAX &&
	   u64(wid) == intrinsics.atomic_load_explicit(&gate_hold_target, .Acquire) &&
	   intrinsics.atomic_exchange_explicit(&gate_hold_remaining, 0, .Acq_Rel) == 1 {
		held = 1
		deadline := gate_deadline(before)
		for mach_absolute_time() < deadline {
			if intrinsics.atomic_load_explicit(&gate_hold_release, .Acquire) != 0 {break}
			usleep(1_000)
		}
		if intrinsics.atomic_load_explicit(&gate_hold_release, .Acquire) == 0 {held = 2}
	}
	result := u64(0)
	if op <= TABLE_OP_MAX && gate_originals[op] != 0 {
		result = gate_call_handler(gate_originals[op], ctx)
	}
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

install_transaction_gate :: proc(task: u32, slide: u64, allocate: proc "c" (_: u32, _: ^u64, _: u64, _: i32) -> i32, deallocate: hook.Deallocate, protect: Mach_Protect, page_size: u64) {
	result := Tgate_Status {
		magic = {'W', 'S', 'O', 'B', 'T', 'G', 'A', 'T'},
		version = 1,
		status = 1,
	}
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
	impl := u64(uintptr(rawptr(gate_shim_impl)))
	stub_page: u64
	if code := allocate(task, &stub_page, page_size, 1); code != 0 {
		result.status = 4
		return
	}
	for op, index in GATED_OPS {
		gate_write_stub(stub_page + u64(index) * 32, op, impl)
	}
	hook.hook_sys_icache_invalidate(rawptr(uintptr(stub_page)), uint(page_size))
	if code := protect(task, stub_page, page_size, 0, 1 | 4); code != 0 {
		result.status = 4
		return
	}
	result.stubs = stub_page
	table_page := table_live & ~(page_size - 1)
	region, region_ok := region_info(table_page, page_size)
	if !region_ok {
		result.status = 5
		return
	}
	barrier: hook.Execution_Barrier
	entered := false
	for _ in 0 ..< 64 {
		if hook.enter_execution_barrier(&barrier, deallocate) {entered = true; break}
		usleep(10_000)
	}
	if !entered {
		result.status = 6
		result.threads = u64(hook.barrier_last_count)
		return
	}
	result.threads = u64(barrier.count)
	result.protect_code = i64(protect(task, table_page, page_size, 0, 1 | 2 | 16))
	if result.protect_code != 0 {
		result.status = 7
		if !hook.leave_execution_barrier(&barrier) {result.protect_code = -1}
		return
	}
	for op, index in GATED_OPS {
		entry := ([^]u64)(uintptr(table_live + op * 16))
		gate_originals[op] = entry[0]
		intrinsics.volatile_store(&entry[0], loader.sign_function(stub_page + u64(index) * 32))
	}
	result.entries_written = len(GATED_OPS)
	protect(task, table_page, page_size, 0, region.protection)
	if !hook.leave_execution_barrier(&barrier) {
		result.status = 8
		return
	}
	result.status = 0
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
		code := mach_vm_region_recurse(loader.mach_task_self(), &address, &size, &depth, &words[0], &count)
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
	return hook.valid_path(string(cstring(&buffer[0])))
}

ordering_observer :: proc "c" (connection: rawptr, ids: [^]u32, operations: [^]i32, relative: [^]u32, count: u32, flag: u32) -> i32 {
	before := mach_absolute_time()
	held := u32(0)
	// Claim exactly once: a concurrent matching call must not double-hold.
	if count > 0 && ids != nil && operations != nil && operations[0] == 1 &&
	   u64(ids[0]) == intrinsics.atomic_load_explicit(&observer_hold_target, .Acquire) &&
	   intrinsics.atomic_exchange_explicit(&observer_hold_remaining, 0, .Acq_Rel) == 1 {
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
			if intrinsics.atomic_load_explicit(&observer_hold_release, .Acquire) != 0 {break}
			usleep(1_000)
		}
		if intrinsics.atomic_load_explicit(&observer_hold_release, .Acquire) == 0 {held = 2}
	}
	result := observer_original(connection, ids, operations, relative, count, flag)
	after := mach_absolute_time()
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
	// The request file persists after handling and this process cannot unlink
	// it (sticky directory, owned by the desktop user). Process each distinct
	// command once instead of re-executing a stale file every poll; a leftover
	// "hold" file otherwise re-arms the gate after the claim completes.
	last: [32]u8
	last_n := -1
	for {
		fd := posix.open(REQUEST_PATH, {.NOFOLLOW, .NONBLOCK})
		if fd >= 0 {
			info: posix.stat_t
			request: [32]u8
			valid := posix.fstat(fd, &info) == nil && posix.S_ISREG(info.st_mode) &&
				info.st_uid == 501 && info.st_size > 0 && info.st_size <= len(request)
			n: int
			if valid {
				n = posix.read(fd, &request[0], len(request))
				// Reject in-flight partial writes: every command ends with \n.
				valid = n > 0 && request[n - 1] == '\n'
			}
			posix.close(fd)
			unchanged := valid && n == last_n
			if unchanged {
				for index in 0 ..< n {
					if request[index] != last[index] {unchanged = false; break}
				}
			}
			if valid && !unchanged {
				last_n = n
				for index in 0 ..< n {last[index] = request[index]}
			}
			if valid && !unchanged && n >= 5 && string(request[:5]) == "dump\n" {
				response: Observer_Response
				response.magic = {'W', 'S', 'O', 'B', 'S', 'E', 'R', 'V'}
				response.version = 3
				response.calls = intrinsics.atomic_load_explicit(&observer_calls, .Acquire)
				response.entry = observer_entry
				response.branch_word = u64(observer_branch)
				response.timebase_numer = observer_timebase.numer
				response.timebase_denom = observer_timebase.denom
				// Seqlock per event: the writer zeroes the slot, fills it, then
				// publishes the sequence. Retry on instability; drop and count
				// events that never settle instead of exporting torn data.
				for index in 0 ..< OBSERVER_EVENTS {
					src := &observer_events[index]
					dst := &response.events[index]
					consistent := false
					for _ in 0 ..< 8 {
						first := intrinsics.atomic_load_explicit(&src.sequence, .Acquire)
						if first == 0 {dst^ = {}; consistent = true; break}
						dst^ = src^
						if intrinsics.atomic_load_explicit(&src.sequence, .Acquire) == first {
							consistent = true
							break
						}
					}
					if !consistent {
						dst^ = {}
						response.torn += 1
					}
				}
				write_file_atomic(RESPONSE_PATH, &response, size_of(response))
			} else if valid && !unchanged && n >= 8 && string(request[:8]) == "release\n" {
				intrinsics.atomic_store_explicit(&observer_hold_release, 1, .Release)
				intrinsics.atomic_store_explicit(&gate_hold_release, 1, .Release)
			} else if valid && !unchanged && n >= 6 && string(request[:5]) == "hold " {
				target: u64
				digits := 0
				for index in 5 ..< n {
					byte := request[index]
					if byte == '\n' {break}
					if byte < '0' || byte > '9' {digits = 0; break}
					if target < max(u64) / 10 {
						target = target * 10 + u64(byte - '0')
						digits += 1
					}
				}
				if digits > 0 && target <= u64(max(u32)) {
					intrinsics.atomic_store_explicit(&observer_hold_target, target, .Release)
					intrinsics.atomic_store_explicit(&observer_hold_release, 0, .Release)
					intrinsics.atomic_store_explicit(&observer_hold_remaining, 1, .Release)
				}
			} else if valid && !unchanged && n >= 7 && string(request[:6]) == "thold " {
				target: u64
				digits := 0
				for index in 6 ..< n {
					byte := request[index]
					if byte == '\n' {break}
					if byte < '0' || byte > '9' {digits = 0; break}
					if target < max(u64) / 10 {
						target = target * 10 + u64(byte - '0')
						digits += 1
					}
				}
				if digits > 0 && target <= u64(max(u32)) {
					intrinsics.atomic_store_explicit(&gate_hold_target, target, .Release)
					intrinsics.atomic_store_explicit(&gate_hold_release, 0, .Release)
					intrinsics.atomic_store_explicit(&gate_hold_remaining, 1, .Release)
				}
			}
		}
		usleep(1_000)
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
	handle := loader.dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", 2)
	if handle == nil {result.status = 20; return}
	server := loader.raw_symbol(handle, "SLXServer")
	if server == nil {result.status = 21; return}
	info: Image_Info
	if dladdr(server, &info) == 0 {result.status = 22; return}
	result.image_base = u64(uintptr(info.base))
	location, image_ok := hook.inspect_ordering_image(info.base)
	if !image_ok {result.status = 23; return}
	entry := location.candidate
	bytes := ([^]u8)(uintptr(entry))
	result.uuid = location.uuid
	result.slide = location.slide
	result.candidate = entry
	for index in 0 ..< 16 {result.entry_bytes[index] = bytes[index]}
	if !hook.matches_ordering_entry(location, bytes[:16]) {result.status = 24; return}
	page_size := mach.vm_page_size
	if page_size == 0 || page_size & (page_size - 1) != 0 {result.status = 3; return}
	page := entry & ~(page_size - 1)
	initial, region_ok := region_info(page, page_size)
	if !region_ok || initial.protection != 5 || initial.max_protection != 5 {result.status = 3; return}
	result.initial_current = i64(initial.protection)
	result.initial_max = i64(initial.max_protection)

	kernel := loader.dlopen("/usr/lib/system/libsystem_kernel.dylib", 2)
	if kernel == nil {result.status = 3; return}
	allocate := cast(proc "c" (_: u32, _: ^u64, _: u64, _: i32) -> i32)loader.raw_symbol(kernel, "mach_vm_allocate")
	deallocate := cast(hook.Deallocate)loader.raw_symbol(kernel, "mach_vm_deallocate")
	protect := cast(Mach_Protect)loader.raw_symbol(kernel, "mach_vm_protect")
	if allocate == nil || deallocate == nil || protect == nil {result.status = 3; return}

	task := loader.mach_task_self()
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
	replacement := loader.strip_function(u64(uintptr(rawptr(ordering_observer))))
	plan, plan_ok := hook.plan_inline(entry, trampoline, replacement, expected)
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
	hook.hook_sys_icache_invalidate(rawptr(uintptr(trampoline)), uint(page_size))
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
	intrinsics.atomic_store_explicit(&observer_hold_target, 0, .Release)
	intrinsics.atomic_store_explicit(&observer_hold_release, 0, .Release)
	intrinsics.atomic_store_explicit(&observer_hold_remaining, 0, .Release)

	barrier: hook.Execution_Barrier
	state: hook.Inline_State
	parked := false
	for _ in 0 ..< 64 {
		entered := false
		for _ in 0 ..< 64 {
			if hook.enter_execution_barrier(&barrier, deallocate) {entered = true; break}
			usleep(10_000)
		}
		if !entered {
			result.status = 5
			result.threads = u64(hook.barrier_last_count)
			result.setup_code = i64(hook.barrier_last_failure)
			return
		}
		result.threads = u64(barrier.count)
		result.privatize_code = i64(protect(task, page, page_size, 0, 1 | 2 | 16))
		if result.privatize_code != 0 {
			result.status = 6
			if !hook.leave_execution_barrier(&barrier) {result.barrier_leave_code = 1}
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
		if !hook.write_inline_loop_via_alias(entry, expected, deallocate) {
			result.install_code = 1
			if !hook.leave_execution_barrier(&barrier) {result.barrier_leave_code = 1}
			result.status = 8
			return
		}
		if !hook.leave_execution_barrier(&barrier) {
			result.barrier_leave_code = 1
			write_file(STATUS_PATH, &result, size_of(result))
			for {intrinsics.cpu_relax()}
		}
		for _ in 0 ..< 100_000 {intrinsics.cpu_relax()}
		reentered := false
		for _ in 0 ..< 64 {
			if hook.enter_execution_barrier(&barrier, deallocate) {reentered = true; break}
			usleep(10_000)
		}
		if !reentered {
			if !hook.restore_inline_loop_via_alias(entry, expected, deallocate) {
				write_file(STATUS_PATH, &result, size_of(result))
				for {intrinsics.cpu_relax()}
			}
			result.status = 5
			result.threads = u64(hook.barrier_last_count)
			result.setup_code = i64(hook.barrier_last_failure)
			return
		}
		inside, checked := hook.barrier_has_pc_in_range(&barrier, entry + 4, hook.INLINE_PATCH_BYTES - 4)
		if checked && !inside {
			parked = true
			break
		}
		if !hook.restore_inline_loop_via_alias(entry, expected, deallocate) {
			write_file(STATUS_PATH, &result, size_of(result))
			for {intrinsics.cpu_relax()}
		}
		if !hook.leave_execution_barrier(&barrier) {
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
	if hook.install_inline_after_loop(&state, entry, replacement, expected, deallocate) {
		result.install_code = 0
	} else {
		result.install_code = 3
		hook.teardown_inline_quiescent(&state)
		if !hook.restore_inline_loop_via_alias(entry, expected, deallocate) {
			write_file(STATUS_PATH, &result, size_of(result))
			for {intrinsics.cpu_relax()}
		}
	}
	final, final_ok := region_info(page, page_size)
	if final_ok {
		result.final_current = i64(final.protection)
		result.final_max = i64(final.max_protection)
	}
	if !hook.leave_execution_barrier(&barrier) {result.barrier_leave_code = 1}
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
	thread: posix.pthread_t
	worker := transmute(proc "c" (rawptr) -> rawptr)uintptr(loader.sign_function(u64(uintptr(rawptr(control_thread)))))
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
