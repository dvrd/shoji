package shoji

// Daemon side of the WindowServer gate. `config windowserver_gate on`
// (normally from shojirc) only records the request; the main loop then runs
// `sudo -n shoji --ws-attach` in the background and receives the gate's send
// right on the session rendezvous, so the config run is never blocked.
//
// Lifetime: the rendezvous receive right is registered on the first attempt
// and kept until shutdown. A WindowServer restart ends the login session and
// with it this daemon, so a served gate is never re-attached in place.

import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:time"
import gate "windowserver/gate"

WS_ATTACH_ATTEMPTS :: 5
WS_ATTACH_RETRY_FIRST :: 2 * time.Second
WS_ATTACH_RETRY_MAX :: 30 * time.Second
// Covers injection (≤5 s), delivery (≤3 s) and sudo itself.
WS_ATTACH_CHILD_LIMIT :: 15 * time.Second
// `--ws-attach` exit status for refusals that a retry cannot fix.
WS_ATTACH_EXIT_REFUSED :: 3

Ws_Attach_State :: enum {
	Off,
	Waiting, // requested; next attempt pending
	Attaching, // child running
	Serving,
	Failed, // attempts exhausted or refused; `config windowserver_gate on` retries
}

Ws_Attach_Runtime :: struct {
	ws:           ^Ws_Adapter,
	manager:      ^Manager,
	state:        Ws_Attach_State,
	child:        i32,
	child_start:  time.Time,
	killed:       bool,
	output:       Output_Tail,
	output_fd:    i32,
	output_open:  bool,
	rendezvous:   u32,
	attempts:     u32,
	retry_delay:  time.Duration,
	next_attempt: time.Time,
	cause:        Bounded_Text(HEALTH_TEXT_BYTES),
	failed_event: bool, // Failed transition not yet notified.
}

Ws_Attach_Outcome :: enum {
	Connected,
	Retry,
	Give_Up,
}

ws_attach_runtime_start :: proc(r: ^Ws_Attach_Runtime, adapter: ^Ws_Adapter, m: ^Manager) {
	r^ = {ws = adapter, manager = m, output_fd = -1}
	m.ws_gate_control = ws_attach_control
	m.ws_gate_user = r
}

ws_attach_runtime_stop :: proc(r: ^Ws_Attach_Runtime) {
	if r.child != 0 {posix.kill(posix.pid_t(r.child), .SIGKILL)}
	ws_attach_close_output(r)
	if r.rendezvous != 0 {
		gate.gate_mach_port_destroy(gate.gate_mach_task_self(), r.rendezvous)
		r.rendezvous = 0
	}
}

ws_attach_state_name :: proc(state: Ws_Attach_State) -> string {
	switch state {
	case .Off:
		return "off"
	case .Waiting:
		return "waiting"
	case .Attaching:
		return "attaching"
	case .Serving:
		return "serving"
	case .Failed:
		return "failed"
	}
	return "off"
}

ws_attach_control :: proc(user: rawptr, value: string) -> Response {
	r := (^Ws_Attach_Runtime)(user)
	switch value {
	case "":
		return success(ws_attach_state_name(r.state))
	case "on":
		if r.state == .Off || r.state == .Failed {
			r.state = .Waiting
			r.attempts, r.retry_delay, r.next_attempt = 0, 0, {}
			bounded_set(&r.cause, "")
		}
	case "off":
		ws_attach_disconnect(r)
		r.state = .Off
	}
	return success()
}

ws_attach_disconnect :: proc(r: ^Ws_Attach_Runtime) {
	if r.manager.layout_batch == ws_layout_batch {r.manager.layout_batch = nil}
	ws_adapter_close(r.ws)
}

ws_attach_tick :: proc(r: ^Ws_Attach_Runtime, now: time.Time) {
	if r.output_open && !output_tail_drain(&r.output, r.output_fd) {
		ws_attach_close_output(r)
	}
	if r.state == .Attaching {
		if ws_attach_receive(r) {return}
		if !r.killed && time.diff(r.child_start, now) > WS_ATTACH_CHILD_LIMIT {
			posix.kill(posix.pid_t(r.child), .SIGKILL)
			r.killed = true
		}
		return
	}
	if r.state != .Waiting || time.diff(now, r.next_attempt) > 0 {return}
	if err := ws_attach_spawn(r, now); err != "" {
		ws_attach_failed_attempt(r, err, false, now)
	}
}

