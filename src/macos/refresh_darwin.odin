package macos

import e "../engine"
import "base:intrinsics"
import "core:fmt"
import "core:strings"
import objc "core:sys/darwin/Foundation"

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
	defer {state.opening_collecting = false}
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
			if w := m.windows[id]; w != nil && (w.opening.phase == .Pending || w.opening.phase == .Opening) && w.opening.focus_superseded {
				if replacement := m.windows[w.opening.focus_replacement]; replacement != nil {
					if e.perform(m, {kind = .Focus_Without_Raise, window = replacement.id}) == "" {id = replacement.id}
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
