package shoji

import "base:intrinsics"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import objc "core:sys/darwin/Foundation"
import posix "core:sys/posix"
import "core:time"
import dock "dock"
import health "health"
import ipc "ipc"
import layout "layout"
foreign import screen_cf "system:CoreFoundation.framework"

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
	state.manager.scroll_time = time.duration_seconds(time.diff(time.Time{}, time.now()))
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

// Screen Recording guide
// ------------------------------------------------------------------------

// macOS does not reliably prompt for a locally signed app, so Shoji asks
// itself: an alert that explains the permission and opens the right pane of
// System Settings. Non-blocking; the main loop polls for the answer.
SCREEN_CAPTURE_SETTINGS :: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

@(default_calling_convention = "c")
foreign screen_cf {
	CFUserNotificationCreate :: proc(allocator: Ref, timeout: f64, flags: uint, error: ^i32, dictionary: Ref) -> Ref ---
	CFUserNotificationReceiveResponse :: proc(notification: Ref, timeout: f64, response: ^uint) -> i32 ---
}

screen_capture_alert: Ref

screen_capture_guide :: proc() {
	if CGPreflightScreenCaptureAccess() || screen_capture_alert != nil {
		return
	}
	keys := [4]Ref {
		cf_string("AlertHeader"),
		cf_string("AlertMessage"),
		cf_string("DefaultButtonTitle"),
		cf_string("AlternateButtonTitle"),
	}
	values := [4]Ref {
		cf_string("Shoji needs Screen Recording"),
		cf_string(
			"Window resize animations cross-fade from a snapshot of the window, which needs Screen Recording.\n\nIn System Settings, turn on Shoji under Screen & System Audio Recording, then restart Shoji (shoji service restart).",
		),
		cf_string("Open System Settings"),
		cf_string("Not Now"),
	}
	defer for i in 0 ..< 4 {
		CFRelease(keys[i]); CFRelease(values[i])
	}
	dictionary := CFDictionaryCreate(nil, &keys[0], &values[0], 4, nil, nil)
	if dictionary == nil {
		return
	}
	defer CFRelease(dictionary)
	error: i32
	screen_capture_alert = CFUserNotificationCreate(nil, 0, 0, &error, dictionary)
	if screen_capture_alert == nil {
		fmt.eprintln("shoji: Screen Recording is off; content fades are disabled")
	}
}

// 0 is the default button (Open System Settings), 1 the alternate (Not Now).
screen_capture_guide_tick :: proc() {
	if screen_capture_alert == nil {
		return
	}
	response: uint
	if CFUserNotificationReceiveResponse(screen_capture_alert, 0, &response) != 0 {
		return
	}
	CFRelease(screen_capture_alert)
	screen_capture_alert = nil
	if response & 3 != 0 {
		return
	}
	argv := [3]cstring{"/usr/bin/open", SCREEN_CAPTURE_SETTINGS, nil}
	environment := [1]cstring{nil}
	pid: posix.pid_t
	if posix.posix_spawn(&pid, "/usr/bin/open", nil, nil, &argv[0], &environment[0]) != .NONE {
		fmt.eprintln("shoji: could not open System Settings")
		return
	}
	status: i32
	_ = posix.waitpid(pid, &status, {})
}

