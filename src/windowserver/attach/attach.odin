package attach

// `shoji --ws-attach`: the only root step of the WindowServer gate, run by
// the daemon as `sudo -n shoji --ws-attach` (one pinned sudoers rule, no
// arguments, so the rule cannot be bent toward another payload or process).
//
//   1. refuse unless root, not disabled, on the supported build, and the
//      installed payload is root-owned and not writable by anyone else;
//   2. inject into the live WindowServer unless it already serves a gate;
//   3. add this binary's CDHash to the gate's clients allowlist;
//   4. hand a send right to the gate to the caller's session rendezvous.
//
// The send right authorizes nothing by itself: the gate still checks the
// receiver's audit token against the allowlist on HELLO.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"
import gate "../gate"
import inject "../../inject"

WS_ATTACH_PAYLOAD :: WS_PAYLOAD_DIR + "/shoji-ws.dylib"
WS_ATTACH_START_WAIT :: 5 * time.Second
WS_ATTACH_START_POLL :: 50 * time.Millisecond
WS_ATTACH_DELIVERY_WAIT :: 3 * time.Second
// Recent Shoji builds stay trusted across a rollback; older ones age out.
WS_ATTACH_CLIENTS_KEEP :: 16
WS_ATTACH_PIDS_LIMIT :: 8192
CDHASH_HEX_LENGTH :: 40

Ws_Attach_Error :: enum {
	None,
	Not_Root,
	Disabled,
	Unsupported_Build,
	Payload_Unsafe,
	No_WindowServer,
	Inject,
	Not_Started,
	Stale_Payload,
	Install_Failed,
	Self_Identity,
	Clients_Write,
	Task_Port,
	Delivery,
}

Ws_Attach_Result :: struct {
	windowserver: i32,
	injected:     bool,
	table_status: u64,
	detail:       string,
}

foreign import attach_system "system:System"
@(default_calling_convention = "c")
foreign attach_system {
	proc_listallpids :: proc(buffer: [^]i32, buffer_size: i32) -> i32 ---
}

ws_attach_cli :: proc(args: []string) -> int {
	if len(args) != 0 {
		fmt.eprintln("--ws-attach takes no arguments")
		return 2
	}
	result, err := ws_attach()
	if err != .None {
		fmt.eprintf("WindowServer gate attach failed: %v", err)
		if result.detail != "" {fmt.eprintf(" (%s)", result.detail)}
		fmt.eprintln()
		#partial switch err {
		case .Disabled, .Unsupported_Build, .Payload_Unsafe, .Stale_Payload, .Install_Failed:
			return WS_ATTACH_EXIT_REFUSED
		}
		return 1
	}
	fmt.printf(
		"WindowServer gate attached: pid %d, %s, table status %d\n",
		result.windowserver,
		result.injected ? "injected" : "already resident",
		result.table_status,
	)
	return 0
}

ws_attach :: proc() -> (result: Ws_Attach_Result, err: Ws_Attach_Error) {
	if err = ws_attach_preflight(&result); err != .None {return}
	result.windowserver = ws_attach_find_windowserver()
	if result.windowserver <= 0 {return result, .No_WindowServer}
	self := gate.gate_mach_task_self()
	task: u32
	if code := gate.gate_task_for_pid(self, result.windowserver, &task); code != 0 {
		result.detail = fmt.tprintf("task_for_pid %d", code)
		return result, .Task_Port
	}
	defer gate.gate_mach_port_deallocate(self, task)
	status, resident := ws_attach_read_status(result.windowserver)
	if !resident {
		status, err = ws_attach_load(&result, task)
		if err != .None {return}
	}
	result.table_status = status.status
	if status.mach_port == 0 || status.mach_port > u64(max(u32)) {
		result.detail = fmt.tprintf("gate port missing, mach code %d", status.mach_code)
		return result, .Not_Started
	}
	if err = ws_attach_trust_self(); err != .None {return}
	err = ws_attach_deliver(task, u32(status.mach_port), &result.detail)
	return
}

