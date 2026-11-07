package shoji

import dock "dock"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:time"
import support "support"
import health "health"

// Scripting-addition protocol client
// ------------------------------------------------------------------------

addition_connect :: proc() -> i32 {
	return connect_socket(fmt.tprintf("/tmp/shoji-sa_%d.socket", getuid()))
}

addition_exchange :: proc(
	packet: ^dock.Packet,
	handshake: bool = false,
	created_space: ^u64 = nil,
) -> (
	dock.Capabilities,
	string,
) {
	fd := addition_connect()
	if fd < 0 {
		return {}, "Dock scripting addition is not loaded; use --load-sa"
	}; defer close(fd)

	uid, gid: u32
	if getpeereid(fd, &uid, &gid) != 0 || uid != getuid() {
		return {}, "unexpected scripting-addition socket owner"
	}

	if !write_all(fd, dock.finish(packet)) {
		return {}, "could not send scripting-addition request"
	}

	status: [1]u8
	if !read_exact(fd, status[:]) {
		return {}, "scripting addition did not acknowledge request"
	}

	if status[0] == u8(dock.Status.Native_Error) {
		data: [5]u8
		if !read_exact(fd, data[:]) {
			return {}, "incomplete scripting-addition native error"
		}
		r := dock.reader(data[:])
		stage := dock.unpack(&r, dock.Native_Stage)
		code := dock.unpack(&r, i32)
		return {}, fmt.tprintf(
			"scripting addition failed at %v (native error %d)",
			stage,
			code,
		)
	}

	if status[0] != u8(dock.Status.OK) {
		return {}, fmt.tprintf(
			"scripting addition returned %v",
			dock.Status(status[0]),
		)
	}

	if handshake {
		data: [len(dock.VERSION) + 5]u8
		if !read_exact(fd, data[:]) {
			return {}, "incomplete scripting-addition handshake"
		}

		caps, ok := dock.handshake(data[:]); if !ok {
			return {}, "incompatible scripting-addition protocol"
		}

		return caps, ""
	}

	if created_space != nil {
		data: [8]u8
		if !read_exact(fd, data[:]) {
			return {}, "incomplete tracked Space creation response"
		}

		r := dock.reader(data[:]); created_space^ = dock.unpack(&r, u64)
		if created_space^ == 0 {
			return {}, "payload did not identify its created Space"
		}
	}

	return {}, ""
}

addition_create_tracked_space :: proc(anchor: u64) -> (u64, string) {
	caps, err := addition_check()
	if err != "" {
		return 0, err
	}

	if .Tracked_Space_Create not_in caps {
		return 0,
			"loaded payload lacks tracked Space creation; load the rebuilt payload into a fresh Dock"
	}

	packet := dock.begin(.Space_Create_Tracked)
	dock.pack(&packet, anchor)

	id: u64
	_, err = addition_exchange(&packet, created_space = &id)
	return id, err
}

addition_check :: proc() -> (dock.Capabilities, string) {
	packet := dock.begin(.Handshake)
	return addition_exchange(&packet, true)
}

// Gated Space move (C4): Window_To_Space_Transaction commits synchronously
// through the transaction table so the WindowServer gate can apply a staged
// landing. Matches Ws_Space_Send; refuses payloads without the capability.
addition_space_transaction :: proc(_: rawptr, target: u64, wid: u32, source: u64) -> string {
	caps, err := addition_check()
	if err != "" {return err}
	if .Space_Transaction not_in caps {return "Dock payload lacks transactional Space moves"}
	packet := dock.begin(.Window_To_Space_Transaction)
	dock.pack(&packet, target)
	dock.pack(&packet, wid)
	dock.pack(&packet, source)
	_, err = addition_exchange(&packet)
	return err
}

