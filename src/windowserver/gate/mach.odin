package gate

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
	ArmPlace = 6, // arm inline ordering + staged signed int32 x/y in arg1
	PlacementStatus = 7, // generation in data0, actual packed coordinates in data1
	LayoutBegin = 8,
	LayoutAdd = 9, // arg0 wid, arg1 signed packed x/y
	LayoutArm = 10, // arg0 marker window, arg1 timing budget in us (1..8000)
	LayoutStatus = 11, // data0 generation; data1 elapsed_us<<32 | applied_count
	Watch   = 12, // arg0: window id (0 cancels); arms a once-only ordering receipt
	WatchStatus = 13, // arg0: generation (0 = any); consumes a fired receipt
	SpacePlace = 14, // ArmPlace for the transaction-table channel (space ops)
	// SpacePlace applied on claim without waiting for Release (frame-scale,
	// for a single-threaded owner whose own commit is the trigger). Release
	// before a claim still cancels with placement status 8.
	SpaceApply = 15,
	// Protocol features of this payload: data0 GATE_FEATURE_* bits, data1 the
	// layout item limit. A payload older than this command answers status 1.
	Capabilities = 16,
	// LayoutBegin + LayoutAdd* + LayoutArm in one message: arg0 marker window,
	// arg1 timing budget in us; the items follow the body (GATE_ITEMS_OFF).
	LayoutSubmit = 17,
}

GATE_FEATURE_LAYOUT_SUBMIT :: u64(1)
// Item limit of payloads that predate Capabilities.
GATE_LEGACY_LAYOUT_LIMIT :: 8

GATE_HEADER_SIZE :: 24
GATE_BODY_SIZE :: 32
GATE_MSG_SIZE :: GATE_HEADER_SIZE + GATE_BODY_SIZE

// LayoutSubmit appends u32 count, u32 reserved, then count packed items
// (u32 wid, i32 x, i32 y). Its msgh_size is exactly GATE_ITEMS_OFF + 12*count.
GATE_ITEMS_HEADER_OFF :: GATE_MSG_SIZE
GATE_ITEMS_OFF :: GATE_MSG_SIZE + 8
GATE_ITEM_SIZE :: 12
GATE_SUBMIT_MAX_SIZE :: GATE_ITEMS_OFF + LAYOUT_LIMIT * GATE_ITEM_SIZE
// Receive buffers hold the largest request plus the audit trailer.
GATE_RECEIVE_BUFFER_SIZE :: 512
#assert(GATE_SUBMIT_MAX_SIZE + GATE_AUDIT_TRAILER_SIZE <= GATE_RECEIVE_BUFFER_SIZE)

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
MACH_RCV_TIMEOUT :: 0x100 // required or mach_msg ignores the timeout value
MACH_MSG_TRAILER_FORMAT_0 :: 0
MACH_RCV_TRAILER_AUDIT :: 3
MACH_MSGH_BITS_COMPLEX :: 0x80000000
MACH_MSG_TYPE_MAKE_SEND :: 20
MACH_MSG_PORT_DESCRIPTOR :: 0
MACH_PORT_TYPE_SEND :: 0x00010000

// WindowServer itself is denied bootstrap_register and bootstrap_look_up on
// macOS 27 (1100 BOOTSTRAP_NOT_PRIVILEGED, proven live 2026-11-03), so the
// gate is never looked up by name. `shoji --ws-attach` (root) copies a send
// right out of WindowServer's task (mach_port_extract_right COPY_SEND on the
// gate port published in the tgate status file) and sends it to the daemon's
// session rendezvous (GATE_RENDEZVOUS_NAME), which the daemon registered.
// Authorization stays the audit-token HELLO; possession of the send right
// alone grants nothing beyond first-HELLO-wins ownership.

// mach_msg_port_descriptor_t: name, pad1, pad2(u16), disposition(u8), type(u8).
// Little-endian bitfield order matches this packed layout.
Gate_Port_Descriptor :: struct #packed {
	name:        u32,
	pad1:        u32,
	pad2:        u16,
	disposition: u8,
	type:        u8,
}