ws_attach_preflight :: proc(result: ^Ws_Attach_Result) -> Ws_Attach_Error {
	if posix.geteuid() != 0 {return .Not_Root}
	if os.exists(WS_DISABLE_SENTINEL) {return .Disabled}
	if build := os_build(); build != gate.BUILD {
		result.detail = build
		return .Unsupported_Build
	}
	if !ws_attach_payload_installed() {return .Payload_Unsafe}
	return .None
}

// Injects into a WindowServer that has no Shoji payload yet and waits for
// the gate status. A payload stays until WindowServer exits, and logging out
// does not restart WindowServer; a resident payload that cannot prove a gate
// (older format, or failed) needs `sudo killall -9 WindowServer`.
ws_attach_load :: proc(
	result: ^Ws_Attach_Result,
	task: u32,
) -> (
	status: gate.Tgate_Status,
	err: Ws_Attach_Error,
) {
	switch ws_images_scan(task) {
	case .Clean:
	case .Shoji_Payload:
		result.detail = "a Shoji payload without a usable gate is loaded; restart WindowServer"
		if install, ok := ws_attach_install_status(); ok && install != 0 {
			result.detail = fmt.tprintf(
				"the loaded Shoji payload failed to install (status %d); restart WindowServer",
				install,
			)
		}
		return {}, .Stale_Payload
	case .Unreadable:
		result.detail = "cannot read WindowServer's image list"
		return {}, .Inject
	}
	// sudo clears the environment; the loader requires the explicit opt-in.
	posix.setenv(gate.EXPERIMENT_ENV, "1", true)
	if message := inject.inject_windowserver(WS_ATTACH_PAYLOAD, result.windowserver);
	   message != "" {
		result.detail = message
		return {}, .Inject
	}
	result.injected = true
	ok: bool
	status, ok = ws_attach_wait_status(result.windowserver)
	if ok {return status, .None}
	if install, install_ok := ws_attach_install_status(); install_ok && install != 0 {
		result.detail = fmt.tprintf("payload install status %d; restart WindowServer", install)
		return {}, .Install_Failed
	}
	result.detail = "payload wrote no gate status"
	return {}, .Not_Started
}

// Root must own the payload and its directory, and nobody else may write
// either: whoever can replace the file chooses code that runs in WindowServer.
ws_attach_payload_safe :: proc(file_uid, file_mode, dir_uid, dir_mode: u32) -> bool {
	return file_uid == 0 &&
		file_mode & gate.S_IFMT_BITS == gate.S_IFREG_BITS &&
		file_mode & 0o022 == 0 &&
		dir_uid == 0 &&
		dir_mode & gate.S_IFMT_BITS == gate.S_IFDIR_BITS &&
		dir_mode & 0o022 == 0
}

ws_attach_payload_installed :: proc() -> bool {
	file, dir: posix.stat_t
	if posix.lstat(WS_ATTACH_PAYLOAD, &file) != .OK {return false}
	if posix.lstat(WS_PAYLOAD_DIR, &dir) != .OK {return false}
	return ws_attach_payload_safe(
		u32(file.st_uid),
		u32(transmute(u16)file.st_mode),
		u32(dir.st_uid),
		u32(transmute(u16)dir.st_mode),
	)
}

ws_attach_find_windowserver :: proc() -> i32 {
	pids := make([]i32, WS_ATTACH_PIDS_LIMIT, context.temp_allocator)
	count := proc_listallpids(raw_data(pids), i32(len(pids) * size_of(i32)))
	if count <= 0 {return 0}
	found: i32 = 0
	for pid in pids[:min(int(count), len(pids))] {
		if pid <= 0 || !gate.valid_path(inject.windowserver_process_path(pid)) {continue}
		// Two system WindowServers would make the target ambiguous.
		if found != 0 {return 0}
		found = pid
	}
	return found
}

