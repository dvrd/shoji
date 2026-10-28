package macos

import recovery "../addition/recovery"
import e "../engine"
import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import objc "core:sys/darwin/Foundation"
import posix "core:sys/posix"
import "core:time"

foreign import libc "system:c"
foreign import window_sls "system:SkyLight.framework"

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

run_config :: proc(path: string) -> bool {
	if path == "" {
		return true
	}
	// The path is passed as argv, never interpolated into shell source.
	argv := [3]cstring {
		"/bin/sh",
		strings.clone_to_cstring(path, context.temp_allocator),
		nil,
	}
	pid: posix.pid_t
	if posix.posix_spawn(
		   &pid,
		   "/bin/sh",
		   nil,
		   nil,
		   &argv[0],
		   _NSGetEnviron()^,
	   ) !=
	   nil {
		fmt.eprintf("shoji: cannot execute config %s\n", path)
		return false
	}
	return true
}

startup_config_start :: proc(
	path: string,
	reload: ^Addition_Reload,
	started: ^bool,
	launch: proc(_: string) -> bool = run_config,
) -> bool {
	if started^ {
		return true
	}
	if path != "" && reload.payload != "" && !reload.healthy {
		return true
	}
	if !launch(path) {
		return false
	}
	started^ = true
	return true
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
		e.query(&state.manager, []string{"--displays"}).text,
		",\"spaces\":",
		e.query(&state.manager, []string{"--spaces"}).text,
		",\"windows\":",
		e.query(&state.manager, []string{"--windows"}).text,
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
		   w != nil && w.floating && state.mouse.buttons != 0 {
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
			if err := e.flush(&state.manager, s); err != "" {
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
	refresh(&state)
	state.opening_tracking = true
	config := strings.clone(config_path == "" ? default_config() : config_path)
	defer delete(config)
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
	if !startup_config_start(config, &reload, &config_started) {
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
			e.motion_trace_record(&state.manager.motion_trace, {kind = "loop"})
			workspace_tick(&state)
			addition_reload_tick(
				&reload,
				state.workspace_events.dock_pid,
				time.now(),
			)
			if !startup_config_start(config, &reload, &config_started) {
				return 1
			}
			animation_recovery_tick(&state, time.now())
			desktop_commands_tick(&commands, &state, &last_refresh, time.now())
			moving := motion_active(&state)
			display := CGMainDisplayID()
			if s := e.space_by_id(&state.manager, state.manager.active_space);
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
				e.motion_trace_record(
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
			status: i32
			for {
				pid := posix.waitpid(-1, &status, {.NOHANG})
				if pid <= 0 {
					break
				}
				addition_reload_finished(
					&reload,
					i32(pid),
					posix.WIFEXITED(status) && posix.WEXITSTATUS(status) == 0,
					time.now(),
				)
			}
		}
	}
	return 0
}

// Native application notifications
// ------------------------------------------------------------------------

Workspace_Event :: enum {
	Wake,
	Dock_Restart,
	Dock_Pref,
	Menu_Bar,
	Display,
	Refresh,
}
Workspace_Events :: bit_set[Workspace_Event]
Workspace_State :: struct {
	listener: ^objc.Object,
	centers: [3]^objc.Object,
	mutex: sync.Mutex,
	pending: Workspace_Events,
	dock_pid, last_dock_pid: i32,
	last_poll: time.Time,
	dock_element, dock_observer: Ref,
	mission_active, desired_mission: bool,
}
workspace_listener_class: objc.Class
workspace_listener_states: map[rawptr]^State
workspace_registry_mutex: sync.Mutex

workspace_notification :: proc "c" (
	object, selector, notification: ^objc.Object,
) {
	context = runtime.default_context()
	sync.mutex_lock(&workspace_registry_mutex)
	defer sync.mutex_unlock(&workspace_registry_mutex)
	state := workspace_listener_states[rawptr(object)]
	if state == nil {
		return
	}
	name := objc_text(intrinsics.objc_send(^objc.Object, notification, "name"))
	workspace_record(state, name)
}

workspace_record :: proc(state: ^State, name: string) {
	w := &state.workspace_events
	sync.mutex_lock(&w.mutex); defer sync.mutex_unlock(&w.mutex)
	switch name {
	case "NSWorkspaceDidWakeNotification":
		w.pending += {.Wake}
	case "NSApplicationDockDidRestartNotification":
		w.pending += {.Dock_Restart}
	case "com.apple.dock.prefchanged":
		w.pending += {.Dock_Pref}
	case "AppleInterfaceMenuBarHidingChangedNotification":
		w.pending += {.Menu_Bar}
	case "NSWorkspaceActiveDisplayDidChangeNotification":
		w.pending += {.Display}
	case "NSWorkspaceActiveSpaceDidChangeNotification",
	     "NSWorkspaceDidHideApplicationNotification",
	     "NSWorkspaceDidUnhideApplicationNotification":
		w.pending += {.Refresh}
	case "AXExposeShowAllWindows",
	     "AXExposeShowFrontWindows",
	     "AXExposeShowDesktop":
		w.desired_mission = true
	case "AXExposeExit":
		w.desired_mission = false
	case:
	}
}

workspace_start :: proc(state: ^State) -> bool {
	sync.mutex_lock(&workspace_registry_mutex)
	defer sync.mutex_unlock(&workspace_registry_mutex)
	if workspace_listener_class == nil {
		workspace_listener_class = objc.objc_allocateClassPair(
			objc.objc_lookUpClass("NSObject"),
			"ShojiWorkspaceObserver",
			0,
		)
		if workspace_listener_class == nil {
			return false
		}
		if !objc.class_addMethod(
			workspace_listener_class,
			objc.sel_registerName("notification:"),
			cast(objc.IMP)workspace_notification,
			"v@:@",
		) {
			return false
		}
		objc.objc_registerClassPair(workspace_listener_class)
	}
	if workspace_listener_states == nil {
		workspace_listener_states = make(map[rawptr]^State)
	}
	w := &state.workspace_events
	w.listener = intrinsics.objc_send(
		^objc.Object,
		(^objc.Object)(workspace_listener_class),
		"new",
	)
	workspace_listener_states[rawptr(w.listener)] = state
	w.centers[0] = intrinsics.objc_send(
		^objc.Object,
		workspace(),
		"notificationCenter",
	)
	w.centers[1] = intrinsics.objc_send(
		^objc.Object,
		(^objc.Object)(objc.objc_lookUpClass("NSNotificationCenter")),
		"defaultCenter",
	)
	w.centers[2] = intrinsics.objc_send(
		^objc.Object,
		(^objc.Object)(
			objc.objc_lookUpClass("NSDistributedNotificationCenter"),
		),
		"defaultCenter",
	)
	names := [][]string {
		{
			"NSWorkspaceDidWakeNotification",
			"NSWorkspaceActiveDisplayDidChangeNotification",
			"NSWorkspaceActiveSpaceDidChangeNotification",
			"NSWorkspaceDidHideApplicationNotification",
			"NSWorkspaceDidUnhideApplicationNotification",
		},
		{"NSApplicationDockDidRestartNotification"},
		{
			"com.apple.dock.prefchanged",
			"AppleInterfaceMenuBarHidingChangedNotification",
		},
	}
	for group, i in names {
		for name in group {
			value := cf_string(name)
			intrinsics.objc_send(
				nil,
				w.centers[i],
				"addObserver:selector:name:object:",
				w.listener,
				objc.sel_registerName("notification:"),
				(^objc.Object)(value),
				(^objc.Object)(nil),
			)
			CFRelease(value)
		}
	}
	return true
}

workspace_unobserve_dock :: proc(state: ^State) {
	w := &state.workspace_events
	if w.dock_observer != nil {
		CFRunLoopRemoveSource(
			CFRunLoopGetMain(),
			AXObserverGetRunLoopSource(w.dock_observer),
			kCFRunLoopDefaultMode,
		)
		CFRelease(w.dock_observer); w.dock_observer = nil
	}
	if w.dock_element != nil {
		CFRelease(w.dock_element); w.dock_element = nil
	}
}

workspace_stop :: proc(state: ^State) {
	w := &state.workspace_events
	workspace_unobserve_dock(state)
	if w.listener != nil {
		for center in w.centers { intrinsics.objc_send(nil, center, "removeObserver:", w.listener) }
		sync.mutex_lock(&workspace_registry_mutex)
		delete_key(&workspace_listener_states, rawptr(w.listener))
		if len(workspace_listener_states) == 0 {
			delete(workspace_listener_states); workspace_listener_states = nil
		}
		sync.mutex_unlock(&workspace_registry_mutex)
		intrinsics.objc_send(nil, w.listener, "release")
		w.listener = nil
	}
}

mission_callback :: proc "c" (
	observer, element, notification: Ref,
	user: rawptr,
) {
	context = runtime.default_context()
	workspace_record((^State)(user), text(notification))
}

// Keep the last live PID across a poll that observes Dock absent.
workspace_set_dock_pid :: proc(state: ^State, pid: i32) {
	w := &state.workspace_events
	if pid == w.dock_pid {
		return
	}
	workspace_unobserve_dock(state)
	if pid != 0 {
		if w.last_dock_pid != 0 && pid != w.last_dock_pid {
			workspace_record(state, "NSApplicationDockDidRestartNotification")
		}
		w.last_dock_pid = pid
	}
	w.dock_pid = pid
	workspace_record(state, "AXExposeExit")
}

workspace_poll_dock :: proc() -> i32 {
	// Also safe when called by startup diagnostics outside the daemon loop.
	pool := pool_push(); defer pool_pop(pool)
	identifier := cf_string("com.apple.dock")
	defer CFRelease(identifier)
	apps := intrinsics.objc_send(
		^objc.Object,
		Running_Application,
		"runningApplicationsWithBundleIdentifier:",
		(^objc.Object)(identifier),
	)
	if intrinsics.objc_send(uint, apps, "count") != 1 {
		return 0
	}
	app := intrinsics.objc_send(^objc.Object, apps, "objectAtIndex:", uint(0))
	return intrinsics.objc_send(i32, app, "processIdentifier")
}

workspace_tick :: proc(state: ^State, detect_dock: bool = true) {
	w := &state.workspace_events
	now := time.now()
	if detect_dock &&
	   (w.last_poll == time.Time{} ||
			   time.diff(w.last_poll, now) >= time.Second) {
		w.last_poll = now
		pid := workspace_poll_dock()
		workspace_set_dock_pid(state, pid)
		if pid != 0 && w.dock_observer == nil {
			w.dock_element = AXUIElementCreateApplication(pid)
			if AXObserverCreate(pid, mission_callback, &w.dock_observer) == 0 {
				for name in ([]string {
						"AXExposeShowAllWindows",
						"AXExposeShowFrontWindows",
						"AXExposeShowDesktop",
						"AXExposeExit",
					}) { observe(state, w.dock_observer, w.dock_element, name) }
				CFRunLoopAddSource(
					CFRunLoopGetMain(),
					AXObserverGetRunLoopSource(w.dock_observer),
					kCFRunLoopDefaultMode,
				)
			} else {
				CFRelease(w.dock_element); w.dock_element = nil
			}
		}
	}
	sync.mutex_lock(&w.mutex)
	pending, mission := w.pending, w.desired_mission
	w.pending = {}
	sync.mutex_unlock(&w.mutex)
	if mission != w.mission_active {
		w.mission_active = mission
		state.manager.suspended = mission
		state.dirty = true
		emit(
			state,
			Event {
				name = mission \
					? "mission_control_enter" \
					: "mission_control_exit",
			},
		)
	}
	names := [Workspace_Event]string {
		.Wake         = "system_woke",
		.Dock_Restart = "dock_did_restart",
		.Dock_Pref    = "dock_did_change_pref",
		.Menu_Bar     = "menu_bar_hidden_changed",
		.Display      = "display_changed",
		.Refresh      = "",
	}
	for event in pending {
		state.dirty = true
		// Display IDs are only known after refresh reconciles the active Space.
		if event != .Refresh && event != .Display {
			emit(state, Event{name = names[event]})
		}
	}
}

// Application polling policy
// ------------------------------------------------------------------------

// Query WindowServer once, rather than sending AXWindows to every menu-bar helper.
// Occluded windows are included; desktop elements and non-document levels are not.
accessory_window_owners :: proc() -> (owners: map[i32]bool, known: bool) {
	list := CGWindowListCopyWindowInfo(1 | 16, 0)
	if list == nil {
		return nil, false
	}
	defer CFRelease(list)
	owners = make(map[i32]bool, context.temp_allocator)
	for i in 0 ..< CFArrayGetCount(list) {
		entry := CFArrayGetValueAtIndex(list, i)
		if number(dictionary(entry, "kCGWindowLayer")) != 0 {
			continue
		}
		pid := i32(number(dictionary(entry, "kCGWindowOwnerPID")))
		if pid > 0 {
			owners[pid] = true
		}
	}
	return owners, true
}

poll_application_windows :: proc(
	pid: i32,
	activation_policy: int,
	frontmost_pid: i32,
	owners: map[i32]bool,
	owners_known: bool,
) -> bool {
	if activation_policy == 0 {
		return true
	}
	if activation_policy != 1 {
		return false
	}
	return !owners_known || pid == frontmost_pid || owners[pid]
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
		objc_text(
			intrinsics.objc_send(^objc.Object, running, "localizedName"),
		),
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
	defer { state.opening_collecting = false }
	defer {
		if !state.read_only && state.manager.shadow_configured {
			if err := e.apply_window_shadows(&state.manager); err != "" {
				fmt.eprintln("shoji: shadow:", err)
			}
		}
	}
	pool := pool_push()
	defer pool_pop(pool)
	refresh_displays(state)
	m := &state.manager
	apps := intrinsics.objc_send(
		^objc.Object,
		workspace(),
		"runningApplications",
	)
	frontmost := intrinsics.objc_send(
		^objc.Object,
		workspace(),
		"frontmostApplication",
	)
	frontmost_pid := intrinsics.objc_send(i32, frontmost, "processIdentifier")
	accessory_owners, owners_known := accessory_window_owners()
	seen := make(map[u32]bool, context.temp_allocator)
	seen_apps := make(map[i32]bool, context.temp_allocator)
	for i in 0 ..< intrinsics.objc_send(uint, apps, "count") {
		running := intrinsics.objc_send(
			^objc.Object,
			apps,
			"objectAtIndex:",
			i,
		)
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
		if !poll_application_windows(
			pid,
			policy,
			frontmost_pid,
			accessory_owners,
			owners_known,
		) {
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
			observation := collect_window(
				state,
				app,
				element,
				id,
				pid,
				policy,
				hidden,
			)
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
		e.remove_window(m, id)
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

refresh_effects :: proc(state: ^State) {
	m := &state.manager
	if !state.read_only {
		if err := e.reconcile_window_memberships(m); err != "" {
			fmt.eprintln("shoji:", err)
		}
	}
	front := intrinsics.objc_send(
		^objc.Object,
		workspace(),
		"frontmostApplication",
	)
	pid := intrinsics.objc_send(i32, front, "processIdentifier")
	if app, ok := state.applications[pid]; ok {
		focused := attribute(app.element, "AXFocusedWindow")
		if focused != nil {
			id: u32
			_AXUIElementGetWindow(focused, &id)
			CFRelease(focused)
			if w := m.windows[id];
			   w != nil &&
			   (w.opening.phase == .Pending || w.opening.phase == .Opening) &&
			   w.opening.focus_superseded {
				if replacement := m.windows[w.opening.focus_replacement];
				   replacement != nil {
					if e.perform(
						   m,
						   {
							   kind = .Focus_Without_Raise,
							   window = replacement.id,
						   },
					   ) ==
					   "" {
						id = replacement.id
					}
				}
			}
			e.focus_window(m, id)
		}
	}
	if !state.read_only && m.window_opacity {
		if err := e.apply_window_opacity(m); err != "" {
			fmt.eprintln("shoji: opacity:", err)
		}
	}
	if !state.read_only {
		if _, err := addition_check(); err == "" {
			if err := e.apply_window_layers(m); err != "" {
				fmt.eprintln("shoji: layer:", err)
			}
		}
		mouse_follow_focus(state)
	}
}

// Window observations
// ------------------------------------------------------------------------

// A single native read, with unknown values retained explicitly. Borrowed
// strings remain valid for the refresh tick; reconciliation owns model strings.
Window_Appearance :: struct {
	sub_level: i32,
	ordered_in: Maybe(bool),
	tags: Maybe(u64),
	opacity: Maybe(f64),
	level: Maybe(i32),
	can_move: Maybe(bool),
}

attribute_capability :: proc(element: Ref, name: string) -> Maybe(bool) {
	key := cf_string(name); defer CFRelease(key)
	value: bool
	if AXUIElementIsAttributeSettable(element, key, &value) != 0 {
		return nil
	}
	return value
}

collect_window :: proc(
	state: ^State,
	app: Application,
	element: Ref,
	id: u32,
	pid: i32,
	policy: int,
	hidden: bool,
) -> e.Window {
	result: e.Window
	sid := window_space(state, id)
	display: u32
	if s := e.space_by_id(&state.manager, sid); s != nil {
		display = s.display
	}
	w := &result
	frame := window_frame(element)
	w^ = {
		id                    = id,
		pid                   = pid,
		app                   = app.name,
		title                 = attribute_text(element, "AXTitle"),
		ordered_in            = window_ordered_in(state, id),
		root_window           = window_is_root(
			state,
			id,
			element,
			app.element,
		),
		frame                 = frame.? or_else e.Rect{},
		frame_valid           = frame != nil,
		can_resize            = attribute_capability(element, "AXSize"),
		application_accessory = policy == 1,
		space                 = sid,
		display               = display,
		hidden                = hidden,
		minimized             = attribute_bool(element, "AXMinimized"),
		fullscreen            = attribute_bool(element, "AXFullScreen"),
		opacity               = 1,
		layer                 = "normal",
	}
	// Roles are immutable for an existing window; avoid extra synchronous reads.
	if old := state.manager.windows[id];
	   old == nil || old.pid != pid || old.role == "" || old.subrole == "" {
		w.role = attribute_text(element, "AXRole")
		w.subrole = attribute_text(element, "AXSubrole")
	}
	return result
}

collect_window_appearance :: proc(
	state: ^State,
	element: Ref,
	id: u32,
) -> Window_Appearance {
	result: Window_Appearance
	tags: u64
	if SLSGetWindowTags(state.connection, id, &tags, 64) == 0 {
		result.tags = tags
	}
	level: i32
	if SLSGetWindowLevel(state.connection, id, &level) == 0 {
		result.level = level
	}
	result.sub_level = SLSGetWindowSubLevel(state.connection, id)
	alpha: f32
	if SLSGetWindowAlpha(state.connection, id, &alpha) == 0 {
		result.opacity = f64(alpha)
	}
	result.can_move = attribute_capability(element, "AXPosition")
	result.ordered_in = window_ordered_in(state, id)
	return result
}

reconcile_window :: proc(
	state: ^State,
	app: Application,
	element: Ref,
	value: e.Window,
) -> (
	^e.Window,
	bool,
) {
	m := &state.manager
	w := m.windows[value.id]
	if w != nil && w.pid != value.pid {
		window_reference_remove(
			state,
			value.id,
			state.applications[w.pid].observer,
		)
		e.remove_window(m, value.id)
	}
	window_reference_update(state, value.id, element, app.observer)
	return reconcile_window_model(m, value)
}

// Native queries stay in collection. Unknown capabilities and spaces preserve
// the previous observation; a failed query must not revoke a known capability.
reconcile_window_model :: proc(
	m: ^e.Manager,
	value: e.Window,
) -> (
	^e.Window,
	bool,
) {
	w := m.windows[value.id]
	created := w == nil
	if created {
		w = e.add_window(m, value)
		if w.rule_error != "" {
			fmt.eprintf(
				"shoji: window %d rule deferred: %s\n",
				w.id,
				w.rule_error,
			)
		}
	} else {
		if w.role == "" {
			w.role = strings.clone(value.role)
		}
		if w.subrole == "" {
			w.subrole = strings.clone(value.subrole)
		}
		if value.ordered_in != nil {
			w.ordered_in = value.ordered_in
		}
		if value.can_resize != nil {
			w.can_resize = value.can_resize
		}
		w.root_window = value.root_window
		w.hidden, w.minimized, w.fullscreen =
			value.hidden, value.minimized, value.fullscreen
		if (value.frame_valid.? or_else true) && valid_frame(value.frame) {
			w.frame = value.frame
			w.frame_valid = true
			e.size_feedback_late_result(w, value.frame)
		}
		if w.title != value.title {
			delete(w.title); w.title = strings.clone(value.title)
		}
		if value.space != 0 {
			w.space, w.display = value.space, value.display
		}
	}
	return w, created
}

reconcile_window_appearance :: proc(
	w: ^e.Window,
	appearance: Window_Appearance,
) {
	if tags, known := appearance.tags.?; known {
		w.sticky = tags & (1 << 11) != 0; w.shadow = tags & (1 << 3) == 0
	}
	if level, known := appearance.level.?; known {
		w.level = level
	}
	w.sub_level = appearance.sub_level
	w.layer =
		w.sub_level < 0 ? "below" : (w.sub_level > 0 ? "above" : "normal")
	if opacity, known := appearance.opacity.?; known {
		w.opacity = opacity
	}
	if can_move, known := appearance.can_move.?; known {
		w.can_move = can_move
	}
	if w.scratchpad != "" {
		if ordered, known := appearance.ordered_in.?; known {
			w.scratchpad_hidden = !ordered
		}
	}
}

refresh_window_rules :: proc(m: ^e.Manager, w: ^e.Window) {
	previous_error := strings.clone(w.rule_error, context.temp_allocator)
	if err := e.apply_rules(m, w); err != "" && err != previous_error {
		fmt.eprintf("shoji: window %d rule deferred: %s\n", w.id, err)
	}
}

// Visibility and reference retention
// ------------------------------------------------------------------------

Window_Presence :: enum {
	Unknown,
	Present,
	Missing,
	Reused,
}
Window_Observation :: struct {
	presence: Window_Presence,
	ordered_in: Maybe(bool),
}
Window_Probe :: struct {
	probe: proc(
		user: rawptr,
		state: ^State,
		window: ^e.Window,
	) -> Window_Observation,
	user: rawptr,
}
foreign window_sls {
	SLSConnectionGetPID :: proc "c" (connection: i32, pid: ^i32) -> i32 ---
}
window_ordered_in :: proc(state: ^State, id: u32) -> Maybe(bool) {
	ordered: u8
	if SLSWindowIsOrderedIn(state.connection, id, &ordered) != 0 {
		return nil
	}
	return ordered != 0
}
native_window_probe :: proc(
	user: rawptr,
	state: ^State,
	window: ^e.Window,
) -> Window_Observation {
	id := window.id
	number := CFNumberCreate(nil, 3, &id); defer CFRelease(number)
	array := CFArrayCreate(nil, &number, 1, nil); defer CFRelease(array)
	query := SLSWindowQueryWindows(state.connection, array, 1)
	if query == nil {
		return {}
	}
	defer CFRelease(query)
	iterator := SLSWindowQueryResultCopyWindows(query)
	if iterator == nil {
		return {}
	}
	defer CFRelease(iterator)
	count := SLSWindowIteratorGetCount(iterator)
	if count == 0 {
		return {presence = .Missing}
	}
	if count != 1 || !SLSWindowIteratorAdvance(iterator) {
		return {}
	}
	owner, ok := animation_recovery_query_owner(state.connection, id)
	pid: i32
	if !ok || SLSConnectionGetPID(owner, &pid) != 0 {
		return {}
	}
	if pid != window.pid {
		return {presence = .Reused}
	}
	return {presence = .Present, ordered_in = window_ordered_in(state, id)}
}
retain_unlisted_windows :: proc(
	state: ^State,
	seen: ^map[u32]bool,
	seen_apps: map[i32]bool,
) {
	probe := state.window_probe.probe
	if probe == nil {
		probe = native_window_probe
	}
	for id, window in state.manager.windows {
		if seen[id] || !seen_apps[window.pid] || state.windows[id] == nil {
			continue
		}
		// Native inactive tabs can disappear from AXWindows without destruction.
		// A failed WindowServer query is inconclusive; retain the last observation.
		observation := probe(state.window_probe.user, state, window)
		if observation.presence == .Missing ||
		   observation.presence == .Reused {
			continue
		}
		seen[id] = true
		if app, exists := state.applications[window.pid]; exists {
			window.hidden = app.hidden
		}
		if observation.presence == .Present && observation.ordered_in != nil {
			window.ordered_in = observation.ordered_in
		}
	}
}
WINDOW_NOTIFICATIONS :: []string {
	"AXUIElementDestroyed",
	"AXMoved",
	"AXResized",
	"AXTitleChanged",
	"AXWindowMiniaturized",
	"AXWindowDeminiaturized",
}
window_reference_remove :: proc(state: ^State, id: u32, observer: Ref) {
	previous := state.windows[id]
	if previous == nil {
		return
	}
	if observer != nil {
		for name in WINDOW_NOTIFICATIONS {
			key := cf_string(name)
			AXObserverRemoveNotification(observer, previous, key)
			CFRelease(key)
		}
	}
	CFRelease(previous)
	delete_key(&state.windows, id)
}
window_reference_update :: proc(
	state: ^State,
	id: u32,
	element, observer: Ref,
) {
	previous := state.windows[id]
	if previous != nil && CFEqual(previous, element) {
		return
	}
	window_reference_remove(state, id, observer)
	state.windows[id] = CFRetain(element)
	if observer != nil {
		for name in WINDOW_NOTIFICATIONS {
			observe(state, observer, element, name)
		}
	}
}

// Opening readiness
// ------------------------------------------------------------------------

Opening_Guard :: struct {
	proxy: Animation_Proxy,
	hidden: bool,
	requested, sample: e.Rect,
	original: e.Rect,
	samples: int,
	checked: time.Time,
}

// Diagnostic builds arm on discovery so a human-triggered opening cannot miss
// the bounded capture interval. Only geometry and native operation status enter it.
opening_trace_begin :: proc(state: ^State) {
	when #config(SHOJI_OPENING_TRACE, false) {
		if !state.manager.motion_trace.active {
			e.motion_debug(&state.manager, {"motion", "start"})
		}
	}
}

opening_trace_native :: proc(
	state: ^State,
	kind: string,
	id: u32,
	requested: e.Rect = {},
) {
	if !state.manager.motion_trace.active {
		return
	}
	actual: e.Rect
	code := SLSGetWindowBounds(state.connection, id, &actual)
	e.motion_trace_record(
		&state.manager.motion_trace,
		{
			kind = kind,
			window = id,
			requested = requested,
			observed = actual,
			status = code,
		},
	)
}

// Both native notifications and enumeration use this admission boundary.
opening_observe :: proc(
	state: ^State,
	app: Application,
	element: Ref,
	observation: e.Window,
) -> ^e.Window {
	value := observation
	old := state.manager.windows[value.id]
	if state.opening_tracking &&
	   !state.read_only &&
	   (old == nil || old.pid != value.pid) {
		opening_trace_begin(state)
		opening_trace_native(state, "opening-discovered", value.id)
		value.opening = {
			phase        = .Pending,
			focus_origin = state.manager.focused,
		}
	}
	w: ^e.Window
	if element != nil {
		w, _ = reconcile_window(state, app, element, value)
	} else {
		w, _ = reconcile_window_model(&state.manager, value)
	}
	if w.opening.phase == .Pending {
		if state.opening_windows == nil {
			state.opening_windows = make(map[u32]bool)
		}
		state.opening_windows[w.id] = true
		if state.opening_collecting {
			backend := state.opening_backend
			if backend.prepare == nil {
				backend = {opening_native_prepare, opening_conceal}
			}
			_, err := e.stage_opening(&state.manager, w, backend)
			if err != "" {
				fmt.eprintln("shoji: stage opening:", w.id, err)
			}
		} else {
			opening_attempt(state, w)
		}
	}
	if element != nil {
		reconcile_window_appearance(
			w,
			collect_window_appearance(state, element, w.id),
		)
	}
	return w
}

opening_created :: proc(state: ^State, observer, element: Ref) {
	if state.read_only || !state.opening_tracking {
		return
	}
	id: u32
	if _AXUIElementGetWindow(element, &id) != 0 ||
	   id == 0 ||
	   attribute_text(element, "AXRole") != "AXWindow" {
		return
	}
	opening_trace_begin(state)
	opening_trace_native(state, "opening-created", id)
	for pid, app in state.applications {
		if app.observer != observer {
			continue
		}
		if state.validation_pid != 0 && state.validation_pid != pid {
			return
		}
		opening_observe(
			state,
			app,
			element,
			collect_window(
				state,
				app,
				element,
				id,
				pid,
				app.policy,
				app.hidden,
			),
		)
		return
	}
}

// The transparent owned surface is a liveness token, not a screenshot. Dock's
// orphan recovery restores the real window if the token owner crashes.
opening_conceal :: proc(m: ^e.Manager, w: ^e.Window) -> string {
	state := (^State)(m.backend_user)
	guard, exists := state.opening_guards[w.id]
	if !exists {
		owner, known := animation_recovery_query_owner(state.connection, w.id)
		pid: i32
		if !known || SLSConnectionGetPID(owner, &pid) != 0 || pid != w.pid {
			return "opening window ownership is unavailable"
		}
		surface, err := surface_create(
			state,
			{0, 0, 1, 1},
			w.id,
			(1 << 1) | (1 << 3) | (1 << 9),
			13,
			1,
		)
		if err != "" {
			return err
		}
		proxy_owner, proxy_known := animation_recovery_query_owner(
			state.connection,
			surface.id,
		)
		if !proxy_known {
			surface_destroy(state, surface)
			return "opening token ownership is unavailable"
		}
		if err := animation_journal_record(
			&state.animation_journal,
			recovery.Entry{w.id, surface.id, owner, proxy_owner},
		); err != "" {
			surface_destroy(state, surface); return err
		}
		CGContextClearRect(surface.ctx, {0, 0, 1, 1})
		CGContextFlush(surface.ctx)
		guard.proxy = {
			window  = w.id,
			surface = surface,
		}
		guard.original = w.frame
		if state.opening_guards == nil {
			state.opening_guards = make(map[u32]Opening_Guard)
		}
		state.opening_guards[w.id] = guard
	}
	if guard.hidden {
		return ""
	}
	opening_trace_native(state, "opening-conceal-begin", w.id)
	if err := animation_swap(guard.proxy, true); err != "" {
		return err
	}
	opening_trace_native(state, "opening-conceal-end", w.id)
	guard.hidden = true; state.opening_guards[w.id] = guard
	return ""
}

opening_release :: proc(state: ^State, id: u32) -> string {
	guard, exists := state.opening_guards[id]
	if !exists {
		return ""
	}
	if w := state.manager.windows[id];
	   w != nil &&
	   (w.opening.phase == .Pending || w.opening.phase == .Excluded) &&
	   guard.requested.w > 0 &&
	   guard.original.w > 0 {
		if err := apply_frame_now(state, id, guard.original); err != "" {
			return err
		}
	}
	opening_trace_native(state, "opening-reveal-begin", id)
	if err := native_proxy_restore(state, guard.proxy); err != "" {
		return err
	}
	opening_trace_native(state, "opening-reveal-end", id)
	native_proxy_destroy(state, guard.proxy)
	delete_key(&state.opening_guards, id)
	return ""
}

opening_native_prepare :: proc(
	m: ^e.Manager,
	w: ^e.Window,
	seed: e.Rect,
) -> (
	e.Rect,
	bool,
	string,
) {
	state := (^State)(m.backend_user)
	element := state.windows[w.id]
	guard, exists := state.opening_guards[w.id]
	if element == nil || !exists || !guard.hidden {
		return {}, false, ""
	}
	if guard.requested != seed {
		if err := e.perform(
			m,
			{kind = .Frame, window = w.id, frame = seed, direct = true},
		); err != "" {
			return {}, false, err
		}
		guard.requested = seed; guard.samples = 0
		guard.checked = time.now(); state.opening_guards[w.id] = guard
		return {}, false, ""
	}
	now := time.now()
	if time.diff(guard.checked, now) < 8 * time.Millisecond {
		return {}, false, ""
	}
	accepted, valid := window_frame(element).?
	if !valid {
		return {}, false, ""
	}
	if math.abs(accepted.x - guard.sample.x) <= 1 &&
	   math.abs(accepted.y - guard.sample.y) <= 1 &&
	   math.abs(accepted.w - guard.sample.w) <= 1 &&
	   math.abs(accepted.h - guard.sample.h) <= 1 {
		guard.samples += 1
	} else {
		guard.samples = 1
	}
	guard.sample = accepted; guard.checked = now
	state.opening_guards[w.id] = guard
	return accepted, guard.samples >= 2, ""
}

opening_attempt :: proc(state: ^State, w: ^e.Window) {
	backend := state.opening_backend
	if backend.prepare == nil {
		backend = {opening_native_prepare, opening_conceal}
	}
	wait := w.opening.wait
	admitted, err := e.admit_window(&state.manager, w, backend)
	if admitted {
		opening_trace_native(state, "opening-admitted", w.id, w.opening.seed)
	}
	if err != "" && wait != .Backend {
		fmt.eprintln("shoji: opening:", w.id, err)
	}
	if admitted || w.opening.phase == .Excluded {
		if err := opening_release(state, w.id); err != "" {
			fmt.eprintln("shoji: reveal opening:", err)
		}
	}
}

opening_destroyed :: proc(state: ^State, element: Ref) {
	id: u32
	for window, ref in state.windows {
		if CFEqual(element, ref) {
			id = window; break
		}
	}
	if id == 0 {
		return
	}
	w := state.manager.windows[id]
	// Remove the decoration before AX unsubscription, recovery or reflow can
	// block. Its generation still names the real owner when ordered above a
	// proxy, and focus may already have moved to another window.
	if state.focus_ring.window == id ||
	   (w != nil && state.focus_ring.generation == w.generation) {
		focus_ring_stop(state)
	}
	if w == nil {
		return
	}
	s := e.space_by_id(&state.manager, w.space)
	app := state.applications[w.pid]
	window_reference_remove(state, id, app.observer)
	e.remove_window(&state.manager, id)
	if err := opening_release(state, id); err != "" {
		fmt.eprintln("shoji: closed opening:", err)
	}
	delete_key(&state.opening_windows, id)
	if s != nil {
		if err := e.flush(&state.manager, s); err != "" {
			fmt.eprintln("shoji: close layout:", err)
		}
	}
}

opening_tick :: proc(state: ^State) {
	if state.read_only ||
	   state.manager.suspended ||
	   state.manager.gesture_active {
		return
	}
	ids := make(
		[dynamic]u32,
		0,
		len(state.opening_windows),
		context.temp_allocator,
	)
	for id in state.opening_windows { append(&ids, id) }
	e.sort_ids(ids[:])
	for id in ids {
		w := state.manager.windows[id]
		if w == nil ||
		   w.opening.phase == .Excluded ||
		   w.opening.phase == .Admitted {
			if err := opening_release(state, id); err == "" {
				delete_key(&state.opening_windows, id)
			}
			continue
		}
		if w.opening.phase == .Pending {
			if element := state.windows[id]; element != nil {
				w.ordered_in = window_ordered_in(state, id)
				if sid := window_space(state, id); sid != 0 {
					w.space = sid
				}
				if observed, valid := window_frame(element).?; valid {
					w.frame = observed
				}
			}
			opening_attempt(state, w)
			continue
		}
		if err := opening_release(state, id); err != "" {
			continue
		}
		busy := false
		for window in state.animations {
			if other := state.manager.windows[window];
			   other != nil && other.space == w.space {
				busy = true; break
			}
		}
		if s := e.space_by_id(&state.manager, w.space);
		   s != nil &&
		   s.view.layout == .Scroll &&
		   (s.view.scroll.motion.active || s.view.scroll.geometry_active) {
			busy = true
		}
		if !busy {
			if err := e.finish_opening(&state.manager, w); err != "" {
				fmt.eprintln("shoji: finish opening:", err)
			}
		}
	}
	opening_notice_tick(state)
}

opening_stop :: proc(state: ^State) {
	for id, guard in state.opening_guards {
		if w := state.manager.windows[id];
		   w != nil && w.opening.phase == .Pending {
			e.perform(
				&state.manager,
				{kind = .Layer, window = id, value = w.opening.original_layer},
			)
		}
		if err := opening_release(state, id); err != "" {
			fmt.eprintln("shoji: opening recovery:", err)
			native_proxy_destroy(state, guard.proxy)
		}
	}
	delete(state.opening_guards); delete(state.opening_windows)
	surface_destroy(state, state.opening_notice)
}

// Opening notices
// ------------------------------------------------------------------------

// A space-blocked newcomer remains managed. The notice explains why no new
// tile has appeared, without changing another window's position or focus.
opening_notice_space :: proc(m: ^e.Manager, frontmost_pid: i32) -> ^e.Space {
	if frontmost_pid <= 0 {
		return nil
	}
	for _, w in m.windows {
		// A blocked background app must not leave its warning over another app.
		if w.pid != frontmost_pid {
			continue
		}
		if w.opening.phase == .Pending && w.opening.wait == .Space {
			if s := e.space_by_id(m, w.space); s != nil && s.visible {
				return s
			}
		}
	}
	return nil
}

native_frontmost_pid :: proc() -> i32 {
	front := intrinsics.objc_send(
		^objc.Object,
		workspace(),
		"frontmostApplication",
	)
	return intrinsics.objc_send(i32, front, "processIdentifier")
}

opening_notice_tick :: proc(
	state: ^State,
	frontmost: proc() -> i32 = native_frontmost_pid,
) {
	if len(state.opening_windows) == 0 && state.opening_notice.id == 0 {
		return
	}
	pid := frontmost()
	blocked := opening_notice_space(&state.manager, pid)
	if blocked == nil {
		if state.opening_notice.id != 0 {
			surface_destroy(state, state.opening_notice)
			state.opening_notice = {}
		}
		return
	}
	if state.connection == 0 {
		return
	}
	frame := e.Rect {
		blocked.view.frame.x + max(0, blocked.view.frame.w - 330),
		blocked.view.frame.y + 12,
		316,
		48,
	}
	if state.opening_notice.id != 0 {
		if state.opening_notice.frame != frame &&
		   surface_update(state, state.opening_notice, frame) == "" {
			state.opening_notice.frame = frame
		}
		return
	}
	surface, err := surface_create(
		state,
		frame,
		0,
		(1 << 1) | (1 << 3) | (1 << 9),
		13,
		1,
	)
	if err != "" {
		return
	}
	CGContextSetRGBFillColor(surface.ctx, .98, .95, .86, 1)
	CGContextFillRect(surface.ctx, {0, 0, 316, 48})
	graphics := (^objc.Object)(objc.objc_lookUpClass("NSGraphicsContext"))
	native := intrinsics.objc_send(
		^objc.Object,
		graphics,
		"graphicsContextWithCGContext:flipped:",
		surface.ctx,
		bool(false),
	)
	intrinsics.objc_send(nil, graphics, "saveGraphicsState")
	intrinsics.objc_send(nil, graphics, "setCurrentContext:", native)
	label := cf_string("Needs more room for a new window")
	intrinsics.objc_send(
		nil,
		(^objc.Object)(label),
		"drawInRect:withAttributes:",
		e.Rect{12, 12, 292, 24},
		(^objc.Object)(nil),
	)
	CFRelease(label)
	intrinsics.objc_send(nil, graphics, "restoreGraphicsState")
	CGContextFlush(surface.ctx)
	if surface_update(state, surface, frame) != "" ||
	   SLSSetWindowLevel(state.connection, surface.id, 20) != 0 ||
	   SLSOrderWindow(state.connection, surface.id, 1, 0) != 0 {
		surface_destroy(state, surface); return
	}
	state.opening_notice = surface
}