// Complex messages insert mach_msg_body_t (descriptor count) between the
// 24-byte header and the first descriptor. A handshake without that word
// is rejected by the kernel.
GATE_HANDSHAKE_SIZE :: GATE_HEADER_SIZE + 4 + size_of(Gate_Port_Descriptor)
GATE_DESC_COUNT_OFF :: GATE_HEADER_SIZE
GATE_DESC_OFF :: GATE_HEADER_SIZE + 4

// mach_msg_audit_trailer_t places the audit token after type, size, seqno
// and the security token (4+4+4+8). MACH_RCV_TRAILER_ELEMENTS is bits 24..27;
// MACH_RCV_TRAILER_TYPE (format) is bits 28..31.
GATE_TRAILER_AUDIT_OFF :: 20
GATE_AUDIT_TRAILER_SIZE :: 52
GATE_RECV_SIZE :: GATE_MSG_SIZE + GATE_AUDIT_TRAILER_SIZE

// The daemon's session rendezvous; only `--ws-attach` looks it up.
GATE_RENDEZVOUS_NAME :: "com.shoji.gate.rendezvous"

@(default_calling_convention = "c")
foreign system {
	@(link_name = "mach_msg") gate_mach_msg :: proc "c" (header: rawptr, option: u32, send_size: u32, rcv_size: u32, rcv_name: u32, timeout: u32, notify: u32) -> i32 ---
	@(link_name = "mach_port_allocate") gate_mach_port_allocate :: proc "c" (task: u32, right: u32, name: ^u32) -> i32 ---
	@(link_name = "mach_port_insert_right") gate_mach_port_insert_right :: proc "c" (task: u32, name: u32, right: u32, type: u32) -> i32 ---
	@(link_name = "mach_port_deallocate") gate_mach_port_deallocate :: proc "c" (task: u32, name: u32) -> i32 ---
	@(link_name = "bootstrap_register") gate_bootstrap_register :: proc "c" (bp: u32, name: cstring, sp: u32) -> i32 ---
	@(link_name = "bootstrap_look_up") gate_bootstrap_look_up :: proc "c" (bp: u32, name: cstring, sp: ^u32) -> i32 ---
	@(link_name = "mach_port_destroy") gate_mach_port_destroy :: proc "c" (task: u32, name: u32) -> i32 ---
	@(link_name = "mach_port_type") gate_mach_port_type :: proc "c" (task: u32, name: u32, type: ^u32) -> i32 ---
	@(link_name = "mach_task_self") gate_mach_task_self :: proc "c" () -> u32 ---
	@(link_name = "dlopen") gate_dlopen :: proc "c" (path: cstring, mode: i32) -> rawptr ---
	@(link_name = "dlsym") gate_dlsym :: proc "c" (handle: rawptr, symbol: cstring) -> rawptr ---
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

gate_receive_audit_options :: proc "contextless" () -> u32 {
	return MACH_MSG_RECEIVE | MACH_RCV_TIMEOUT | (MACH_MSG_TRAILER_FORMAT_0 << 28) | (MACH_RCV_TRAILER_AUDIT << 24)
}

gate_store_u32 :: proc "contextless" (buf: []u8, off: int, value: u32) -> bool {
	if off < 0 || len(buf) < off + 4 {return false}
	buf[off] = u8(value)
	buf[off + 1] = u8(value >> 8)
	buf[off + 2] = u8(value >> 16)
	buf[off + 3] = u8(value >> 24)
	return true
}

gate_load_u32 :: proc "contextless" (buf: []u8, off: int) -> (value: u32, ok: bool) {
	if off < 0 || len(buf) < off + 4 {return}
	value = u32(buf[off]) | u32(buf[off + 1]) << 8 | u32(buf[off + 2]) << 16 | u32(buf[off + 3]) << 24
	return value, true
}

gate_store_u64 :: proc "contextless" (buf: []u8, off: int, value: u64) -> bool {
	return gate_store_u32(buf, off, u32(value)) && gate_store_u32(buf, off + 4, u32(value >> 32))
}

gate_load_u64 :: proc "contextless" (buf: []u8, off: int) -> (value: u64, ok: bool) {
	low, low_ok := gate_load_u32(buf, off)
	high, high_ok := gate_load_u32(buf, off + 4)
	if !low_ok || !high_ok {return}
	return u64(low) | u64(high) << 32, true
}

gate_store_i32 :: proc "contextless" (buf: []u8, off: int, value: i32) -> bool {
	return gate_store_u32(buf, off, transmute(u32)value)
}

gate_load_i32 :: proc "contextless" (buf: []u8, off: int) -> (value: i32, ok: bool) {
	raw, raw_ok := gate_load_u32(buf, off)
	if !raw_ok {return}
	return transmute(i32)raw, true
}

// Zero the header and body, then write a complex handshake that moves a
// send right to the gate port. remote is the client's rendezvous send right.
gate_pack_handshake :: proc "contextless" (buf: []u8, remote, send_right: u32) -> (n: int, ok: bool) {
	if len(buf) < GATE_HANDSHAKE_SIZE || remote == 0 || send_right == 0 {return}
	for i in 0 ..< GATE_HANDSHAKE_SIZE {buf[i] = 0}
	if !gate_store_u32(buf, 0, MACH_MSGH_BITS_COMPLEX | MACH_MSG_TYPE_COPY_SEND) {return}
	if !gate_store_u32(buf, 4, u32(GATE_HANDSHAKE_SIZE)) {return}
	if !gate_store_u32(buf, 8, remote) {return}
	if !gate_store_u32(buf, 20, 7) {return}
	if !gate_store_u32(buf, GATE_DESC_COUNT_OFF, 1) {return}
	if !gate_store_u32(buf, GATE_DESC_OFF, send_right) {return}
	buf[GATE_DESC_OFF + 10] = u8(MACH_MSG_TYPE_COPY_SEND)
	buf[GATE_DESC_OFF + 11] = u8(MACH_MSG_PORT_DESCRIPTOR)
	return GATE_HANDSHAKE_SIZE, true
}

gate_handshake_send_right :: proc "contextless" (buf: []u8) -> (port: u32, ok: bool) {
	count, count_ok := gate_load_u32(buf, GATE_DESC_COUNT_OFF)
	if !count_ok || count != 1 || len(buf) < GATE_HANDSHAKE_SIZE {return}
	if buf[GATE_DESC_OFF + 11] != u8(MACH_MSG_PORT_DESCRIPTOR) {return}
	port, ok = gate_load_u32(buf, GATE_DESC_OFF)
	if port == 0 {ok = false}
	return
}

Gate_Request :: struct {
	magic, version, command: u32,
	arg0, arg1:              u64,
}

gate_pack_request :: proc "contextless" (
	buf: []u8,
	remote, reply: u32,
	command: Gate_Command,
	arg0, arg1: u64,
	items: []Layout_Item = nil,
) -> (n: int, ok: bool) {
	size := len(items) == 0 ? GATE_MSG_SIZE : GATE_ITEMS_OFF + len(items) * GATE_ITEM_SIZE
	if len(items) > LAYOUT_LIMIT || len(buf) < size || remote == 0 || reply == 0 {return}
	for i in 0 ..< size {buf[i] = 0}
	bits := u32(MACH_MSG_TYPE_COPY_SEND) | u32(MACH_MSG_TYPE_MAKE_SEND_ONCE) << 8
	if !gate_store_u32(buf, 0, bits) {return}
	if !gate_store_u32(buf, 4, u32(size)) {return}
	if !gate_store_u32(buf, 8, remote) {return}
	if !gate_store_u32(buf, 12, reply) {return}
	if !gate_store_u32(buf, 20, 1) {return}
	if !gate_store_u32(buf, GATE_OFF_MAGIC, GATE_MAGIC) {return}
	if !gate_store_u32(buf, GATE_OFF_VERSION, GATE_VERSION) {return}
	if !gate_store_u32(buf, GATE_OFF_COMMAND, u32(command)) {return}
	if !gate_store_u64(buf, GATE_OFF_ARG0, arg0) {return}
	if !gate_store_u64(buf, GATE_OFF_ARG1, arg1) {return}
	if len(items) == 0 {return GATE_MSG_SIZE, true}
	if !gate_store_u32(buf, GATE_ITEMS_HEADER_OFF, u32(len(items))) {return}
	for item, index in items {
		off := GATE_ITEMS_OFF + index * GATE_ITEM_SIZE
		if !gate_store_u32(buf, off, item.wid) {return}
		if !gate_store_i32(buf, off + 4, item.x) {return}
		if !gate_store_i32(buf, off + 8, item.y) {return}
	}
	return size, true
}

// Items of a received LayoutSubmit. The count must match msgh_size exactly,
// so a truncated or padded message is rejected rather than read past.
gate_unpack_items :: proc "contextless" (buf: []u8) -> (items: [LAYOUT_LIMIT]Layout_Item, count: int, ok: bool) {
	size, size_ok := gate_load_u32(buf, 4)
	declared, declared_ok := gate_load_u32(buf, GATE_ITEMS_HEADER_OFF)
	if !size_ok || !declared_ok || declared == 0 || declared > LAYOUT_LIMIT {return}
	if u64(size) != u64(GATE_ITEMS_OFF) + u64(declared) * GATE_ITEM_SIZE || int(size) > len(buf) {return}
	count = int(declared)
	for index in 0 ..< count {
		off := GATE_ITEMS_OFF + index * GATE_ITEM_SIZE
		wid, wid_ok := gate_load_u32(buf, off)
		x, x_ok := gate_load_i32(buf, off + 4)
		y, y_ok := gate_load_i32(buf, off + 8)
		if !wid_ok || !x_ok || !y_ok {return}
		items[index] = {wid, x, y}
	}
	return items, count, true
}

gate_unpack_request :: proc "contextless" (buf: []u8) -> (request: Gate_Request, ok: bool) {
	request.magic, ok = gate_load_u32(buf, GATE_OFF_MAGIC)
	if !ok {return}
	request.version, ok = gate_load_u32(buf, GATE_OFF_VERSION)
	if !ok {return}
	request.command, ok = gate_load_u32(buf, GATE_OFF_COMMAND)
	if !ok {return}
	request.arg0, ok = gate_load_u64(buf, GATE_OFF_ARG0)
	if !ok {return}
	request.arg1, ok = gate_load_u64(buf, GATE_OFF_ARG1)
	return
}

// ipc_kmsg_copyout_header reverses the header. After a successful receive,
// msgh_remote_port (offset 8) is the sender's reply right and the low bits
// name its disposition. msgh_local_port is the receive right dequeued from.
gate_received_reply_right :: proc "contextless" (buf: []u8) -> (port: u32, ok: bool) {
	bits, bits_ok := gate_load_u32(buf, 0)
	if !bits_ok || (bits & 0x1f) != MACH_MSG_TYPE_MOVE_SEND_ONCE {return}
	port, ok = gate_load_u32(buf, 8)
	if port == 0 {ok = false}
	return
}

gate_pack_reply :: proc "contextless" (buf: []u8, reply_right, command: u32, status: i32, data0, data1: u64) -> (n: int, ok: bool) {
	if len(buf) < GATE_MSG_SIZE || reply_right == 0 {return}
	for i in 0 ..< GATE_MSG_SIZE {buf[i] = 0}
	if !gate_store_u32(buf, 0, MACH_MSG_TYPE_MOVE_SEND_ONCE) {return}
	if !gate_store_u32(buf, 4, u32(GATE_MSG_SIZE)) {return}
	if !gate_store_u32(buf, 8, reply_right) {return}
	if !gate_store_u32(buf, GATE_OFF_MAGIC, GATE_REPLY_MAGIC) {return}
	if !gate_store_u32(buf, GATE_OFF_VERSION, GATE_VERSION) {return}
	if !gate_store_u32(buf, GATE_OFF_COMMAND, command) {return}
	if !gate_store_i32(buf, GATE_OFF_COMMAND + 4, status) {return}
	if !gate_store_u64(buf, GATE_OFF_ARG0, data0) {return}
	if !gate_store_u64(buf, GATE_OFF_ARG1, data1) {return}
	return GATE_MSG_SIZE, true
}

Gate_Reply :: struct {
	magic, version, command: u32,
	status:                  i32,
	data0, data1:            u64,
}

gate_unpack_reply :: proc "contextless" (buf: []u8) -> (reply: Gate_Reply, ok: bool) {
	reply.magic, ok = gate_load_u32(buf, GATE_OFF_MAGIC)
	if !ok {return}
	reply.version, ok = gate_load_u32(buf, GATE_OFF_VERSION)
	if !ok {return}
	reply.command, ok = gate_load_u32(buf, GATE_OFF_COMMAND)
	if !ok {return}
	reply.status, ok = gate_load_i32(buf, GATE_OFF_COMMAND + 4)
	if !ok {return}
	reply.data0, ok = gate_load_u64(buf, GATE_OFF_ARG0)
	if !ok {return}
	reply.data1, ok = gate_load_u64(buf, GATE_OFF_ARG1)
	return
}

// The kernel rounds msgh_size to a Mach word before appending the trailer.
// A long receive buffer alone does not prove an audit trailer was delivered.
gate_audit_token :: proc "contextless" (buf: []u8) -> (token: Audit_Token, ok: bool) {
	size, size_ok := gate_load_u32(buf, 4)
	if !size_ok || size < u32(GATE_HEADER_SIZE) {return}
	anchor := (u64(size) + 3) & ~u64(3)
	if anchor + GATE_AUDIT_TRAILER_SIZE > u64(len(buf)) {return}
	trailer_type, type_ok := gate_load_u32(buf, int(anchor))
	trailer_size, trailer_ok := gate_load_u32(buf, int(anchor) + 4)
	if !type_ok || !trailer_ok || trailer_type != MACH_MSG_TRAILER_FORMAT_0 ||
	   trailer_size < GATE_AUDIT_TRAILER_SIZE || anchor + u64(trailer_size) > u64(len(buf)) {return}
	off := int(anchor) + GATE_TRAILER_AUDIT_OFF
	for i in 0 ..< 8 {
		word, word_ok := gate_load_u32(buf, off + i * 4)
		if !word_ok {return}
		token.val[i] = word
	}
	return token, true
}

// Owner-death reclaim predicate (B1 production identity). The gate is
// first-HELLO-wins; a dead owner must not brick it forever. A new HELLO
// reclaims ownership only when the registered owner is confirmed dead
// (ESRCH). Caller supplies liveness; the decision stays pure and testable.
gate_should_reclaim :: proc "contextless" (owner_pid, owner_pidversion, hello_pid, hello_pidversion: u32, owner_alive: bool) -> bool {
	if owner_pid == 0 {return false} // unowned: normal first-claim path
	if owner_alive {return false} // live owner keeps the gate
	if owner_pid == hello_pid && owner_pidversion == hello_pidversion {return false}
	return true
}

// 0 accept, 1 malformed, 3 hello from another process, 4 not the owner.
// The first well-formed HELLO claims ownership. A reused pid with a new
// pidversion does not inherit it.
gate_decide :: proc "contextless" (owner_pid, owner_pidversion: ^u32, audit_ok: bool, pid, pidversion, version, command: u32) -> i32 {
	if !audit_ok || pid == 0 {return 4}
	if version != GATE_VERSION || command < 1 || command > u32(Gate_Command.LayoutSubmit) {return 1}
	if command == u32(Gate_Command.Hello) {
		if owner_pid^ == 0 {
			owner_pid^ = pid
			owner_pidversion^ = pidversion
		}
		if owner_pid^ != pid || owner_pidversion^ != pidversion {return 3}
		return 0
	}
	if owner_pid^ == 0 || pid != owner_pid^ || pidversion != owner_pidversion^ {return 4}
	return 0
}

// User-session bootstrap port. WindowServer's own global is a different
// port; the payload resolves the session port separately.
gate_process_bootstrap_port :: proc() -> (port: u32, ok: bool) {
	kernel := gate_dlopen("/usr/lib/system/libsystem_kernel.dylib", 2)
	if kernel == nil {return}
	symbol := gate_dlsym(kernel, "bootstrap_port")
	if symbol == nil {return}
	port = (^u32)(symbol)^
	return port, port != 0
}