ws_attach_read_status :: proc(windowserver: i32) -> (status: gate.Tgate_Status, ok: bool) {
	fd := posix.open(gate.TGATE_STATUS_PATH, {.NOFOLLOW, .CLOEXEC})
	if fd < 0 {return}
	defer posix.close(fd)
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK {return}
	// One extra byte detects a file longer than the expected status.
	data: [size_of(gate.Tgate_Status) + 1]u8
	n := posix.read(fd, &data[0], len(data))
	if n < 0 {return}
	return gate.tgate_status_decode(data[:n], u32(st.st_uid), windowserver)
}

ws_attach_wait_status :: proc(windowserver: i32) -> (status: gate.Tgate_Status, ok: bool) {
	deadline := time.time_add(time.now(), WS_ATTACH_START_WAIT)
	for {
		status, ok = ws_attach_read_status(windowserver)
		if ok || time.diff(time.now(), deadline) <= 0 {return}
		time.sleep(WS_ATTACH_START_POLL)
	}
}

// Returns the allowlist with `self` as the newest entry, keeping at most
// `keep` well-formed entries. Malformed entries are dropped: they never match.
ws_attach_clients_merge :: proc(existing, self: string, keep: int) -> string {
	assert(len(self) == CDHASH_HEX_LENGTH && keep > 0)
	entries := make([dynamic]string, 0, keep, context.temp_allocator)
	rest := existing
	for entry in strings.fields_iterator(&rest) {
		for part in strings.split(entry, ",", context.temp_allocator) {
			if !ws_attach_cdhash_hex(part) || part == self {continue}
			if len(entries) == keep - 1 {ordered_remove(&entries, 0)}
			append(&entries, part)
		}
	}
	append(&entries, self)
	b := strings.builder_make(context.temp_allocator)
	for entry in entries {
		strings.write_string(&b, entry)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

ws_attach_cdhash_hex :: proc(text: string) -> bool {
	if len(text) != CDHASH_HEX_LENGTH {return false}
	for c in transmute([]u8)text {
		if !(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f') {return false}
	}
	return true
}

ws_attach_trust_self :: proc() -> Ws_Attach_Error {
	hash: [20]u8
	if csops(i32(posix.getpid()), 5, &hash, len(hash)) != 0 {return .Self_Identity}
	existing := ""
	if data, _, ok := read_limited(WS_CLIENTS_PATH, gate.GATE_CLIENTS_LIMIT); ok {
		existing = string(data)
	}
	merged := ws_attach_clients_merge(existing, hex(hash[:]), WS_ATTACH_CLIENTS_KEEP)
	if merged == existing {return .None}
	if len(merged) > gate.GATE_CLIENTS_LIMIT {return .Clients_Write}
	return ws_attach_write_clients(merged) ? .None : .Clients_Write
}

// Writes beside the target and renames, so the gate never reads a partial file.
ws_attach_write_clients :: proc(content: string) -> bool {
	temporary :: WS_CLIENTS_PATH + ".tmp"
	posix.unlink(temporary)
	flags := posix.O_Flags{.WRONLY, .CREAT, .EXCL, .NOFOLLOW, .CLOEXEC}
	fd := posix.open(temporary, flags, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if fd < 0 {return false}
	written := posix.write(fd, raw_data(content), uint(len(content))) == len(content)
	// fchmod: the creation mode is filtered by the caller's umask.
	owned := posix.fchmod(fd, {.IRUSR, .IWUSR, .IRGRP, .IROTH}) == .OK
	synced := posix.fsync(fd) == .OK
	closed := posix.close(fd) == .OK
	if !(written && owned && synced && closed) || posix.rename(temporary, WS_CLIENTS_PATH) != 0 {
		posix.unlink(temporary)
		return false
	}
	return true
}

ws_attach_deliver :: proc(task, gate_port: u32, detail: ^string) -> Ws_Attach_Error {
	failure, code := gate.gate_deliver_to_rendezvous(task, gate_port, WS_ATTACH_DELIVERY_WAIT)
	if failure != .None {
		detail^ = fmt.tprintf("%v %d", failure, code)
		return .Delivery
	}
	return .None
}
