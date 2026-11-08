package shoji

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import posix "core:sys/posix"
import "core:time"
import ipc "ipc"

foreign import libc "system:c"

// Daemon lifecycle and event loop
// ------------------------------------------------------------------------

@(default_calling_convention = "c")
foreign libc {
	_NSGetEnviron :: proc() -> ^[^]cstring ---
}
stop_requested: i32
stop_handler :: proc "c" (signal: posix.Signal) {
	sync.atomic_store(&stop_requested, 1)
}

// Runs the startup configuration once. It waits for a verified Dock payload
// so payload-dependent settings apply, but not indefinitely: once recovery is
// reported as failed, the rest of the configuration still applies.
startup_config_start :: proc(
	path: string,
	reload: ^Addition_Reload,
	started: ^bool,
	launch: proc(_: string) -> bool = nil,
	run: ^Config_Run = nil,
) -> bool {
	if started^ {
		return true
	}
	waiting := reload.payload != "" && !reload.healthy && reload.payload_health.state != .Failed
	if path != "" && waiting {
		return true
	}
	launched := launch != nil ? launch(path) : config_run_start(run, path)
	if !launched {
		return false
	}
	started^ = true
	return true
}

// shojirc sets the focus ring's style through the command socket, so it runs
// after the daemon starts. Drawing the ring before it finishes would flash
// the default style. The hold is bounded so a slow or hung configuration,
// or a long Dock payload wait, cannot hide focus feedback indefinitely.
FOCUS_RING_CONFIG_HOLD :: 15 * time.Second

focus_ring_hold_tick :: proc(state: ^State, run: ^Config_Run, start, now: time.Time) {
	if !state.focus_ring_held {
		return
	}
	if !run.report.finished && time.diff(start, now) < FOCUS_RING_CONFIG_HOLD {
		return
	}
	state.focus_ring_held = false
	focus_ring_tick(state)
}

default_config :: proc() -> string {
	xdg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	home := os.get_env("HOME", context.temp_allocator)
	candidates := [3]string {
		fmt.tprintf(
			"%s/shoji/shojirc",
			xdg != "" ? xdg : fmt.tprintf("%s/.config", home),
		),
		fmt.tprintf("%s/.shojirc", home),
		"",
	}
	for path in candidates {
		if path != "" && os.exists(path) {
			return path
		}
	}
	return ""
}

inspect :: proc() -> int {
	if !AXIsProcessTrusted() {
		fmt.eprintln(
			"shoji: Accessibility permission is required to enumerate application windows",
		)
		return 1
	}
	state: State
	state.read_only = true
	state_init(&state)
	defer state_destroy(&state)
	if state.connection == 0 {
		fmt.eprintln(
			"shoji: no WindowServer connection; run in your desktop login session",
		)
		return 1
	}
	refresh(&state)
	fmt.print(
		"{\"displays\":",
		query(&state.manager, []string{"--displays"}).text,
		",\"spaces\":",
		query(&state.manager, []string{"--spaces"}).text,
		",\"windows\":",
		query(&state.manager, []string{"--windows"}).text,
		"}\n",
	)
	return 0
}

desktop_refresh_tick :: proc(
	state: ^State,
	last: ^time.Time,
	now: time.Time,
	collect: proc(_: ^State) = refresh,
) {
	// AXMoved/AXResized arrive for every frame we write. Rediscovering all
	// applications here puts synchronous AX reads between pointer updates.
	// Keep notifications dirty and reconcile once the interactive drag ends.
	if !state.structural_dirty {
		if w := state.manager.windows[state.manager.focused];
		   w != nil && !managed(w) && state.mouse.buttons != 0 {
			return
		}
		if state.mouse.drag.window != 0 && !state.mouse.failed {
			return
		}
		if state.mouse.scroll_tracking {
			return
		}
		for s in state.manager.spaces {
			if s.visible &&
			   s.view.layout == .Scroll &&
			   (s.view.scroll.motion.active ||
					   s.view.scroll.geometry_active ||
					   s.view.scroll.dragging) {
				return
			}
		}
		for _, job in state.animations {
			if animation_is_live(job) {
				return
			}
		}
	}
	if !state.dirty && time.diff(last^, now) < time.Second {
		return
	}
	collect(state)
	state.manager.scroll_time = time.duration_seconds(
		time.diff(time.Time{}, time.now()),
	)
	state.structural_dirty = false
	for s in state.manager.spaces {
		if s.visible {
			if err := flush(&state.manager, s); err != "" {
				fmt.eprintln("shoji:", err)
			}
		}
	}
	last^ = now
}

