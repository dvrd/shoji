package macos

import e "../engine"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import posix "core:sys/posix"
import "core:time"

foreign import libc "system:c"
@(default_calling_convention = "c")
foreign libc {
	_NSGetEnviron :: proc() -> ^[^]cstring ---
}
stop_requested: i32
stop_handler :: proc "c" (signal: posix.Signal) {
	sync.atomic_store(&stop_requested, 1)
}

run_config :: proc(path: string) -> bool {
	if path == "" {
		return true
	}
	// The path is passed as argv, never interpolated into shell source.
	argv := [3]cstring{"/bin/sh", strings.clone_to_cstring(path, context.temp_allocator), nil}
	pid: posix.pid_t
	if posix.posix_spawn(&pid, "/bin/sh", nil, nil, &argv[0], _NSGetEnviron()^) != nil {
		fmt.eprintf("shoji: cannot execute config %s\n", path)
		return false
	}
	return true
}

startup_config_start :: proc(path: string, reload: ^Addition_Reload, started: ^bool, launch: proc(string) -> bool = run_config) -> bool {
	if started^ {return true}
	if path != "" && reload.payload != "" && !reload.healthy {return true}
	if !launch(path) {return false}
	started^ = true
	return true
}

default_config :: proc() -> string {
	xdg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	home := os.get_env("HOME", context.temp_allocator)
	candidates := [3]string {
		fmt.tprintf("%s/shoji/shojirc", xdg != "" ? xdg : fmt.tprintf("%s/.config", home)),
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
		fmt.eprintln("shoji: no WindowServer connection; run in your desktop login session")
		return 1
	}
	refresh(&state)
	fmt.print(
		"{\"displays\":",
		e.query(&state.manager, []string{"--displays"}).text,
		",\"spaces\":",
		e.query(&state.manager, []string{"--spaces"}).text,
		",\"windows\":",
		e.query(&state.manager, []string{"--windows"}).text,
		"}\n",
	)
	return 0
}

desktop_refresh_tick :: proc(state: ^State, last: ^time.Time, now: time.Time, collect: proc(^State) = refresh) {
	// AXMoved/AXResized arrive for every frame we write. Rediscovering all
	// applications here puts synchronous AX reads between pointer updates.
	// Keep notifications dirty and reconcile once the interactive drag ends.
	if !state.structural_dirty {
		if state.mouse.drag.window != 0 && !state.mouse.failed {return}
		if state.mouse.scroll_tracking {return}
		for s in state.manager.spaces {if s.visible && s.view.layout == .Scroll && (s.view.scroll.motion.active || s.view.scroll.geometry_active || s.view.scroll.dragging) {return}}
		for _, job in state.animations {if animation_is_live(job) {return}}
	}
	if !state.dirty && time.diff(last^, now) < time.Second {return}
	collect(state)
	state.structural_dirty = false
	for s in state.manager.spaces {
		if s.visible {
			if err := e.flush(&state.manager, s); err != "" {fmt.eprintln("shoji:", err)}
		}
	}
	last^ = now
}

run :: proc(config_path: string, payload_path: string = "", validation_pid: i32 = 0) -> int {
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
	socket_name := strings.clone(socket_path())
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
		fmt.eprintln("shoji: no WindowServer connection; run in your desktop login session")
		return 1
	}
	journal_path := fmt.tprintf("/tmp/shoji-animation_%d.json", getuid())
	if validation_pid != 0 {journal_path = fmt.tprintf("/tmp/shoji-validation-animation_%d_%d.json", getuid(), validation_pid)}
	if err := animation_journal_open(&state.animation_journal, journal_path); err != "" {
		fmt.eprintln("shoji:", err); return 1
	}
	refresh(&state)
	state.opening_tracking = true
	config := strings.clone(config_path == "" ? default_config() : config_path)
	defer delete(config)
	if config != "" && !os.exists(config) {
		fmt.eprintf("shoji: config does not exist: %s\n", config)
		return 1
	}
	if validation_pid == 0 {mouse_start(&state)}
	defer mouse_stop(&state)
	if !workspace_start(&state) {fmt.eprintln("shoji: workspace notifications unavailable")}
	defer workspace_stop(&state)
	config_started := false
	if !startup_config_start(config, &reload, &config_started) {return 1}
	if !config_started {fmt.eprintln("shoji: waiting for the Dock payload before executing config")}
	fmt.eprintf("shoji: listening on %s\n", socket_name)
	last_refresh := time.now()
	commands: Command_Server
	defer command_server_stop(&commands)
	for sync.atomic_load(&stop_requested) == 0 {
		scratch: mem.Dynamic_Arena
		mem.dynamic_arena_init(&scratch)
		{
			context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
			CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.016, true)
			action_now := time.now()
			state.manager.scroll_time = time.duration_seconds(time.diff(time.Time{}, action_now))
			e.motion_trace_record(&state.manager.motion_trace, {kind = "loop"})
			workspace_tick(&state)
			addition_reload_tick(&reload, state.workspace_events.dock_pid, time.now())
			if !startup_config_start(config, &reload, &config_started) {return 1}
			animation_recovery_tick(&state, time.now())
			moving := motion_active(&state)
			display := CGMainDisplayID()
			if s := e.space_by_id(&state.manager, state.manager.active_space); s != nil {display = s.display}
			display_clock_prepare(&state.display_clock, display, moving && state.manager.scroll_frame_pacing)
			frame_ready, sample_now, fallback := true, time.now(), false
			if moving && state.manager.scroll_frame_pacing {frame_ready, sample_now, fallback = display_clock_take(&state.display_clock, sample_now)}
			if frame_ready && moving {e.motion_trace_record(&state.manager.motion_trace, {kind = state.manager.scroll_frame_pacing ? "presentation-tick" : "unpaced-tick", value = fallback ? 1 : 0, duration_ms = state.manager.scroll_frame_pacing ? state.display_clock.pacer.period*1000 : 0, source_time = state.manager.scroll_frame_pacing ? state.display_clock.pacer.target : 0})}
			motion_frame_tick(&state, frame_ready, sample_now, CACurrentMediaTime())
			state.manager.scroll_time = time.duration_seconds(time.diff(time.Time{}, time.now()))
			frame_size_feedback_tick(&state, time.now())
			opening_tick(&state)
			feedback_tick(&state)
			desktop_refresh_tick(&state, &last_refresh, time.now())
			ready := Poll_FD {
				fd     = fd,
				events = 1,
			}
			if poll(&ready, 1, 0) > 0 && ready.revents & 1 != 0 {
				client_fd := accept(fd, nil, nil)
				if client_fd >= 0 {
					command_accept(&commands, client_fd)
				}
			}
			command_server_tick(&commands, &state.manager)
			status: i32
			for {
				pid := posix.waitpid(-1, &status, {.NOHANG})
				if pid <= 0 {break}
				addition_reload_finished(&reload, i32(pid), posix.WIFEXITED(status) && posix.WEXITSTATUS(status) == 0, time.now())
			}
		}
		mem.dynamic_arena_destroy(&scratch)
	}
	return 0
}