run :: proc(config_path: string, payload_path: string = "", validation_pid: i32 = 0) -> int {
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
		fmt.eprintln("shoji: no WindowServer connection; run in your desktop login session")
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
	if err := animation_journal_open(&state.animation_journal, journal_path); err != "" {
		fmt.eprintln("shoji:", err); return 1
	}
	conceal_path := dock.conceal_journal_path(getuid())
	if validation_pid != 0 {
		conceal_path = fmt.tprintf(
			"/tmp/shoji-validation-concealed_%d_%d.json",
			getuid(),
			validation_pid,
		)
	}
	state.manager.conceal_journal = strings.clone(conceal_path)
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
	runtime_health := Runtime_Health {
		reload = &reload,
		attach = &attach,
	}
	defer health_stop(&runtime_health)
	health_start(&runtime_health, &state.manager)
	if !startup_config_start(config, &reload, &config_started, run = &runtime_health.config) {
		return 1
	}
	if !config_started {
		fmt.eprintln("shoji: waiting for the Dock payload before executing config")
	}
	fmt.eprintf("shoji: listening on %s\n", socket_name)
	if validation_pid == 0 && state.manager.resize_fade {
		screen_capture_guide()
	}
	last_refresh := time.now()
	commands: Command_Server
	defer command_server_stop(&commands)
	if err := command_server_start(&commands, fd); err != "" {
		fmt.eprintln("shoji:", err); return 1
	}
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	loop_body_began: time.Tick
	for sync.atomic_load(&stop_requested) == 0 {
		defer scratch_reset(&scratch)
		pool := pool_push(); defer pool_pop(pool)
		{
			context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
			// A stalled iteration is either its own work or the run loop
			// (Accessibility callbacks, timers). Record only the slow ones.
			wait_began := time.tick_now()
			if body := time.duration_milliseconds(time.tick_diff(loop_body_began, wait_began)); body > 25 && loop_body_began != {} {
				motion_trace_record(&state.manager.motion_trace, {kind = "stall-body", duration_ms = body})
			}
			CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.016, true)
			if wait := time.duration_milliseconds(time.tick_since(wait_began)); wait > 25 {
				motion_trace_record(&state.manager.motion_trace, {kind = "stall-runloop", duration_ms = wait})
			}
			loop_body_began = time.tick_now()
			action_now := time.now()
			state.manager.scroll_time = time.duration_seconds(time.diff(time.Time{}, action_now))
			motion_trace_record(&state.manager.motion_trace, {kind = "loop"})
			workspace_tick(&state)
			addition_reload_tick(&reload, state.workspace_events.dock_pid, time.now())
			if !startup_config_start(
				config,
				&reload,
				&config_started,
				run = &runtime_health.config,
			) {
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
			if s := space_by_id(&state.manager, state.manager.active_space); s != nil {
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
			motion_frame_tick(&state, frame_ready, sample_now, CACurrentMediaTime())
			if frame_ready && moving && state.manager.scroll_frame_pacing && !fallback {
				target := state.display_clock.pacer.target
				motion_trace_record(
					&state.manager.motion_trace,
					{
						kind = "frame-latency",
						duration_ms = frame_present_latency_ms(CACurrentMediaTime(), target),
						source_time = target,
					},
				)
			}
			state.manager.scroll_time = time.duration_seconds(time.diff(time.Time{}, time.now()))
			frame_size_feedback_tick(&state, time.now())
			resize_transform_tick(&state)
			screen_capture_guide_tick()
			opening_tick(&state)
			feedback_tick(&state)
			if window, outcome, waited, resolved := ws_focus_tick(&state.ws, time.now());
			   resolved {
				motion_trace_record(
					&state.manager.motion_trace,
					{
						kind = outcome == .Fired \
							? "ws-focus-receipt-fired" \
							: "ws-focus-receipt-timeout",
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

// Daemon health owner: connects the Dock payload reloader, the startup
// configuration run and notifications, and answers `query --health`.


Runtime_Health :: struct {
	reload:   ^Addition_Reload,
	config:   Config_Run,
	notifier: Notifier,
	attach:   ^Ws_Attach_Runtime, // nil outside the daemon
}

health_start :: proc(h: ^Runtime_Health, m: ^Manager) {
	assert(h.reload != nil)
	notifier_start(&h.notifier)
	m.health_report = health_report
	m.health_notify_test = health_notify_test
	m.health_user = h
}

health_stop :: proc(h: ^Runtime_Health) {
	config_run_stop(&h.config)
	notifier_stop(&h.notifier)
}

health_tick :: proc(h: ^Runtime_Health, now: time.Time) {
	config_run_drain(&h.config)
	notify_payload_transition(&h.notifier, h.reload, now)
	notify_config_failures(&h.notifier, &h.config, now)
	if h.attach != nil && h.attach.failed_event {
		h.attach.failed_event = false
		cause := health.bounded_get(&h.attach.cause)
		notify(&h.notifier, "Shoji: WindowServer gate unavailable", cause, now)
	}
}

// Routes a reaped child to its owner by process ID.
health_child_finished :: proc(h: ^Runtime_Health, pid, status: i32, now: time.Time) {
	exit := health.child_exit_from_status(status)
	if addition_reload_finished(h.reload, pid, exit, now) {
		notify_payload_transition(&h.notifier, h.reload, now)
		return
	}
	if config_run_finished(&h.config, pid, exit) {
		notify_config_failures(&h.notifier, &h.config, now)
	}
}

health_report :: proc(user: rawptr) -> string {
	h := (^Runtime_Health)(user)
	r := h.reload
	report := &h.config.report
	failures := make([]health.Health_Config_Failure_JSON, report.count, context.temp_allocator)
	for i in 0 ..< report.count {
		f := &report.failures[i]
		failures[i] = {f.line, health.bounded_get(&f.command), health.bounded_get(&f.error)}
	}
	value := health.Health_JSON {
		payload                  = health_payload_state_name(r),
		payload_enabled          = r.payload != "",
		payload_failures         = r.payload_health.failures,
		payload_cause            = health.bounded_get(&r.payload_health.cause),
		crash_report             = health.bounded_get(&r.payload_health.crash_report),
		config_finished          = report.finished,
		config_exit              = report.finished ? health.child_exit_text(report.exit) : "",
		config_failures          = failures,
		config_failures_dropped  = report.dropped,
		notifications            = health_notifier_name(&h.notifier),
		notifications_suppressed = h.notifier.suppressed,
		gate                     = "off",
	}
	if h.attach != nil {
		value.gate = ws_attach_state_name(h.attach.state)
		value.gate_cause = health.bounded_get(&h.attach.cause)
	}
	data, err := json.marshal(value, {pretty = true}, context.temp_allocator)
	if err != nil {
		return "{}"
	}
	return string(data)
}

health_payload_state_name :: proc(r: ^Addition_Reload) -> string {
	if r.payload == "" {
		return "disabled"
	}
	switch r.payload_health.state {
	case .Starting:
		return "starting"
	case .Ready:
		return "ready"
	case .Recovering:
		return "recovering"
	case .Failed:
		return "failed"
	}
	return "unknown"
}

health_notifier_name :: proc(n: ^Notifier) -> string {
	if !n.available {
		return "unavailable"
	}
	switch n.authorization {
	case .Unknown:
		return "pending"
	case .Granted:
		return "allowed"
	case .Denied:
		return "denied"
	}
	return "unknown"
}

// Posts a visible test notification. The time keeps repeated tests from being
// deduplicated; the rate limit still applies and is reported.
health_notify_test :: proc(user: rawptr) -> Response {
	n := &(^Runtime_Health)(user).notifier
	switch health_notifier_name(n) {
	case "unavailable":
		return failure("notifications unavailable: run Shoji from Shoji.app")
	case "denied":
		return failure("notifications denied: allow Shoji in System Settings > Notifications")
	}
	now := time.now()
	hour, minute, second := time.clock_from_time(now)
	body := fmt.tprintf("Notifications work (%02d:%02d:%02d).", hour, minute, second)
	suppressed := n.suppressed
	notify(n, "Shoji: test", body, now)
	if n.suppressed != suppressed {
		return failure("not posted: rate limit reached (5 per 10 minutes)")
	}
	if health_notifier_name(n) == "pending" {
		return success("posted; permission still pending, answer the macOS prompt\n")
	}
	return success("posted test notification\n")
}

// Desktop refresh
// ------------------------------------------------------------------------

application_create :: proc(
	state: ^State,
	running: ^objc.Object,
	pid: i32,
	policy: int,
) -> Application {
	app: Application
	app.policy = policy
	app.element = AXUIElementCreateApplication(pid)
	// Accessory helpers must not hold up the desktop event loop.
	AXUIElementSetMessagingTimeout(app.element, policy == 1 ? 0.025 : 0.25)
	app.name = strings.clone(
		objc_text(intrinsics.objc_send(^objc.Object, running, "localizedName")),
	)
	if AXObserverCreate(pid, observer_callback, &app.observer) == 0 {
		for name in ([]string {
				"AXWindowCreated",
				"AXCreated",
				"AXFocusedWindowChanged",
				"AXApplicationActivated",
				"AXApplicationDeactivated",
				"AXApplicationHidden",
				"AXApplicationShown",
			}) {
			observe(state, app.observer, app.element, name)
		}
		CFRunLoopAddSource(
			CFRunLoopGetMain(),
			AXObserverGetRunLoopSource(app.observer),
			kCFRunLoopDefaultMode,
		)
	}
	return app
}

application_destroy :: proc(app: Application) {
	if app.observer != nil {
		CFRunLoopRemoveSource(
			CFRunLoopGetMain(),
			AXObserverGetRunLoopSource(app.observer),
			kCFRunLoopDefaultMode,
		)
		CFRelease(app.observer)
	}
	CFRelease(app.element)
	delete(app.name)
}

refresh :: proc(state: ^State) {
	state.opening_collecting = true
	defer {state.opening_collecting = false}
	defer {
		if !state.read_only && state.manager.shadow_configured {
			if err := apply_window_shadows(&state.manager); err != "" {
				fmt.eprintln("shoji: shadow:", err)
			}
		}
	}
	pool := pool_push()
	defer pool_pop(pool)
	refresh_displays(state)
	m := &state.manager
	apps := intrinsics.objc_send(^objc.Object, workspace(), "runningApplications")
	frontmost := intrinsics.objc_send(^objc.Object, workspace(), "frontmostApplication")
	frontmost_pid := intrinsics.objc_send(i32, frontmost, "processIdentifier")
	accessory_owners, owners_known := accessory_window_owners()
	seen := make(map[u32]bool, context.temp_allocator)
	seen_apps := make(map[i32]bool, context.temp_allocator)
	for i in 0 ..< intrinsics.objc_send(uint, apps, "count") {
		running := intrinsics.objc_send(^objc.Object, apps, "objectAtIndex:", i)
		pid := intrinsics.objc_send(i32, running, "processIdentifier")
		if pid == getpid() {
			continue
		}
		policy := intrinsics.objc_send(int, running, "activationPolicy")
		if !observe_application(state, pid, policy) {
			continue
		}
		seen_apps[pid] = true
		app, exists := state.applications[pid]
		if !poll_application_windows(pid, policy, frontmost_pid, accessory_owners, owners_known) {
			// Keep existing references for off-screen panels. The WindowServer
			// retention pass below detects disappearance without synchronous AX reads.
			if exists {
				app.hidden = intrinsics.objc_send(bool, running, "isHidden")
				state.applications[pid] = app
			}
			continue
		}
		if !exists {
			app = application_create(state, running, pid, policy)
		}
		hidden := intrinsics.objc_send(bool, running, "isHidden")
		app.hidden = hidden
		app.policy = policy
		state.applications[pid] = app
		list := attribute(app.element, "AXWindows")
		if list == nil {
			// A temporarily unresponsive application is not evidence its windows were destroyed.
			for id, w in m.windows {
				if w.pid == pid {
					w.hidden = hidden
					seen[id] = true
				}
			}
			continue
		}
		for j in 0 ..< CFArrayGetCount(list) {
			element := CFArrayGetValueAtIndex(list, j)
			id: u32
			if _AXUIElementGetWindow(element, &id) != 0 || id == 0 {
				continue
			}
			seen[id] = true
			observation := collect_window(state, app, element, id, pid, policy, hidden)
			new_window := state.manager.windows[id] == nil
			w := opening_observe(state, app, element, observation)
			// Rules run after the observed state is complete. Initial rules are
			// still applied by add_window before insertion into a layout.
			if !state.read_only && !new_window && w.rules_pending {
				refresh_window_rules(m, w)
			}
		}
		CFRelease(list)
	}
	retain_unlisted_windows(state, &seen, seen_apps)
	gone := make([dynamic]u32, 0, 8, context.temp_allocator)
	for id in m.windows {
		if !seen[id] {
			append(&gone, id)
		}
	}
	for id in gone {
		app := state.applications[m.windows[id].pid]
		window_reference_remove(state, id, app.observer)
		remove_observed_window(state, id)
	}
	terminated := make([dynamic]i32, 0, 8, context.temp_allocator)
	for pid in state.applications {
		if !seen_apps[pid] {
			append(&terminated, pid)
		}
	}
	for pid in terminated {
		app := state.applications[pid]
		application_destroy(app)
		delete_key(&state.applications, pid)
	}
	refresh_effects(state)
	observe_changes(state)
	state.dirty = false
	state.opening_collecting = false
	opening_tick(state)
}

Close_Focus_Recovery :: struct {
	space:                  u64,
	deadline, next_attempt: time.Time,
}

remove_observed_window :: proc(state: ^State, id: u32) {
	m := &state.manager
	if w := m.windows[id]; w != nil && m.focused == id && !state.read_only {
		if s := space_by_id(m, w.space); s != nil && s.visible && s.view.layout == .Scroll {
			now := time.now()
			state.close_focus = {
				space        = s.id,
				deadline     = time.time_add(now, 2 * time.Second),
				next_attempt = time.time_add(now, 50 * time.Millisecond),
			}
		}
	}
	remove_window(&state.manager, id)
}

close_focus_candidate :: proc(m: ^Manager, s: ^Space) -> u32 {
	v := &s.view; viewport := v.scroll.viewport
	best: u32; best_area: f64; best_preferred: bool
	for n := layout.first(v.root); n != nil; n = layout.next(n) {
		for i in 0 ..< n.count {
			id := n.windows[i]; w := m.windows[id]
			if w == nil ||
			   !layout_admitted(w) ||
			   w.space != s.id ||
			   (n.column_tabbed && id != n.order[0]) {
				continue
			}
			r := layout.scroll_window_frame(v, n, id, false)
			width := min(r.x + r.w, viewport.x + viewport.w) - max(r.x, viewport.x)
			height := min(r.y + r.h, viewport.y + viewport.h) - max(r.y, viewport.y)
			if width <= 0 || height <= 0 {
				continue
			}
			area := width * height; preferred := id == v.scroll.focused
			if best == 0 ||
			   (preferred && !best_preferred) ||
			   (preferred == best_preferred && area > best_area) {
				best, best_area, best_preferred = id, area, preferred
			}
		}
	}
	return best
}

close_focus_tick :: proc(state: ^State, now: time.Time = {}) {
	p := &state.close_focus; m := &state.manager
	if p.space == 0 {
		return
	}
	now := now
	if (now == time.Time{}) {
		now = time.now()
	}
	// Let native focus settle first. A later focus or Space change wins over
	// this fallback, including when several windows disappear in one refresh.
	if state.read_only ||
	   m.active_space != p.space ||
	   m.windows[m.focused] != nil ||
	   time.diff(now, p.deadline) <= 0 {
		p^ = {}; return
	}
	if m.suspended ||
	   m.gesture_active ||
	   state.mouse.drag.window != 0 ||
	   time.diff(now, p.next_attempt) > 0 {
		return
	}
	s := space_by_id(m, p.space)
	if s == nil || !s.visible || s.view.layout != .Scroll {
		p^ = {}; return
	}
	target := close_focus_candidate(m, s)
	if target == 0 {
		return
	}
	p.next_attempt = time.time_add(now, 100 * time.Millisecond)
	response := execute(m, {"window", fmt.tprintf("%d", target), "--focus"})
	if response.failed {
		state.dirty = true; return
	}
	motion_trace_record(
		&m.motion_trace,
		{kind = "close-focus-recovered", window = target, space = s.id},
	)
	p^ = {}
}

focus_owner :: proc(m: ^Manager, pid: i32, ancestry: []u32) -> u32 {
	id := len(ancestry) > 0 ? ancestry[0] : 0
	for candidate in ancestry {
		if w := m.windows[candidate]; w != nil && w.pid == pid {
			id = candidate
		}
	}
	return id
}

native_focus_owner :: proc(state: ^State, pid: i32, focused: Ref) -> u32 {
	// Sheets can own keyboard focus without appearing in AXWindows. Follow
	// their parent chain to the tracked document that owns the layout slot.
	ids: [16]u32; count := 0
	element := focused; owned := false
	defer {
		if owned && element != nil {
			CFRelease(element)
		}
	}
	for _ in 0 ..< len(ids) {
		if element == nil {
			break
		}
		id: u32
		if _AXUIElementGetWindow(element, &id) == 0 && id != 0 {
			ids[count] = id; count += 1
		}
		parent := attribute(element, "AXParent")
		if owned {
			CFRelease(element)
		}
		element, owned = parent, true
	}
	return focus_owner(&state.manager, pid, ids[:count])
}

// Show a newly discovered focus before the remaining refresh work can block.
refresh_set_focus :: proc(state: ^State, id: u32) {
	changed := state.manager.focused != id
	focus_window(&state.manager, id)
	if changed && !state.read_only {
		focus_ring_tick(state)
	}
}

refresh_effects :: proc(state: ^State) {
	m := &state.manager
	if !state.read_only {
		if err := reconcile_window_memberships(m); err != "" {
			fmt.eprintln("shoji:", err)
		}
	}
	front := intrinsics.objc_send(^objc.Object, workspace(), "frontmostApplication")
	pid := intrinsics.objc_send(i32, front, "processIdentifier")
	if app, ok := state.applications[pid]; ok {
		focused := attribute(app.element, "AXFocusedWindow")
		if focused != nil {
			id := native_focus_owner(state, pid, focused)
			CFRelease(focused)
			if w := m.windows[id];
			   w != nil &&
			   (w.opening.phase == .Pending || w.opening.phase == .Opening) &&
			   w.opening.focus_superseded {
				if replacement := m.windows[w.opening.focus_replacement]; replacement != nil {
					if perform(m, {kind = .Focus_Without_Raise, window = replacement.id}) == "" {
						id = replacement.id
					}
				}
			}
			refresh_set_focus(state, id)
		}
	}
	if !state.read_only && m.window_opacity {
		if err := apply_window_opacity(m); err != "" {
			fmt.eprintln("shoji: opacity:", err)
		}
	}
	if !state.read_only {
		if _, err := addition_check(); err == "" {
			if err := apply_window_layers(m); err != "" {
				fmt.eprintln("shoji: layer:", err)
			}
		}
		mouse_follow_focus(state)
	}
}

// Startup configuration process
// ------------------------------------------------------------------------
// shojirc runs as 'sh -x' with a line-numbered PS4 so a failing command can
// be reported with its line. Trace lines are parsed, never logged; error
// output is forwarded to the daemon log and recorded in a bounded report.
// The daemon keeps running when configuration fails.


Config_Run :: struct {
	pid:         i32,
	output_fd:   i32,
	output_open: bool,
	report:      health.Config_Report,
	notified:    int, // Failures already handed to the notifier.
}

// Launches path; returns false only when the shell cannot be started.
config_run_start :: proc(run: ^Config_Run, path: string) -> bool {
	assert(run.pid == 0 && !run.output_open)
	if path == "" {
		return true
	}
	// The path is passed as argv, never interpolated into shell source.
	argv := [6]cstring {
		"/usr/bin/env",
		"PS4=" + health.CONFIG_TRACE_PREFIX + "${LINENO}: ",
		"/bin/sh",
		"-x",
		strings.clone_to_cstring(path, context.temp_allocator),
		nil,
	}
	pid, output_fd, err := spawn_with_stderr_pipe(argv[:])
	if err != "" {
		fmt.eprintf("shoji: cannot execute config %s: %s\n", path, err)
		return false
	}
	run^ = {}
	run.pid = pid
	run.output_fd = output_fd
	run.output_open = output_fd >= 0
	return true
}

// Moves available output into the report. Returns recorded failures.
config_run_drain :: proc(run: ^Config_Run) -> int {
	if !run.output_open {
		return 0
	}
	before := run.report.count + run.report.dropped
	chunk: [512]u8
	for _ in 0 ..< 64 {
		n := posix.read(posix.FD(run.output_fd), &chunk[0], len(chunk))
		if n > 0 {
			health.config_report_feed(&run.report, chunk[:n])
			continue
		}
		if n < 0 && (posix.errno() == .EAGAIN || posix.errno() == .EINTR) {
			break
		}
		posix.close(posix.FD(run.output_fd))
		run.output_open = false
		break
	}
	recorded := run.report.count + run.report.dropped - before
	for i in run.report.count - min(recorded, run.report.count) ..< run.report.count {
		fmt.eprintln("shoji:", health.config_failure_text(&run.report.failures[i]))
	}
	return recorded
}

// Handles the shell's exit. Returns false when child is not this run.
config_run_finished :: proc(run: ^Config_Run, child: i32, exit: health.Child_Exit) -> bool {
	if child == 0 || child != run.pid {
		return false
	}
	config_run_drain(run)
	if run.output_open {
		posix.close(posix.FD(run.output_fd))
		run.output_open = false
	}
	if run.report.pending.count > 0 {
		health.config_report_line(&run.report, health.bounded_get(&run.report.pending))
		health.bounded_set(&run.report.pending, "")
	}
	run.pid = 0
	run.report.exit = exit
	run.report.finished = true
	if !health.child_exit_ok(exit) && run.report.count == 0 && run.report.dropped == 0 {
		// The shell failed without an attributable error line.
		failure := &run.report.failures[0]
		failure.line = run.report.last_line
		health.bounded_set(&failure.command, health.bounded_get(&run.report.last_command))
		health.bounded_set(
			&failure.error,
			fmt.tprintf("configuration %s", health.child_exit_text(exit)),
		)
		run.report.count = 1
		fmt.eprintln("shoji:", health.config_failure_text(failure))
	}
	return true
}

config_run_stop :: proc(run: ^Config_Run) {
	if run.output_open {
		posix.close(posix.FD(run.output_fd))
	}
	run.output_open = false
}

foreign import display_quartz "system:QuartzCore.framework"
foreign import frame_updates_sls "system:SkyLight.framework"

// Display clock and frame pacing
// ------------------------------------------------------------------------

// All callbacks and consumers run on the main run loop. One replaceable pulse
// avoids queuing obsolete animation work when a client blocks the daemon.
Frame_Pacer :: struct {
	pending:                                           bool,
	target, last_callback, last_take, consumed_target: f64,
	period:                                            f64,
	superseded:                                        u64,
}
frame_pacer_pulse :: proc(p: ^Frame_Pacer, target, now, period: f64) {
	if math.is_nan(target) || math.is_inf(target) || target < now - 0.1 || target > now + 0.1 {
		return
	}
	if target <= p.consumed_target {
		return
	}
	if p.pending {
		p.superseded += 1
	}
	p.pending, p.target, p.last_callback = true, target, now
	if period > 0 && period <= .1 {
		p.period = period
	}
}
frame_pacer_take :: proc(
	p: ^Frame_Pacer,
	now: f64,
	linked: bool,
) -> (
	ready: bool,
	target: f64,
	fallback: bool,
) {
	if linked && p.pending {
		p.pending = false
		p.last_take, p.consumed_target = now, p.target
		return true, max(now, p.target), false
	}
	// A missing/paused display must not strand windows. Throttle fallback too.
	if (!linked || now - p.last_callback >= 0.1) && now - p.last_take >= 1.0 / 60 {
		p.last_take = now
		return true, now, true
	}
	return false, now, false
}

// Milliseconds from `commit` to `present`. Negative means the sample is after
// the display-link target. A non-finite input is 0.
frame_present_latency_ms :: proc(commit, present: f64) -> f64 {
	if math.is_nan(commit) || math.is_nan(present) || math.is_inf(commit) || math.is_inf(present) {
		return 0
	}
	return (present - commit) * 1000
}

Display_Clock :: struct {
	listener, link: ^objc.Object,
	display:        u32,
	running:        bool,
	retry_at:       f64,
	pacer:          Frame_Pacer,
}
foreign display_quartz {CACurrentMediaTime :: proc "c" () -> f64 ---}
display_listener_class: objc.Class
display_listeners: map[rawptr]^Display_Clock

display_clock_callback :: proc "c" (object: ^objc.Object, _: objc.SEL, sender: ^objc.Object) {
	context = runtime.default_context()
	clock := display_listeners[rawptr(object)]
	if clock == nil || !clock.running {
		return
	}
	frame_pacer_pulse(
		&clock.pacer,
		intrinsics.objc_send(f64, sender, "targetTimestamp"),
		CACurrentMediaTime(),
		intrinsics.objc_send(f64, sender, "duration"),
	)
}
display_clock_stop :: proc(clock: ^Display_Clock) {
	if clock.link != nil {
		intrinsics.objc_send(nil, clock.link, "invalidate")
		intrinsics.objc_send(nil, clock.link, "release")
	}
	if clock.listener != nil {
		delete_key(&display_listeners, rawptr(clock.listener))
		intrinsics.objc_send(nil, clock.listener, "release")
	}
	clock^ = {}
	if len(display_listeners) == 0 {
		delete(display_listeners); display_listeners = nil
	}
}
// An unsuccessful creation records a retry deadline, not permanent success.
display_clock_should_create :: proc(clock: ^Display_Clock, display: u32, now: f64) -> bool {
	if clock.link != nil {
		return false
	}
	if clock.display != display {
		clock.display = display; clock.retry_at = 0
	}
	if now < clock.retry_at {
		return false
	}
	clock.retry_at = now + .5
	return true
}
display_clock_prepare :: proc(clock: ^Display_Clock, display: u32, moving: bool, now: f64 = 0) {
	now := now
	if now == 0 {
		now = CACurrentMediaTime()
	}
	if clock.display != display {
		display_clock_stop(clock)
	}
	if !moving {
		if clock.link != nil && clock.running {
			intrinsics.objc_send(nil, clock.link, "setPaused:", bool(true))
		}
		clock.running = false; clock.pacer.pending = false
		return
	}
	if display_clock_should_create(clock, display, now) {
		created := false
		defer {
			if !created {
				retry, pacer := clock.retry_at, clock.pacer
				display_clock_stop(clock)
				clock.display, clock.retry_at = display, retry
				clock.pacer = pacer
			}
		}
		if display_listener_class == nil {
			display_listener_class = objc.objc_allocateClassPair(
				objc.objc_lookUpClass("NSObject"),
				"ShojiDisplayClock",
				0,
			)
			if display_listener_class == nil {
				return
			}
			if !objc.class_addMethod(
				display_listener_class,
				objc.sel_registerName("frame:"),
				cast(objc.IMP)display_clock_callback,
				"v@:@",
			) {
				objc.objc_disposeClassPair(display_listener_class)
				display_listener_class = nil
				return
			}
			objc.objc_registerClassPair(display_listener_class)
		}
		screens := intrinsics.objc_send(
			^objc.Object,
			(^objc.Object)(objc.objc_lookUpClass("NSScreen")),
			"screens",
		)
		count := intrinsics.objc_send(int, screens, "count")
		screen: ^objc.Object
		for i in 0 ..< count {
			candidate := intrinsics.objc_send(^objc.Object, screens, "objectAtIndex:", i)
			description := intrinsics.objc_send(^objc.Object, candidate, "deviceDescription")
			key := cf_string("NSScreenNumber")
			number := intrinsics.objc_send(
				^objc.Object,
				description,
				"objectForKey:",
				(^objc.Object)(key),
			); CFRelease(key)
			if intrinsics.objc_send(u32, number, "unsignedIntValue") == display {
				screen = candidate; break
			}
		}
		if screen == nil ||
		   !intrinsics.objc_send(
				   bool,
				   screen,
				   "respondsToSelector:",
				   objc.sel_registerName("displayLinkWithTarget:selector:"),
			   ) {
			return
		}
		clock.listener = intrinsics.objc_send(
			^objc.Object,
			(^objc.Object)(display_listener_class),
			"new",
		)
		if clock.listener == nil {
			return
		}
		if display_listeners == nil {
			display_listeners = make(map[rawptr]^Display_Clock)
		}
		display_listeners[rawptr(clock.listener)] = clock
		clock.link = intrinsics.objc_send(
			^objc.Object,
			screen,
			"displayLinkWithTarget:selector:",
			clock.listener,
			objc.sel_registerName("frame:"),
		)
		if clock.link == nil {
			return
		}
		intrinsics.objc_send(nil, clock.link, "retain")
		intrinsics.objc_send(
			nil,
			clock.link,
			"addToRunLoop:forMode:",
			objc.RunLoop_mainRunLoop(),
			objc.RunLoopCommonModes,
		)
		created = true
	}
	if clock.link != nil && !clock.running {
		clock.running = true
		clock.pacer.last_callback = CACurrentMediaTime()
		intrinsics.objc_send(nil, clock.link, "setPaused:", bool(false))
	}
}
// Convert only the short relative prediction; CA uptime and wall time are
// different epochs. Action processing keeps its actual-time clock separately.
display_clock_take :: proc(clock: ^Display_Clock, now: time.Time) -> (bool, time.Time, bool) {
	ready, target, fallback := frame_pacer_take(
		&clock.pacer,
		CACurrentMediaTime(),
		clock.link != nil && clock.running,
	)
	lead := clamp(target - CACurrentMediaTime(), 0, .05)
	return ready, time.time_add(now, time.Duration(lead * f64(time.Second))), fallback
}

// Nested presentation batches
// ------------------------------------------------------------------------

Frame_Updates :: struct {
	depth:       int,
	user:        rawptr,
	set_enabled: proc(user: rawptr, connection: i32, enabled: bool) -> i32,
}

foreign frame_updates_sls {
	SLSDisableUpdate :: proc "c" (connection: i32) -> i32 ---
	SLSReenableUpdate :: proc "c" (connection: i32) -> i32 ---
}

frame_updates_set :: proc(state: ^State, enabled: bool) -> i32 {
	if state.frame_updates.set_enabled != nil {
		return state.frame_updates.set_enabled(state.frame_updates.user, state.connection, enabled)
	}
	if state.connection == 0 {
		return 0
	}
	return enabled ? SLSReenableUpdate(state.connection) : SLSDisableUpdate(state.connection)
}

frame_updates_begin :: proc(state: ^State) -> string {
	if state.frame_updates.depth == 0 {
		if code := frame_updates_set(state, false); code != 0 {
			return fmt.tprintf("could not begin frame presentation batch (%d)", code)
		}
	}
	state.frame_updates.depth += 1
	return ""
}

frame_updates_end :: proc(state: ^State) -> string {
	if state.frame_updates.depth <= 0 {
		return "unbalanced frame presentation batch"
	}
	state.frame_updates.depth -= 1
	if state.frame_updates.depth == 0 {
		if code := frame_updates_set(state, true); code != 0 {
			return fmt.tprintf("could not present frame batch (%d)", code)
		}
	}
	return ""
}

// Coordinated motion ticks
// ------------------------------------------------------------------------

motion_active :: proc(state: ^State) -> bool {
	if len(state.animations) > 0 ||
	   len(state.resize_covers) > 0 ||
	   state.mouse.scroll_tracking ||
	   stack_touch_has_pending() ||
	   state.mouse.drag.window != 0 {
		return true
	}
	for s in state.manager.spaces {
		if s.visible &&
		   s.view.layout == .Scroll &&
		   (s.view.scroll.dragging ||
				   s.view.scroll.motion.active ||
				   s.view.scroll.geometry_active) {
			return true
		}
	}
	return false
}

// One display pulse, one fixed sample time and one presentation batch for
// native geometry and its content covers. Nested AX/scroll batches stay inside
// this boundary; no overlay is presented ahead of its corresponding frame.
motion_frame_tick :: proc(state: ^State, ready: bool, sample_now: time.Time, uptime: f64) {
	if !ready {
		mouse_tick(state, false, sample_now)
		if !state.manager.resize_fade || state.resize_cover_cancel {
			resize_cover_tick(state, uptime)
		}
		focus_ring_tick(state)
		return
	}
	active := motion_active(state)
	if active {
		if err := frame_updates_begin(state); err != "" {
			fmt.eprintln("shoji: motion:", err); return
		}
	}
	defer {
		if active {
			if err := frame_updates_end(state); err != "" {
				fmt.eprintln("shoji: motion:", err)
			}
		}
	}
	// Registered after the update-end defer, so the submit runs first and
	// still inside the disabled section. The hold stays off unless a batch
	// exists, which keeps tests and unbatched flushes on the immediate path.
	hold := active && state.manager.layout_batch != nil
	state.manager.camera_hold = hold
	state.frame_owned_count = 0
	defer {
		if hold {
			owned := state.frame_owned[:state.frame_owned_count]
			if !layout_frame_submit(&state.manager, owned) {
				feedback_owned_fallback(state)
			}
		}
		state.manager.camera_hold = false
		state.frame_owned_count = 0
	}
	state.manager.scroll_time = time.duration_seconds(time.diff(time.Time{}, sample_now))
	animation_tick(state, sample_now)
	mouse_tick(state, true, sample_now)
	scroll_native_tick(state, sample_now)
	resize_cover_tick(state, uptime)
	focus_ring_tick(state)
}

// The owner serializes access. The coordinator stores no native references and
// cannot cancel an AX call already in progress; callers must reconcile its
// completion against the generation returned by motion_complete.
Motion_Target :: struct {
	window:     u32,
	space:      u64,
	generation: u64,
}
Motion_Request_Kind :: enum {
	Position,
	Focus,
}
Motion_Request :: struct {
	kind:     Motion_Request_Kind,
	target:   Motion_Target,
	frame:    Rect,
	revision: u64,
}
Motion_Entry :: struct {
	target:   Motion_Target,
	frame:    Rect,
	revision: u64,
	pending:  bool,
}
Motion_Coordinator :: struct {
	entries:                            map[u32]Motion_Entry,
	next_generation, next_revision:     u64,
	focus:                              Motion_Request,
	focus_pending, in_flight, stopping: bool,
	active:                             Motion_Request,
}

motion_coordinator_destroy :: proc(q: ^Motion_Coordinator) {delete(q.entries); q^ = {}}
motion_coordinator_stop :: proc(q: ^Motion_Coordinator) {
	q.stopping = true
	q.focus_pending = false
	for _, &entry in q.entries {entry.pending = false}
}
motion_coordinator_idle :: proc(q: ^Motion_Coordinator) -> bool {return !q.in_flight}
motion_register :: proc(q: ^Motion_Coordinator, window: u32, space: u64) -> Motion_Target {
	if q.stopping {
		return {}
	}
	if q.entries == nil {
		q.entries = make(map[u32]Motion_Entry)
	}
	if q.focus_pending && q.focus.target.window == window {
		q.focus_pending = false
	}
	q.next_generation += 1
	target := Motion_Target{window, space, q.next_generation}
	q.entries[window] = {
		target = target,
	}
	return target
}
motion_matches :: proc(q: ^Motion_Coordinator, target: Motion_Target) -> bool {
	entry, found := q.entries[target.window]
	return found && entry.target == target
}
motion_unregister :: proc(q: ^Motion_Coordinator, target: Motion_Target) {
	if !motion_matches(q, target) {
		return
	}
	delete_key(&q.entries, target.window)
	if q.focus_pending && q.focus.target == target {
		q.focus_pending = false
	}
}
motion_invalidate_space :: proc(q: ^Motion_Coordinator, space: u64) {
	ids: [dynamic]u32; defer delete(ids)
	for id, entry in q.entries {
		if entry.target.space == space {
			append(&ids, id)
		}
	}
	for id in ids {delete_key(&q.entries, id)}
	if q.focus_pending && q.focus.target.space == space {
		q.focus_pending = false
	}
}
motion_queue_position :: proc(q: ^Motion_Coordinator, target: Motion_Target, frame: Rect) -> bool {
	if q.stopping || !motion_matches(q, target) {
		return false
	}
	q.next_revision += 1
	entry := q.entries[target.window]
	entry.frame, entry.revision, entry.pending = frame, q.next_revision, true
	q.entries[target.window] = entry
	return true
}
motion_queue_focus :: proc(q: ^Motion_Coordinator, target: Motion_Target) -> bool {
	if q.stopping || !motion_matches(q, target) {
		return false
	}
	q.next_revision += 1
	q.focus = {
		kind     = .Focus,
		target   = target,
		revision = q.next_revision,
	}
	q.focus_pending = true
	return true
}
motion_take :: proc(q: ^Motion_Coordinator) -> (Motion_Request, bool) {
	if q.stopping || q.in_flight {
		return {}, false
	}
	job: Motion_Request
	if q.focus_pending {
		job = q.focus; q.focus_pending = false
	} else {
		found := false
		selected: u32
		for id, value in q.entries {
			if value.pending && (!found || value.revision < job.revision) {
				job = {
					kind     = .Position,
					target   = value.target,
					frame    = value.frame,
					revision = value.revision,
				}
				selected, found = id, true
			}
		}
		if !found {
			return {}, false
		}
		entry := q.entries[selected]; entry.pending = false; q.entries[selected] = entry
	}
	q.active, q.in_flight = job, true
	return job, true
}
motion_request_current :: proc(q: ^Motion_Coordinator, job: Motion_Request) -> bool {
	if q.stopping || !q.in_flight || q.active != job || !motion_matches(q, job.target) {
		return false
	}
	if job.kind == .Focus {
		return q.focus.revision == job.revision
	}
	return q.entries[job.target.window].revision == job.revision
}
motion_complete :: proc(q: ^Motion_Coordinator, job: Motion_Request, success: bool) -> bool {
	current := motion_request_current(q, job)
	if q.in_flight && q.active == job {
		q.in_flight = false
	}
	return success && current
}

// Motion traces
// ------------------------------------------------------------------------

// Opt-in bounded memory capture: no file I/O or logging on the animation path.
// Native bounds and AX completion are observations, not display presentation.
MOTION_TRACE_LIMIT :: 8192
MOTION_TRACE_SECONDS :: 60.0
Motion_Event :: struct {
	kind:                                   string,
	at_ms, duration_ms, source_time, value: f64,
	space:                                  u64,
	window:                                 u32,
	requested, observed:                    Rect,
	status:                                 i32,
}
Motion_Trace :: struct {
	active, full, expired: bool,
	started:               time.Tick,
	events:                [dynamic]Motion_Event,
}
Motion_Export :: struct {
	version:               int,
	active, full, expired: bool,
	limit:                 int,
	clock:                 string,
	events:                []Motion_Event,
}
motion_trace_record :: proc(trace: ^Motion_Trace, event: Motion_Event, now: time.Tick = {}) {
	if !trace.active {
		return
	}
	now := now
	if now == (time.Tick{}) {
		now = time.tick_now()
	}
	elapsed := time.duration_seconds(time.tick_diff(trace.started, now))
	if elapsed >= MOTION_TRACE_SECONDS {
		trace.active = false; trace.expired = true; return
	}
	if len(trace.events) >= MOTION_TRACE_LIMIT {
		trace.active = false; trace.full = true; return
	}
	event := event
	event.at_ms = elapsed * 1000
	append(&trace.events, event)
}
motion_debug :: proc(m: ^Manager, args: []string) -> Response {
	if len(args) == 2 && args[0] == "ws" && (args[1] == "status" || args[1] == "dump") {
		if m.ws_debug == nil {
			return failure("WindowServer adapter not available in this process")
		}
		return success(m.ws_debug(m.backend_user, args[1] == "dump"))
	}
	if len(args) == 3 && args[0] == "conceal" && (args[2] == "on" || args[2] == "off") {
		return debug_conceal(m, args[1], args[2] == "on")
	}
	if len(args) != 2 || args[0] != "motion" {
		return failure(DEBUG_USAGE)
	}
	t := &m.motion_trace
	switch args[1] {
	case "start":
		delete(t.events)
		t^ = {
			active  = true,
			started = time.tick_now(),
			events  = make([dynamic]Motion_Event, 0, MOTION_TRACE_LIMIT),
		}
		return success("motion capture started (60 seconds or 8192 events)")
	case "stop":
		t.active = false; return success("motion capture stopped")
	case "clear":
		delete(t.events); t^ = {}; return success()
	case "dump":
		motion_trace_record(t, {kind = "dump"})
		data, err := json.marshal(
			Motion_Export {
				1,
				t.active,
				t.full,
				t.expired,
				MOTION_TRACE_LIMIT,
				"monotonic milliseconds since capture start; source_time is CGEvent uptime for input, Core Animation uptime for presentation-tick",
				t.events[:],
			},
			allocator = context.temp_allocator,
		)
		if err != nil {
			return failure("could not encode motion trace")
		}
		return success(string(data))
	}
	return failure(DEBUG_USAGE)
}

// Where a window joined the layout: value = windows in its column, status =
// 1 when that column is tabbed, requested.x = the armed insertion window.
motion_trace_join :: proc(m: ^Manager, s: ^Space, id: u32, kind: string) {
	if !m.motion_trace.active || s == nil {
		return
	}
	n := layout.find(s.view.root, id)
	event := Motion_Event {
		kind = kind,
		window = id,
		space = s.id,
		requested = {x = f64(s.view.insertion)},
	}
	if n != nil {
		event.value = f64(n.count)
		event.status = n.column_tabbed ? 1 : 0
	}
	motion_trace_record(&m.motion_trace, event)
}

DEBUG_USAGE :: "debug expects motion start|stop|dump|clear, ws status|dump or conceal WID on|off"

debug_conceal :: proc(m: ^Manager, window: string, conceal: bool) -> Response {
	wid, ok := strconv.parse_u64(window)
	if !ok || wid == 0 || wid > u64(max(u32)) {
		return failure("conceal expects a window id")
	}
	if m.windows[u32(wid)] == nil {
		return failure("conceal expects a managed window")
	}
	if err := perform(m, {kind = .Conceal, window = u32(wid), flag = conceal}); err != "" {
		return failure(err)
	}
	return success()
}