// Reconcile native changes before selecting command targets, then let this
// iteration's presentation see any new animation jobs immediately.
desktop_commands_tick :: proc(
	server: ^Command_Server,
	state: ^State,
	last: ^time.Time,
	now: time.Time,
	collect: proc(_: ^State) = refresh,
) {
	desktop_refresh_tick(state, last, now, collect)
	close_focus_tick(state, time.now())
	command_server_tick(server, &state.manager)
}

run :: proc(
	config_path: string,
	payload_path: string = "",
	validation_pid: i32 = 0,
) -> int {
	pool := pool_push(); defer pool_pop(pool)
	reload: Addition_Reload
	if err := addition_reload_init(&reload, payload_path); err != "" {
		fmt.eprintln("shoji:", err); return 1
	}
	defer addition_reload_destroy(&reload)
	if geteuid() == 0 {
		fmt.eprintln("shoji: run as your desktop user, not root")
		return 1
	}
	if !AXIsProcessTrusted() {
		fmt.eprintln(
			"shoji: grant Accessibility permission to this executable in System Settings, then restart",
		)
		return 1
	}
	lock_path := fmt.tprintf("/tmp/shoji_%d.lock", getuid())
	lock := posix.open(
		strings.clone_to_cstring(lock_path, context.temp_allocator),
		{.RDWR, .CREAT, .NOFOLLOW, .CLOEXEC},
		{.IRUSR, .IWUSR},
	)
	if lock < 0 {
		fmt.eprintln("shoji: cannot open daemon lock")
		return 1
	}
	defer posix.close(lock)
	if flock(i32(lock), 2 | 4) != 0 {
		fmt.eprintln("shoji: another daemon is already running")
		return 1
	}
	socket_name := strings.clone(ipc.socket_path())
	defer delete(socket_name)
	cpath := strings.clone_to_cstring(socket_name)
	defer delete(cpath)
	addr, ok := address(socket_name)
	if !ok {
		return 1
	}
	fd := socket(1, 1, 0)
	if fd < 0 {
		fmt.eprintln("shoji: cannot create socket")
		return 1
	}
	defer close(fd)
	prepare_socket(fd)
	unlink(cpath)
	if bind(fd, &addr, size_of(addr)) != 0 {
		fmt.eprintln("shoji: cannot bind socket")
		return 1
	}
	defer unlink(cpath)
	if chmod(cpath, 0o600) != 0 || listen(fd, 64) != 0 {
		fmt.eprintln("shoji: cannot listen on socket")
		return 1
	}
	posix.signal(.SIGINT, stop_handler)
	posix.signal(.SIGTERM, stop_handler)
	state: State
	state.validation_pid = validation_pid
	state_init(&state)
	defer state_destroy(&state)
	if state.connection == 0 {
		fmt.eprintln(
			"shoji: no WindowServer connection; run in your desktop login session",
		)
		return 1
	}
	journal_path := fmt.tprintf("/tmp/shoji-animation_%d.json", getuid())
	if validation_pid != 0 {
		journal_path = fmt.tprintf(
			"/tmp/shoji-validation-animation_%d_%d.json",
			getuid(),
			validation_pid,
		)
	}
	if err := animation_journal_open(&state.animation_journal, journal_path);
	   err != "" {
		fmt.eprintln("shoji:", err); return 1
	}
	defer ws_adapter_close(&state.ws)
	attach: Ws_Attach_Runtime
	ws_attach_runtime_start(&attach, &state.ws, &state.manager)
	defer ws_attach_runtime_stop(&attach)
	config := strings.clone(config_path == "" ? default_config() : config_path)
	defer delete(config)
	state.focus_ring_held = config != ""
	ring_hold_start := time.now()
	refresh(&state)
	state.opening_tracking = true
	if validation_pid == 0 {
		snapshot_path := fmt.tprintf("/tmp/shoji-layout_%d.json", getuid())
		layout_snapshot_open(&state.layout_snapshot, strings.clone(snapshot_path), time.now())
	}
	if config != "" && !os.exists(config) {
		fmt.eprintf("shoji: config does not exist: %s\n", config)
		return 1
	}
	if validation_pid == 0 {
		mouse_start(&state)
	}
	defer mouse_stop(&state)
	if !workspace_start(&state) {
		fmt.eprintln("shoji: workspace notifications unavailable")
	}
	defer workspace_stop(&state)
	config_started := false
	runtime_health := Runtime_Health{reload = &reload, attach = &attach}
	defer health_stop(&runtime_health)
	health_start(&runtime_health, &state.manager)
	if !startup_config_start(config, &reload, &config_started, run = &runtime_health.config) {
		return 1
	}
	if !config_started {
		fmt.eprintln(
			"shoji: waiting for the Dock payload before executing config",
		)
	}
	fmt.eprintf("shoji: listening on %s\n", socket_name)
	last_refresh := time.now()
	commands: Command_Server
	defer command_server_stop(&commands)
	if err := command_server_start(&commands, fd); err != "" {
		fmt.eprintln("shoji:", err); return 1
	}
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	for sync.atomic_load(&stop_requested) == 0 {
		defer scratch_reset(&scratch)
		pool := pool_push(); defer pool_pop(pool)
		{
			context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
			CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.016, true)
			action_now := time.now()
			state.manager.scroll_time = time.duration_seconds(
				time.diff(time.Time{}, action_now),
			)
			motion_trace_record(&state.manager.motion_trace, {kind = "loop"})
			workspace_tick(&state)
			addition_reload_tick(
				&reload,
				state.workspace_events.dock_pid,
				time.now(),
			)
			if !startup_config_start(config, &reload, &config_started, run = &runtime_health.config) {
				return 1
			}
			health_tick(&runtime_health, time.now())
			ws_attach_tick(&attach, time.now())
			focus_ring_hold_tick(&state, &runtime_health.config, ring_hold_start, time.now())
			animation_recovery_tick(&state, time.now())
			layout_snapshot_tick(&state, runtime_health.config.report.finished, time.now())
			desktop_commands_tick(&commands, &state, &last_refresh, time.now())
			moving := motion_active(&state)
			display := CGMainDisplayID()
			if s := space_by_id(&state.manager, state.manager.active_space);
			   s != nil {
				display = s.display
			}
			display_clock_prepare(
				&state.display_clock,
				display,
				moving && state.manager.scroll_frame_pacing,
			)
			frame_ready, sample_now, fallback := true, time.now(), false
			if moving && state.manager.scroll_frame_pacing {
				frame_ready, sample_now, fallback = display_clock_take(
					&state.display_clock,
					sample_now,
				)
			}
			if frame_ready && moving {
				motion_trace_record(
					&state.manager.motion_trace,
					{
						kind = state.manager.scroll_frame_pacing \
							? "presentation-tick" \
							: "unpaced-tick",
						value = fallback ? 1 : 0,
						duration_ms = state.manager.scroll_frame_pacing \
							? state.display_clock.pacer.period * 1000 \
							: 0,
						source_time = state.manager.scroll_frame_pacing \
							? state.display_clock.pacer.target \
							: 0,
					},
				)
			}
			motion_frame_tick(
				&state,
				frame_ready,
				sample_now,
				CACurrentMediaTime(),
			)
			state.manager.scroll_time = time.duration_seconds(
				time.diff(time.Time{}, time.now()),
			)
			frame_size_feedback_tick(&state, time.now())
			opening_tick(&state)
			feedback_tick(&state)
			if window, outcome, waited, resolved := ws_focus_tick(&state.ws, time.now()); resolved {
				motion_trace_record(
					&state.manager.motion_trace,
					{
						kind = outcome == .Fired ? "ws-focus-receipt-fired" : "ws-focus-receipt-timeout",
						window = window,
						duration_ms = time.duration_milliseconds(waited),
					},
				)
			}
			status: i32
			for {
				pid := posix.waitpid(-1, &status, {.NOHANG})
				if pid <= 0 {
					break
				}
				if !ws_attach_child_finished(&attach, i32(pid), status, time.now()) {
					health_child_finished(&runtime_health, i32(pid), status, time.now())
				}
			}
		}
	}
	return 0
}
