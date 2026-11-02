package experimental

// Mach gate protocol (B1). The payload inside WindowServer registers a
// bootstrap service and answers versioned commands; only the registered
// owner process (first HELLO, matched by audit-token pid + pidversion) may
// issue further commands. Layout is byte-explicit: mach header 24 bytes,
// body 32 bytes, audit trailer appended by the kernel on receive.

foreign import system "system:System"

GATE_SERVICE_NAME :: "com.shoji.windowserver.gate"
GATE_MAGIC :: 0x53484f4a // 'SHOJ'
GATE_REPLY_MAGIC :: 0x53484f4b // 'SHOK'
GATE_VERSION :: 1

Gate_Command :: enum u32 {
	Hello   = 1, // arg0: nonce; registers the sender as owner if unowned
	Arm     = 2, // arg0: window id; arg1: scope mask (bit0 inline, bit1 table)
	Release = 3,
	Status  = 4,
	Dump    = 5, // writes the file-channel dump for now; replies ack
}

GATE_HEADER_SIZE :: 24
GATE_BODY_SIZE :: 32
GATE_MSG_SIZE :: GATE_HEADER_SIZE + GATE_BODY_SIZE

// Body field offsets (from message start)
GATE_OFF_MAGIC :: 24
GATE_OFF_VERSION :: 28
GATE_OFF_COMMAND :: 32
GATE_OFF_ARG0 :: 40
GATE_OFF_ARG1 :: 48

// mach constants
MACH_MSG_SEND :: 1
MACH_MSG_RECEIVE :: 2
MACH_MSG_TYPE_COPY_SEND :: 19
MACH_MSG_TYPE_MAKE_SEND_ONCE :: 21
MACH_MSG_TYPE_MOVE_SEND_ONCE :: 18
MACH_PORT_RIGHT_RECEIVE :: 1
MACH_PORT_RIGHT_SEND_ONCE :: 4
MACH_RCV_TIMED_OUT :: 0x10004003
MACH_MSG_TRAILER_FORMAT_0 :: 0
MACH_RCV_TRAILER_AUDIT :: 3

@(default_calling_convention = "c")
foreign system {
	@(link_name = "mach_msg") gate_mach_msg :: proc "c" (header: rawptr, option: u32, send_size: u32, rcv_size: u32, rcv_name: u32, timeout: u32, notify: u32) -> i32 ---
	@(link_name = "mach_port_allocate") gate_mach_port_allocate :: proc "c" (task: u32, right: u32, name: ^u32) -> i32 ---
	@(link_name = "mach_port_insert_right") gate_mach_port_insert_right :: proc "c" (task: u32, name: u32, right: u32, type: u32) -> i32 ---
	@(link_name = "mach_port_deallocate") gate_mach_port_deallocate :: proc "c" (task: u32, name: u32) -> i32 ---
	@(link_name = "bootstrap_register") gate_bootstrap_register :: proc "c" (bp: u32, name: cstring, sp: u32) -> i32 ---
	@(link_name = "bootstrap_look_up") gate_bootstrap_look_up :: proc "c" (bp: u32, name: cstring, sp: ^u32) -> i32 ---
}

// bootstrap_port is a global variable, not a function; resolve it with
// dlsym (loader.raw_symbol) and dereference:
//   bp := (^u32)(loader.raw_symbol(handle, "bootstrap_port"))^

// audit_token_t layout: auid, euid, egid, ruid, rgid, pid, asid, pidversion
Audit_Token :: struct {
	val: [8]u32,
}

gate_audit_pid :: proc "contextless" (token: ^Audit_Token) -> u32 {
	return token.val[5]
}

gate_audit_pidversion :: proc "contextless" (token: ^Audit_Token) -> u32 {
	return token.val[7]
}
