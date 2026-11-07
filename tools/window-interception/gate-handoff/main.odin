package main

// Gate handoff helper (root, disposable guest). Replaces the bootstrap
// rendezvous that macOS 27 denies to WindowServer (1100 on both register and
// look_up; see lookup-trace-20261103). Reads the gate port name from the
// payload's tgate status file, copies a send right out of WindowServer's
// task with mach_port_extract_right(COPY_SEND), and inserts it into the
// requesting client's task with mach_port_insert_right(COPY_SEND).
//
// Channels are per-pid to survive concurrent clients: a client publishes
// request.<pid> (uid-501 regular file whose contents must repeat the pid)
// and polls response.<pid> for the inserted right name. The helper removes
// each request file after processing. Refusals are printed per request and
// make the helper exit nonzero. Authorization remains the gate's
// audit-token HELLO; the handoff only delivers a capability.
import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:strconv"
import "core:strings"
import "core:time"
import hook "../../../src/experimental/window_server"

foreign import system "system:System"

@(default_calling_convention = "c")
foreign system {
	task_for_pid :: proc(self: u32, pid: i32, task: ^u32) -> i32 ---
	mach_port_extract_right :: proc(task: u32, name: u32, msgt: u32, poly: ^u32, poly_type: ^u32) -> i32 ---
	mach_port_insert_right :: proc(task: u32, name: u32, right: u32, type: u32) -> i32 ---
	mach_port_deallocate :: proc(task: u32, name: u32) -> i32 ---
	opendir :: proc(path: cstring) -> rawptr ---
	readdir :: proc(dir: rawptr) -> ^Dir_Entry ---
	closedir :: proc(dir: rawptr) -> i32 ---
	@(link_name = "unlink") unlink_file :: proc(path: cstring) -> i32 ---
	@(link_name = "mach_task_self") mach_task_self :: proc() -> u32 ---
	@(link_name = "rename") rename_file :: proc(from, to: cstring) -> i32 ---
}

// macOS 64-bit struct dirent.
Dir_Entry :: struct {
	ino:      u64,
	seekoff:  u64,
	reclen:   u16,
	namelen:  u16,
	type:     u8,
	name:     [1024]u8,
}

STATUS_PATH :: hook.TGATE_STATUS_PATH
STATUS_PORT_OFF :: 104 // Tgate_Status.mach_port
COPY_SEND :: 19 // MACH_MSG_TYPE_COPY_SEND

fail :: proc(format: string, args: ..any) {
	fmt.eprintf("FAIL: ")
	fmt.eprintf(format, ..args)
	fmt.eprintf("\n")
}

gate_port_from_status :: proc() -> (port: u32, ok: bool) {
	data, err := os.read_entire_file_from_path(STATUS_PATH, context.allocator)
	if err != nil || len(data) < 144 {
		fail("status file unreadable")
		return
	}
	if string(data[:8]) != "WSOBTGAT" {
		fail("status magic")
		return
	}
	value := u64(0)
	for i in 0 ..< 8 {value |= u64(data[STATUS_PORT_OFF + i]) << (8 * u64(i))}
	if value == 0 || value > u64(max(u32)) {
		fail("status gate port %#x", value)
		return
	}
	return u32(value), true
}

// The request must be a uid-501 regular file whose contents repeat the pid
// encoded in its name; this binds the file to the task it names.
request_pid_valid :: proc(path: string, pid: i32) -> bool {
	fd := posix.open(strings.unsafe_string_to_cstring(path), {.NOFOLLOW})
	if fd < 0 {return false}
	defer posix.close(fd)
	info: posix.stat_t
	if posix.fstat(fd, &info) != nil || !posix.S_ISREG(info.st_mode) || info.st_uid != 501 ||
	   info.st_size <= 0 || info.st_size > 16 {return false}
	buffer: [16]u8
	n := posix.read(fd, &buffer[0], len(buffer))
	if n <= 0 || buffer[n - 1] != '\n' {return false}
	value, parse_ok := strconv.parse_u64(string(buffer[:n - 1]))
	return parse_ok && i64(value) == i64(pid)
}

