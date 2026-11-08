package gate

// Transaction-gate status shared by the payload (writer, inside WindowServer)
// and Shoji (reader). The payload writes it to TGATE_STATUS_PATH as
// _windowserver; /private/tmp survives the WindowServer restarts that unload
// the payload, so readers must match windowserver_pid against the live server.

import "base:intrinsics"
import "core:time"

foreign import gate_system "system:System"

TGATE_MAGIC :: [8]u8{'W', 'S', 'O', 'B', 'T', 'G', 'A', 'T'}
// Version 4 adds windowserver_pid; older files cannot be tied to a server.
TGATE_VERSION :: 5

Tgate_Status :: struct {
	magic:                                        [8]u8,
	version, status:                              u64,
	table_unslid, table_live, slide:              u64,
	verify_failed_op, expected_raw, observed_raw: u64,
	entries_written, threads, stubs:              u64,
	protect_code:                                 i64,
	mach_port, owner_pid:                         u64,
	mach_code:                                    i64,
	dispatch_site, table_copy:                    u64,
	windowserver_pid:                             u64,
}

// Accepts only a complete current-version status written for `windowserver`.
// `owner_uid` is the file's owner; only WindowServer's user may have written it.
tgate_status_decode :: proc(
	data: []u8,
	owner_uid: u32,
	windowserver: i32,
) -> (
	status: Tgate_Status,
	ok: bool,
) {
	if len(data) != size_of(Tgate_Status) || owner_uid != UID || windowserver <= 0 {return}
	intrinsics.mem_copy_non_overlapping(&status, raw_data(data), size_of(Tgate_Status))
	if status.magic != TGATE_MAGIC || status.version != TGATE_VERSION {return {}, false}
	if status.windowserver_pid != u64(windowserver) {return {}, false}
	return status, true
}

@(default_calling_convention = "c")
foreign gate_system {
	@(link_name = "task_for_pid")
	gate_task_for_pid :: proc(target: u32, pid: i32, task: ^u32) -> i32 ---
	@(link_name = "mach_port_extract_right")
	gate_mach_port_extract_right :: proc(task, name, desired: u32, right, acquired: ^u32) -> i32 ---
}

Gate_Delivery_Error :: enum {
	None,
	No_Bootstrap, // This process has no session bootstrap port.
	Extract, // WindowServer's gate right could not be copied.
	No_Rendezvous, // Nobody registered GATE_RENDEZVOUS_NAME in time.
	Pack,
	Send,
}

// Copies a send right to WindowServer's gate port and sends it to whoever
// registered GATE_RENDEZVOUS_NAME in this process's session bootstrap. The
// receiver still has to pass the gate's audit-token HELLO; possession of
// the right authorizes nothing. Polls the name for at most `wait`.
gate_deliver_to_rendezvous :: proc(
	windowserver_task, gate_port: u32,
	wait: time.Duration,
) -> (
	error: Gate_Delivery_Error,
	code: i32,
) {
	bootstrap, bootstrap_ok := gate_process_bootstrap_port()
	if !bootstrap_ok {return .No_Bootstrap, 0}
	self := gate_mach_task_self()
	send, acquired: u32
	code = gate_mach_port_extract_right(
		windowserver_task,
		gate_port,
		MACH_MSG_TYPE_COPY_SEND,
		&send,
		&acquired,
	)
	if code != 0 {return .Extract, code}
	defer gate_mach_port_deallocate(self, send)
	POLL :: 50 * time.Millisecond
	rendezvous: u32
	deadline := time.time_add(time.now(), wait)
	for {
		code = gate_bootstrap_look_up(bootstrap, GATE_RENDEZVOUS_NAME, &rendezvous)
		if code == 0 || time.diff(time.now(), deadline) <= 0 {break}
		time.sleep(POLL)
	}
	if code != 0 {return .No_Rendezvous, code}
	defer gate_mach_port_deallocate(self, rendezvous)
	message: struct #align (16) {
		bytes: [GATE_HANDSHAKE_SIZE]u8,
	}
	n, packed := gate_pack_handshake(message.bytes[:], rendezvous, send)
	if !packed {return .Pack, 0}
	code = gate_mach_msg(&message.bytes[0], MACH_MSG_SEND, u32(n), 0, 0, 0, 0)
	if code != 0 {return .Send, code}
	return .None, 0
}
