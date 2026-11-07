package shoji

// D2: user-facing WindowServer diagnostics. `shoji --ws-report [DIR]` prints
// an install report and, when the gate can be reached, exports the
// observer's event ring (raw + decoded JSON) for bug reports. Read-only
// except for the gate's own Dump, which only writes the ring snapshot.

import "core:crypto/sha2"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"
import gate "windowserver/gate"
import ipc "ipc"

WS_PAYLOAD_DIR :: "/Library/GPUBundles/ShojiWindowServerProbe"
WS_PAYLOAD_PATH :: WS_PAYLOAD_DIR + "/shoji-ws.dylib"
WS_CLIENTS_PATH :: WS_PAYLOAD_DIR + "/clients"
WS_RING_PATH :: gate.OBSERVER_RESPONSE_PATH
WS_SUPPORTED_BUILD :: gate.BUILD

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
ws_ring_decode :: proc(data: []u8, allocator := context.temp_allocator) -> (ring: Ws_Ring, err: string) {
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
		if sequence == 0 {continue}
		before, after := le(data, off + 16, u64), le(data, off + 24, u64)
		captured := le(data, off + 44, u32)
		if sequence > calls || after < before || captured > 4 {
			return {}, "inconsistent ring event"
		}
		for e in events {if e.sequence == sequence {return {}, "duplicate ring sequence"}}
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
	content: string, file_uid, file_mode: u32, file_size: i64,
	dir_uid, dir_mode: u32, self_cdhash: []u8,
) -> Ws_Clients_Report {
	r := Ws_Clients_Report{present = true}
	r.trusted = gate.gate_allowlist_trusted(file_uid, file_mode, file_size, dir_uid, dir_mode)
	start := 0
	for i in 0 ..= len(content) {
		if i == len(content) || gate.gate_allowlist_separator(content[i]) {
			if i - start == 40 {r.entries += 1}
			start = i + 1
		}
	}
	r.listed = r.trusted && len(self_cdhash) == 20 && gate.gate_identity_matches_any(content, self_cdhash, 0)
	return r
}

// ------------------------------------------------------------------------
// CLI
// ------------------------------------------------------------------------

foreign import system "system:System"
foreign system {
	csops :: proc "c" (pid: i32, ops: u32, useraddr: rawptr, usersize: uintptr) -> i32 ---
}

hex :: proc(bytes: []u8) -> string {
	b := strings.builder_make(context.temp_allocator)
	for v in bytes {fmt.sbprintf(&b, "%02x", v)}
	return strings.to_string(b)
}

os_build :: proc() -> string {
	build: [32]u8
	length := uintptr(len(build))
	if sysctlbyname("kern.osversion", &build[0], &length, nil, 0) != 0 || length == 0 {return "unknown"}
	return strings.clone(string(build[:length - 1]), context.temp_allocator)
}

read_limited :: proc(path: string, limit: int) -> (data: []u8, st: posix.stat_t, ok: bool) {
	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.NOFOLLOW, .CLOEXEC})
	if fd < 0 {return}
	defer posix.close(fd)
	if posix.fstat(fd, &st) != .OK || i64(st.st_size) <= 0 || i64(st.st_size) > i64(limit) {return}
	data = make([]u8, int(st.st_size), context.temp_allocator)
	if i64(posix.read(fd, &data[0], len(data))) != i64(st.st_size) {return}
	return data, st, true
}

// Ask a running daemon (which may own the gate) before claiming directly.
@(private = "file")
daemon_request :: proc(args: []string) -> (text: string, reached: bool) {
	data, ok := ipc.encode_message(args)
	if !ok {return}
	defer delete(data)
	fd := connect_socket(ipc.socket_path())
	if fd < 0 {return}
	defer close(fd)
	if !write_all(fd, data) {return}
	shutdown(fd, 1)
	deadline := time.time_add(time.now(), 5 * time.Second)
	b := strings.builder_make(context.temp_allocator)
	buffer: [4096]u8
	for wait_socket(fd, 1, deadline) {
		n := recv(fd, &buffer[0], len(buffer), 0)
		if n <= 0 {break}
		strings.write_bytes(&b, buffer[:n])
	}
	text = strings.to_string(b)
	if len(text) > 0 && text[0] == 7 {text = text[1:]} // failure marker
	return strings.trim_space(text), true
}