addition_action :: proc(action: Action) -> string {
	caps, err := addition_check(); if err != "" {
		return err
	}

	packet: dock.Packet

	#partial switch action.kind {
	case .Order:
		packet = dock.begin(.Window_Order); dock.pack(&packet, action.window)
		dock.pack(&packet, i32(action.value))
		dock.pack(&packet, action.relative)
	case .Scale:
		packet = dock.begin(.Window_Scale); dock.pack(&packet, action.window)
		dock.pack(&packet, f32(action.frame.x))
		dock.pack(&packet, f32(action.frame.y))
		dock.pack(&packet, f32(action.frame.w))
		dock.pack(&packet, f32(action.frame.h))
	case .Focus_Without_Raise:
		packet = dock.begin(.Window_Focus)
		dock.pack(&packet, action.window)
	case .Space_Focus, .Space_Create, .Space_Destroy:
		op := dock.Opcode.Space_Focus

		if action.kind == .Space_Create {
			op = .Space_Create
		}

		if action.kind == .Space_Destroy {
			op = .Space_Destroy
		}
		packet = dock.begin(op); dock.pack(&packet, action.space)
	case .Space_Move:
		packet = dock.begin(.Space_Move); dock.pack(&packet, action.space)
		dock.pack(&packet, action.destination)
		dock.pack(&packet, u64(0))
		dock.pack(&packet, false)
	case .Space:
		packet = dock.begin(.Window_To_Space); dock.pack(&packet, action.space)
		dock.pack(&packet, action.window)
	case .Opacity:
		packet = dock.begin(
			action.duration > 0 \
				? dock.Opcode.Window_Opacity_Fade \
				: dock.Opcode.Window_Opacity,
		)
		dock.pack(&packet, action.window)
		dock.pack(&packet, f32(action.value))
		if action.duration > 0 {
			dock.pack(&packet, f32(action.duration))
		}
	case .Layer:
		level := dock.window_layer_key(action.value, caps)
		packet = dock.begin(.Window_Layer); dock.pack(&packet, action.window)
		dock.pack(&packet, level)
	case .Sticky, .Shadow:
		packet = dock.begin(
			action.kind == .Sticky \
				? dock.Opcode.Window_Sticky \
				: dock.Opcode.Window_Shadow,
		)
		dock.pack(&packet, action.window)
		dock.pack(&packet, action.flag)
	case:
		return "unsupported scripting-addition action"
	}
	_, err = addition_exchange(&packet)

	return err
}

// Scripting-addition reload
// ------------------------------------------------------------------------

Addition_Reload_Phase :: enum {
	Check,
	Load,
}
Addition_Reload_Spawn :: proc(
	user: rawptr,
	phase: Addition_Reload_Phase,
	binary, payload: string,
) -> (
	pid: i32,
	output_fd: i32, // Nonblocking read end of the child's stderr, or -1.
	err: string,
)
Addition_Reload :: struct {
	binary, payload: string,
	dock, child, child_dock: i32,
	phase: Addition_Reload_Phase,
	healthy, loaded: bool,
	next_attempt: time.Time,
	retry_delay: time.Duration,
	spawn: Addition_Reload_Spawn,
	user: rawptr,
	// The child's stderr is captured so failures report their real cause.
	output_fd: i32,
	output_open: bool, // output_fd is owned only while this is set.
	output: health.Output_Tail,
	spawned_at: time.Time,
	payload_health: health.Payload_Health,
	// Set by a state change; consumed once by the notification owner.
	transition: health.Health_Transition,
	crash_directory: string, // Overrides the user's crash reports for tests.
}

ADDITION_PAYLOAD_NAME :: "shoji-sa.dylib"

// The Dock payload ships beside the executable: Contents/Resources in the app
// bundle, or the same directory in a development build (bin/).
addition_payload_path :: proc() -> (path: string, err: string) {
	binary, binary_err := os.get_executable_path(context.temp_allocator)
	if binary_err != nil {return "", "cannot resolve shoji executable path"}
	dir := filepath.dir(binary)
	contents := filepath.dir(dir)
	candidates := [2]string {
		fmt.tprintf("%s/Resources/%s", contents, ADDITION_PAYLOAD_NAME),
		fmt.tprintf("%s/%s", dir, ADDITION_PAYLOAD_NAME),
	}
	for candidate in candidates {
		if os.is_file(candidate) {return candidate, ""}
	}
	return "", fmt.tprintf("Dock payload %s not found beside %s", ADDITION_PAYLOAD_NAME, binary)
}