// Claim by rename first: a second helper instance processing the same
// pending request sees ENOENT and skips it instead of double-inserting.
process_request :: proc(ws_task, gate_port: u32, name: string) -> (refused: bool) {
	pid64, parse_ok := strconv.parse_u64(name)
	if !parse_ok || pid64 == 0 || pid64 > u64(max(i32)) {
		fmt.eprintf("refused %s (bad name)\n", name)
		return true
	}
	pid := i32(pid64)
	request_path := fmt.tprintf("%s.%s", hook.GATE_HANDOFF_REQUEST_PATH, name)
	claimed_path := fmt.tprintf("%s.claimed", request_path)
	if rename_file(strings.unsafe_string_to_cstring(request_path), strings.unsafe_string_to_cstring(claimed_path)) != 0 {
		return false
	}
	defer unlink_file(strings.unsafe_string_to_cstring(claimed_path))
	if !request_pid_valid(claimed_path, pid) {
		fmt.eprintf("refused %s (request file)\n", name)
		return true
	}
	self := mach_task_self()
	client_task: u32
	if code := task_for_pid(self, pid, &client_task); code != 0 {
		// Observed on a physical M1 Max running 26B123: root obtains
		// WindowServer's task port but not an ad-hoc arm64e client's (5).
		// Deliver the right through the client's session rendezvous instead.
		fmt.eprintf("task_for_pid(%d) %#x; trying session rendezvous\n", pid, u32(code))
		return !bootstrap_handshake(ws_task, gate_port, pid)
	}
	send, send_type: u32
	if code := mach_port_extract_right(ws_task, gate_port, u32(COPY_SEND), &send, &send_type); code != 0 {
		fmt.eprintf("refused %d (extract %#x)\n", pid, u32(code))
		return true
	}
	inserted: u32
	last_code: i32
	// COPY_SEND keeps the helper's right valid across collision retries; the
	// helper's own send right is released after the response is published.
	for candidate in u64(0x1000) ..< u64(0x100000) {
		code := mach_port_insert_right(client_task, u32(candidate), send, u32(COPY_SEND))
		if code == 0 {
			inserted = u32(candidate)
			break
		}
		last_code = code
	}
	if inserted == 0 {
		fmt.eprintf("refused %d (insert %#x)\n", pid, u32(last_code))
		mach_port_deallocate(self, send)
		return true
	}
	response_path := fmt.tprintf("%s.%d", hook.GATE_HANDOFF_RESPONSE_PATH, pid)
	temporary := fmt.tprintf("%s.tmp", response_path)
	if os.write_entire_file(temporary, transmute([]u8)fmt.tprintf("%d %d\n", pid, inserted)) != nil {
		fmt.eprintf("refused %d (response write)\n", pid)
		mach_port_deallocate(self, send)
		return true
	}
	if rename_file(strings.unsafe_string_to_cstring(temporary), strings.unsafe_string_to_cstring(response_path)) != 0 {
		fmt.eprintf("refused %d (response rename)\n", pid)
		mach_port_deallocate(self, send)
		return true
	}
	mach_port_deallocate(self, send)
	fmt.printf("gate %#x client %d right %#x\n", gate_port, pid, inserted)
	return false
}

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintf("usage: shoji-gate-handoff WINDOWSERVER_PID\n")
		os.exit(2)
	}
	ws_pid64, ws_ok := strconv.parse_u64(os.args[1])
	if !ws_ok || ws_pid64 == 0 || ws_pid64 > u64(max(i32)) {
		fmt.eprintf("usage: shoji-gate-handoff WINDOWSERVER_PID\n")
		os.exit(2)
	}
	ws_pid := i32(ws_pid64)
	gate_port, port_ok := gate_port_from_status()
	if !port_ok {os.exit(1)}
	self := mach_task_self()
	ws_task: u32
	if code := task_for_pid(self, ws_pid, &ws_task); code != 0 {
		fmt.eprintf("FAIL: task_for_pid(%d) %#x\n", ws_pid, u32(code))
		os.exit(1)
	}
	dir := opendir("/private/tmp")
	if dir == nil {
		fail("opendir")
		os.exit(1)
	}
	prefix := "shoji-gate-handoff-request."
	pending, refused := 0, 0
	for {
		entry := readdir(dir)
		if entry == nil {break}
		name := string(cstring(&entry.name[0]))
		if !strings.has_prefix(name, prefix) {continue}
		if strings.has_suffix(name, ".claimed") {continue}
		pending += 1
		if process_request(ws_task, gate_port, name[len(prefix):]) {refused += 1}
	}
	closedir(dir)
	if pending == 0 {
		fmt.eprintf("FAIL: no pending handoff requests\n")
		os.exit(1)
	}
	if refused != 0 {os.exit(1)}
}

// Fallback delivery when the client's task port is unavailable. The client,
// after its file handoff times out, registers hook.GATE_RENDEZVOUS_NAME in its
// session bootstrap and waits for a handshake carrying the gate send right.
// WindowServer cannot look that name up on macOS 27 (1100); this root helper
// runs in the invoking user's session namespace and can. Authorization is
// still the gate's audit-token HELLO; this only delivers a capability.
RENDEZVOUS_WAIT :: 10 * time.Second // covers the client's 5 s handoff wait.

bootstrap_handshake :: proc(ws_task, gate_port: u32, pid: i32) -> bool {
	failure, code := hook.gate_deliver_to_rendezvous(ws_task, gate_port, RENDEZVOUS_WAIT)
	if failure != .None {
		fmt.eprintf("refused %d (%v %#x)\n", pid, failure, u32(code))
		return false
	}
	fmt.printf("gate %#x client %d via session rendezvous\n", gate_port, pid)
	return true
}