ws_attach_spawn :: proc(r: ^Ws_Attach_Runtime, now: time.Time) -> string {
	if r.ws.state == .Serving {
		r.state = .Serving
		return ""
	}
	if r.rendezvous == 0 {
		if err := ws_attach_register(r); err != "" {return err}
	}
	binary, err := os.get_executable_path(context.temp_allocator)
	if err != nil {return "cannot resolve the shoji executable"}
	binary_c := fmt.ctprintf("%s", binary)
	args := [5]cstring{"/usr/bin/sudo", "-n", binary_c, "--ws-attach", nil}
	pid, output_fd, spawn_err := spawn_with_stderr_pipe(args[:])
	if spawn_err != "" {return spawn_err}
	ws_attach_close_output(r)
	r.output = {}
	r.output_fd, r.output_open = output_fd, output_fd >= 0
	r.child, r.child_start, r.killed = pid, now, false
	r.attempts += 1
	r.state = .Attaching
	return ""
}

// The receive right lives as long as the daemon, so the name is registered once.
ws_attach_register :: proc(r: ^Ws_Attach_Runtime) -> string {
	bootstrap, ok := gate.gate_process_bootstrap_port()
	if !ok {return "no session bootstrap port; run the daemon in the login session"}
	task := gate.gate_mach_task_self()
	port: u32
	if gate.gate_mach_port_allocate(task, gate.MACH_PORT_RIGHT_RECEIVE, &port) != 0 {
		return "cannot allocate the gate rendezvous port"
	}
	if code := gate.gate_bootstrap_register(bootstrap, gate.GATE_RENDEZVOUS_NAME, port); code != 0 {
		gate.gate_mach_port_destroy(task, port)
		return fmt.tprintf("gate rendezvous name is in use (%d)", code)
	}
	r.rendezvous = port
	return ""
}

// Non-blocking: takes a delivered gate right if one is queued.
ws_attach_receive :: proc(r: ^Ws_Attach_Runtime) -> bool {
	if r.rendezvous == 0 {return false}
	message: Ws_Mach_Buffer
	options := u32(gate.MACH_MSG_RECEIVE) | u32(gate.MACH_RCV_TIMEOUT)
	size := u32(len(message.bytes))
	if gate.gate_mach_msg(&message.bytes[0], options, 0, size, r.rendezvous, 0, 0) != 0 {
		return false
	}
	service, ok := gate.gate_handshake_send_right(message.bytes[:])
	if !ok {return false}
	ws_adapter_close(r.ws)
	ws_adapter_connect(r.ws, gate.gate_mach_task_self(), service)
	fmt.eprintln("shoji:", ws_adapter_describe(r.ws))
	if r.ws.state != .Serving {return false}
	r.manager.layout_batch = ws_layout_batch
	r.manager.ws_debug = ws_debug
	r.state = .Serving
	bounded_set(&r.cause, "")
	return true
}

// Pure retry policy, unit-tested.
ws_attach_exit_outcome :: proc(
	exit: Child_Exit,
	connected: bool,
	attempts: u32,
) -> Ws_Attach_Outcome {
	if connected {return .Connected}
	if exit.kind == .Exited && exit.code == WS_ATTACH_EXIT_REFUSED {return .Give_Up}
	if attempts >= WS_ATTACH_ATTEMPTS {return .Give_Up}
	return .Retry
}

// Routes a reaped child; false when `pid` is not the attach child.
ws_attach_child_finished :: proc(
	r: ^Ws_Attach_Runtime,
	pid, status: i32,
	now: time.Time,
) -> bool {
	if r.child == 0 || pid != r.child {return false}
	r.child = 0
	if r.output_open {output_tail_drain(&r.output, r.output_fd)}
	ws_attach_close_output(r)
	exit := child_exit_from_status(status)
	if r.state == .Off {return true}
	connected := r.state == .Serving || ws_attach_receive(r)
	if connected {return true}
	cause := output_tail_last_line(&r.output)
	if cause == "" {cause = child_exit_text(exit)}
	give_up := ws_attach_exit_outcome(exit, false, r.attempts) == .Give_Up
	ws_attach_failed_attempt(r, cause, give_up, now)
	return true
}

ws_attach_failed_attempt :: proc(
	r: ^Ws_Attach_Runtime,
	cause: string,
	give_up: bool,
	now: time.Time,
) {
	bounded_set(&r.cause, cause)
	// The child already prefixes its own message; spawn errors are bare.
	fmt.eprintf("shoji: gate: %s\n", cause)
	if give_up || r.attempts >= WS_ATTACH_ATTEMPTS {
		r.state = .Failed
		r.failed_event = true
		return
	}
	r.retry_delay = min(max(r.retry_delay * 2, WS_ATTACH_RETRY_FIRST), WS_ATTACH_RETRY_MAX)
	r.next_attempt = time.time_add(now, r.retry_delay)
	r.state = .Waiting
}

ws_attach_close_output :: proc(r: ^Ws_Attach_Runtime) {
	if r.output_fd >= 0 {posix.close(posix.FD(r.output_fd))}
	r.output_fd, r.output_open = -1, false
}
