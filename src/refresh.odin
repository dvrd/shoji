package shoji

import "base:intrinsics"
import "core:fmt"
import "core:strings"
import objc "core:sys/darwin/Foundation"
import "core:time"
import layout "layout"

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
			if err := apply_window_shadows(&state.manager); err != "" {
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
	space: u64,
	deadline, next_attempt: time.Time,
}

remove_observed_window :: proc(state: ^State, id: u32) {
	m := &state.manager
	if w := m.windows[id]; w != nil && m.focused == id && !state.read_only {
		if s := space_by_id(m, w.space); s != nil && s.visible && s.view.layout == .Scroll {
			now := time.now()
			state.close_focus = {
				space = s.id, deadline = time.time_add(now, 2 * time.Second),
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
			if w == nil || !layout_admitted(w) || w.space != s.id ||
			   (n.column_tabbed && id != n.order[0]) { continue }
			r := layout.scroll_window_frame(v, n, id, false)
			width := min(r.x + r.w, viewport.x + viewport.w) - max(r.x, viewport.x)
			height := min(r.y + r.h, viewport.y + viewport.h) - max(r.y, viewport.y)
			if width <= 0 || height <= 0 { continue }
			area := width * height; preferred := id == v.scroll.focused
			if best == 0 || (preferred && !best_preferred) ||
			   (preferred == best_preferred && area > best_area) {
				best, best_area, best_preferred = id, area, preferred
			}
		}
	}
	return best
}

close_focus_tick :: proc(state: ^State, now: time.Time = {}) {
	p := &state.close_focus; m := &state.manager
	if p.space == 0 { return }
	now := now
	if (now == time.Time{}) { now = time.now() }
	// Let native focus settle first. A later focus or Space change wins over
	// this fallback, including when several windows disappear in one refresh.
	if state.read_only || m.active_space != p.space || m.windows[m.focused] != nil ||
	   time.diff(now, p.deadline) <= 0 { p^ = {}; return }
	if m.suspended || m.gesture_active || state.mouse.drag.window != 0 ||
	   time.diff(now, p.next_attempt) > 0 { return }
	s := space_by_id(m, p.space)
	if s == nil || !s.visible || s.view.layout != .Scroll { p^ = {}; return }
	target := close_focus_candidate(m, s)
	if target == 0 { return }
	p.next_attempt = time.time_add(now, 100 * time.Millisecond)
	response := execute(m, {"window", fmt.tprintf("%d", target), "--focus"})
	if response.failed { state.dirty = true; return }
	motion_trace_record(&m.motion_trace, {kind = "close-focus-recovered", window = target, space = s.id})
	p^ = {}
}

focus_owner :: proc(m: ^Manager, pid: i32, ancestry: []u32) -> u32 {
	id := len(ancestry) > 0 ? ancestry[0] : 0
	for candidate in ancestry {
		if w := m.windows[candidate]; w != nil && w.pid == pid { id = candidate }
	}
	return id
}

native_focus_owner :: proc(state: ^State, pid: i32, focused: Ref) -> u32 {
	// Sheets can own keyboard focus without appearing in AXWindows. Follow
	// their parent chain to the tracked document that owns the layout slot.
	ids: [16]u32; count := 0
	element := focused; owned := false
	defer { if owned && element != nil { CFRelease(element) } }
	for _ in 0 ..< len(ids) {
		if element == nil { break }
		id: u32
		if _AXUIElementGetWindow(element, &id) == 0 && id != 0 {
			ids[count] = id; count += 1
		}
		parent := attribute(element, "AXParent")
		if owned { CFRelease(element) }
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
	front := intrinsics.objc_send(
		^objc.Object,
		workspace(),
		"frontmostApplication",
	)
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
				if replacement := m.windows[w.opening.focus_replacement];
				   replacement != nil {
					if perform(
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