addition_reload_init :: proc(r: ^Addition_Reload, payload: string) -> string {
	if payload == "" {
		return ""
	}
	path, err := filepath.abs(payload, context.temp_allocator)
	if err != nil || !os.is_file(path) {
		return "scripting-addition library does not exist or is not a file"
	}
	binary, binary_err := os.get_executable_path(context.temp_allocator)
	if binary_err != nil {
		return "cannot resolve shoji executable path"
	}
	r.payload = strings.clone(path)
	r.binary = strings.clone(binary)
	return ""
}
addition_reload_destroy :: proc(r: ^Addition_Reload) {
	// The standalone loader owns its remote operation and completion cleanup.
	// Do not interrupt an in-flight injection when the daemon shuts down.
	addition_reload_close_output(r)
	delete(r.payload); delete(r.binary)
	r^ = {}
}
addition_reload_close_output :: proc(r: ^Addition_Reload) {
	if r.output_open {
		posix.close(posix.FD(r.output_fd))
	}
	r.output_open = false
	r.output_fd = -1
}

// The other file-action bindings are declared with the process helpers.
@(default_calling_convention = "c")
foreign {
	posix_spawn_file_actions_addclose :: proc(actions: ^rawptr, fd: i32) -> posix.Errno ---
}

// Starts argv with stderr redirected to a new pipe. The read end is
// nonblocking and close-on-exec; the caller owns it.
spawn_with_stderr_pipe :: proc(argv: []cstring) -> (pid: i32, output_fd: i32, err: string) {
	assert(len(argv) > 0 && argv[len(argv) - 1] == nil)
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK {
		return 0, -1, "cannot create recovery output pipe"
	}
	actions: rawptr
	if support.posix_spawn_file_actions_init(&actions) != .NONE {
		posix.close(fds[0]); posix.close(fds[1])
		return 0, -1, "cannot prepare recovery subprocess"
	}
	defer support.posix_spawn_file_actions_destroy(&actions)
	support.posix_spawn_file_actions_adddup2(&actions, i32(fds[1]), 2)
	posix_spawn_file_actions_addclose(&actions, i32(fds[0]))
	posix_spawn_file_actions_addclose(&actions, i32(fds[1]))
	child: posix.pid_t
	code := posix.posix_spawn(&child, argv[0], &actions, nil, raw_data(argv), _NSGetEnviron()^)
	posix.close(fds[1])
	if code != nil {
		posix.close(fds[0])
		return 0, -1, "cannot start scripting-addition recovery subprocess"
	}
	posix.fcntl(fds[0], .SETFL, posix.O_NONBLOCK)
	posix.fcntl(fds[0], .SETFD, posix.FD_CLOEXEC)
	return i32(child), i32(fds[0]), ""
}

addition_reload_spawn :: proc(
	user: rawptr,
	phase: Addition_Reload_Phase,
	binary, payload: string,
) -> (
	i32,
	i32,
	string,
) {
	binary_c := strings.clone_to_cstring(binary, context.temp_allocator)
	if phase == .Load {
		// The root side resolves the payload itself, so the sudoers rule can
		// pin `shoji --load-sa` exactly.
		args := [5]cstring{"/usr/bin/sudo", "-n", binary_c, "--load-sa", nil}
		return spawn_with_stderr_pipe(args[:])
	}
	args := [3]cstring{binary_c, "--check-sa", nil}
	return spawn_with_stderr_pipe(args[:])
}
addition_reload_backoff :: proc(r: ^Addition_Reload, now: time.Time) {
	r.retry_delay =
		r.retry_delay == 0 \
			? time.Second \
			: min(r.retry_delay * 2, 30 * time.Second)
	r.next_attempt = time.time_add(now, r.retry_delay)
}
addition_reload_tick :: proc(r: ^Addition_Reload, dock_pid: i32, now: time.Time) {
	if r.payload == "" {
		return
	}
	if r.output_open && !health.output_tail_drain(&r.output, r.output_fd) {
		addition_reload_close_output(r)
	}
	if dock_pid != r.dock {
		r.dock = dock_pid
		r.healthy, r.loaded = false, false
		r.phase = .Check
		r.next_attempt = now
		r.retry_delay = 0
	}
	if dock_pid == 0 ||
	   r.child != 0 ||
	   r.healthy ||
	   time.diff(now, r.next_attempt) > 0 {
		return
	}
	spawn := r.spawn
	if spawn == nil {
		spawn = addition_reload_spawn
	}
	pid, output_fd, err := spawn(r.user, r.phase, r.binary, r.payload)
	if err != "" || pid <= 0 {
		if output_fd >= 0 {posix.close(posix.FD(output_fd))}
		cause := fmt.tprintf("Dock payload recovery: %s", err)
		fmt.eprintln("shoji:", cause)
		addition_reload_record_failure(r, cause, "", now)
		addition_reload_backoff(r, now)
		return
	}
	addition_reload_close_output(r)
	r.output = {}
	r.output_fd = output_fd
	r.output_open = output_fd >= 0
	r.spawned_at = now
	r.child, r.child_dock = pid, dock_pid
}