ws_report_cli :: proc(args: []string) -> int {
	out_dir := len(args) > 0 ? args[0] : ""
	started := time.now()
	build := os_build()
	fmt.printf("macOS build: %s (payload supports %s: %s)\n", build, WS_SUPPORTED_BUILD, build == WS_SUPPORTED_BUILD ? "yes" : "no")

	disable_env := os.get_env(WS_DISABLE_ENV, context.temp_allocator) == "1"
	sentinel := os.exists(WS_DISABLE_SENTINEL)
	fmt.printf("kill switch: %s (env %v, sentinel %v)\n", disable_env || sentinel ? "ON" : "off", disable_env, sentinel)

	if payload, _, ok := read_limited(WS_PAYLOAD_PATH, 64 << 20); ok {
		ctx: sha2.Context_256
		sha2.init_256(&ctx)
		sha2.update(&ctx, payload)
		digest: [32]u8
		sha2.final(&ctx, digest[:])
		fmt.printf("payload: installed sha256=%s\n", hex(digest[:]))
	} else {
		fmt.println("payload: not installed")
	}
	fmt.printf("payload resident: %v (status file %s)\n", ws_tgate_present(), WS_TGATE_STATUS_PATH)

	self: [20]u8
	self_ok := csops(i32(posix.getpid()), 5, &self, len(self)) == 0
	fmt.printf("this binary CDHash: %s\n", self_ok ? hex(self[:]) : "unavailable (unsigned?)")
	dir: posix.stat_t
	content, file, clients_ok := read_limited(WS_CLIENTS_PATH, gate.GATE_CLIENTS_LIMIT)
	if clients_ok && posix.lstat(WS_PAYLOAD_DIR, &dir) == .OK {
		r := ws_clients_evaluate(
			string(content), u32(file.st_uid), u32(transmute(u16)file.st_mode), i64(file.st_size),
			u32(dir.st_uid), u32(transmute(u16)dir.st_mode), self_ok ? self[:] : nil,
		)
		fmt.printf(
			"clients file: %d entries, %s, this binary %s\n", r.entries,
			r.trusted ? "root-owned" : "UNTRUSTED (must be root-owned, not group/world-writable)",
			r.listed ? "listed" : "NOT listed (run lifecycle/trust-client.sh as root)",
		)
	} else {
		fmt.println("clients file: absent (only build-time pins can claim the gate)")
	}

	dumped := false
	if text, reached := daemon_request({"debug", "ws", "dump"}); reached {
		fmt.printf("daemon: %s\n", text)
		dumped = strings.contains(text, "ring=")
	} else if disable_env || sentinel {
		fmt.println("gate: not contacted (kill switch)")
	} else {
		// No daemon: claim briefly. A live owner refuses us; that is reported.
		a: Ws_Adapter
		ws_adapter_open(&a, true)
		fmt.printf("gate (direct claim): %s\n", ws_adapter_describe(&a))
		if calls, ok := ws_dump(&a); ok {
			fmt.printf("gate: %d forwarded calls\n", calls)
			dumped = true
		}
		ws_adapter_close(&a)
	}

	if out_dir == "" {return 0}
	if !dumped {
		fmt.println("event ring: not exported (gate not reachable)")
		return 1
	}
	raw, st, ok := read_limited(WS_RING_PATH, WS_RING_SIZE)
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
	if merr != nil || os.write_entire_file(bin_path, raw) != nil || os.write_entire_file(json_path, encoded) != nil {
		fmt.printf("event ring: cannot write to %s\n", out_dir)
		return 1
	}
	fmt.printf("event ring: %d calls, %d retained → %s, %s\n", ring.calls, ring.retained, bin_path, json_path)
	return 0
}