addition_reload_record_failure :: proc(
	r: ^Addition_Reload,
	cause, crash_report: string,
	now: time.Time,
) {
	transition := health.payload_health_failure(&r.payload_health, cause, crash_report, now)
	if transition != .None {
		r.transition = transition
	}
}

// Collects the finished child's output, forwards it to the log, and returns
// the evidence-based cause plus any crash report written since the spawn.
addition_reload_collect :: proc(
	r: ^Addition_Reload,
	exit: health.Child_Exit,
) -> (
	cause, crash_report: string,
) {
	if r.output_open {
		health.output_tail_drain(&r.output, r.output_fd)
		addition_reload_close_output(r)
	}
	output := health.output_tail_text(&r.output)
	if output != "" {
		fmt.eprint(output)
		if !strings.has_suffix(output, "\n") {fmt.eprintln()}
	}
	action := r.phase == .Load ? "Dock payload load failed" : "Dock payload check failed"
	cause = health.payload_failure_cause(action, exit, output)
	directory := r.crash_directory
	if directory == "" {
		directory = health.user_crash_report_directory()
	}
	if directory != "" {
		crash_report = health.crash_report_newest(directory, health.CRASH_REPORT_PREFIX, r.spawned_at)
	}
	return
}

addition_reload_finished :: proc(
	r: ^Addition_Reload,
	child: i32,
	exit: health.Child_Exit,
	now: time.Time,
) -> bool {
	if child == 0 || child != r.child {
		return false
	}
	r.child = 0
	success := health.child_exit_ok(exit)
	cause, crash_report := "", ""
	if !success {
		cause, crash_report = addition_reload_collect(r, exit)
	} else {
		addition_reload_close_output(r)
	}
	// A subprocess completing for an old Dock cannot establish current health.
	if r.child_dock != r.dock {
		return true
	}
	if r.phase == .Check {
		addition_reload_check_finished(r, success, cause, crash_report, now)
	} else {
		addition_reload_load_finished(r, success, cause, crash_report, now)
	}
	return true
}

addition_reload_check_finished :: proc(
	r: ^Addition_Reload,
	success: bool,
	cause, crash_report: string,
	now: time.Time,
) {
	if success {
		r.healthy = true
		r.retry_delay = 0
		if transition := health.payload_health_success(&r.payload_health, now); transition != .None {
			r.transition = transition
		}
		fmt.eprintln("shoji: Dock payload is ready")
	} else if !r.loaded {
		// Expected before the first load: the payload is not resident yet.
		r.phase = .Load
		r.next_attempt = now
	} else {
		fmt.eprintln("shoji: loaded payload handshake failed; retrying verification:", cause)
		addition_reload_record_failure(r, cause, crash_report, now)
		addition_reload_backoff(r, now)
	}
}

addition_reload_load_finished :: proc(
	r: ^Addition_Reload,
	success: bool,
	cause, crash_report: string,
	now: time.Time,
) {
	r.phase = .Check
	if success {
		r.loaded = true
		r.next_attempt = now
		return
	}
	if crash_report != "" {
		fmt.eprintf("shoji: %s; crash report: %s; retrying\n", cause, crash_report)
	} else {
		fmt.eprintf("shoji: %s; retrying\n", cause)
	}
	addition_reload_record_failure(r, cause, crash_report, now)
	addition_reload_backoff(r, now)
}
