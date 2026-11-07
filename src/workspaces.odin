package shoji

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:strings"
import objc "core:sys/darwin/Foundation"
import posix "core:sys/posix"

// Display and Space discovery
// ------------------------------------------------------------------------

Display_Probe :: struct {
	list: proc(state: ^State, ids: []u32, count: ^u32) -> i32,
	spaces: proc(state: ^State) -> Ref,
}
native_display_list :: proc(_: ^State, ids: []u32, count: ^u32) -> i32 {
	return CGGetActiveDisplayList(u32(len(ids)), raw_data(ids), count)
}
native_display_spaces :: proc(state: ^State) -> Ref {
	return SLSCopyManagedDisplaySpaces(state.connection)
}

refresh_displays :: proc(state: ^State) {
	m := &state.manager
	probe := state.display_probe
	if probe.list == nil {
		probe = {native_display_list, native_display_spaces}
	}
	ids: [64]u32
	count: u32
	// A failed observation must not destroy labels, display membership or trees.
	if probe.list(state, ids[:], &count) != 0 ||
	   count == 0 ||
	   count > len(ids) {
		return
	}
	data := probe.spaces(state)
	if data == nil {
		return
	}
	defer CFRelease(data)
	if CFArrayGetCount(data) == 0 {
		return
	}
	for i in 0 ..< CFArrayGetCount(data) {
		entry := CFArrayGetValueAtIndex(data, i)
		spaces := dictionary(entry, "Spaces")
		if spaces == nil || CFArrayGetCount(spaces) == 0 {
			return
		}
		for j in 0 ..< CFArrayGetCount(spaces) {
			if number(dictionary(CFArrayGetValueAtIndex(spaces, j), "id64")) ==
			   0 {
				return
			}
		}
	}
	labels := make(map[u32]string, context.temp_allocator)
	for &d in m.displays {
		labels[d.id] = d.label
		delete(d.uuid)
		delete(d.spaces)
	}
	clear(&m.displays)
	defer {
		for _, label in labels {
			delete(label)
		}
	}
	primary_height := CGDisplayBounds(CGMainDisplayID()).h
	m.main_display = CGMainDisplayID()
	screens := intrinsics.objc_send(^objc.Object, objc.Screen, "screens")
	for id, i in ids[:count] {
		d := Display {
			id           = id,
			index        = u32(i + 1),
			native_index = u32(i + 1),
			frame        = CGDisplayBounds(id),
		}
		d.usable = d.frame
		d.label = labels[id]
		delete_key(&labels, id)
		uuid := CGDisplayCreateUUIDFromDisplayID(id)
		if uuid != nil {
			string := CFUUIDCreateString(nil, uuid)
			CFRelease(uuid)
			if string != nil {
				d.uuid = strings.clone(text(string))
				d.active_space = SLSManagedDisplayGetCurrentSpace(
					state.connection,
					string,
				)
				CFRelease(string)
			}
		}
		for j in 0 ..< intrinsics.objc_send(uint, screens, "count") {
			screen := intrinsics.objc_send(
				^objc.Object,
				screens,
				"objectAtIndex:",
				j,
			)
			description := intrinsics.objc_send(
				^objc.Object,
				screen,
				"deviceDescription",
			)
			key := cf_string("NSScreenNumber")
			number := intrinsics.objc_send(
				^objc.Object,
				description,
				"objectForKey:",
				(^objc.Object)(key),
			)
			CFRelease(key)
			if intrinsics.objc_send(u32, number, "unsignedIntValue") == id {
				r := intrinsics.objc_send(Rect, screen, "visibleFrame")
				d.usable = {r.x, primary_height - r.y - r.h, r.w, r.h}
				break
			}
		}
		append(&m.displays, d)
	}
	order_displays(m)
	seen := make(map[u64]bool, context.temp_allocator)
	index: u32 = 0
	for i in 0 ..< CFArrayGetCount(data) {
		entry := CFArrayGetValueAtIndex(data, i)
		identifier := dictionary(entry, "Display Identifier")
		d: ^Display
		for &display in m.displays {
			if display.uuid == text(identifier) {
				d = &display
				break
			}
		}
		if d == nil {
			continue
		}
		spaces := dictionary(entry, "Spaces")
		if spaces == nil {
			continue
		}
		for j in 0 ..< CFArrayGetCount(spaces) {
			item := CFArrayGetValueAtIndex(spaces, j)
			id := number(dictionary(item, "id64"))
			if id == 0 {
				continue
			}
			index += 1
			seen[id] = true
			s := space_by_id(m, id)
			if s == nil {
				s = add_space(m, id, d.id, index, usable_frame(m, d))
			}
			s.index = index
			s.display = d.id
			s.view.frame = usable_frame(m, d)
			s.visible = d.active_space == id
			s.fullscreen = number(dictionary(item, "type")) == 4
			if s.uuid == "" {
				s.uuid = strings.clone(text(dictionary(item, "uuid")))
			}
			append(&d.spaces, id)
		}
	}
	for i := len(m.spaces) - 1; i >= 0; i -= 1 {
		s := m.spaces[i]
		if !seen[s.id] {
			view_destroy(&s.view)
			delete(s.overrides)
			delete(s.uuid)
			delete(s.label)
			free(s)
			ordered_remove(&m.spaces, i)
		}
	}
	for i in 1 ..< len(m.spaces) {
		for j := i;
		    j > 0 && m.spaces[j - 1].index > m.spaces[j].index;
		    j -= 1 {
			m.spaces[j - 1], m.spaces[j] = m.spaces[j], m.spaces[j - 1]
		}
	}
	active := SLSCopyActiveMenuBarDisplayIdentifier(state.connection)
	if active != nil {
		sid := SLSManagedDisplayGetCurrentSpace(state.connection, active)
		CFRelease(active)
		if sid != m.active_space {
			m.last_space = m.active_space
			m.active_space = sid
		}
	}
}

// Display focus
// ------------------------------------------------------------------------

Display_Focus_Backend :: struct {
	windows: proc(state: ^State) -> []u32,
	focus: proc(state: ^State, window: u32) -> string,
	activate: proc(state: ^State, display: ^Display) -> string,
	warp: proc(state: ^State, point: Point) -> string,
}

native_display_windows :: proc(state: ^State) -> []u32 {
	// WindowServer order chooses the frontmost visible window, independently of BSP order.
	list := CGWindowListCopyWindowInfo(1 | 16, 0)
	if list == nil {
		return nil
	}
	defer CFRelease(list)
	ids := make([dynamic]u32, context.temp_allocator)
	for i in 0 ..< CFArrayGetCount(list) {
		entry := CFArrayGetValueAtIndex(list, i)
		append(&ids, u32(number(dictionary(entry, "kCGWindowNumber"))))
	}
	return ids[:]
}

native_display_focus_window :: proc(state: ^State, window: u32) -> string {
	return perform_native(state, {kind = .Focus, window = window})
}

native_display_activate :: proc(state: ^State, display: ^Display) -> string {
	if display.uuid == "" {
		return "display has no UUID"
	}
	uuid := cf_string(display.uuid)
	defer CFRelease(uuid)
	if SLSSetActiveMenuBarDisplayIdentifier(state.connection, uuid, uuid) !=
	   0 {
		return "could not activate display"
	}
	return ""
}

native_display_warp :: proc(state: ^State, point: Point) -> string {
	if CGWarpMouseCursorPosition(point) != 0 {
		return "could not move cursor to display"
	}
	return ""
}

focus_display :: proc(state: ^State, id: u32) -> string {
	if state.read_only {
		return "window operations are disabled in read-only inspection"
	}
	d := display_by_id(&state.manager, id)
	if d == nil {
		return "could not locate display"
	}
	backend := state.display_focus_backend
	if backend.windows == nil {
		backend = {
			native_display_windows,
			native_display_focus_window,
			native_display_activate,
			native_display_warp,
		}
	}
	window: u32
	for id in backend.windows(state) {
		w := state.manager.windows[id]
		if w != nil &&
		   (w.ordered_in.? or_else true) &&
		   w.display == d.id &&
		   (w.space == d.active_space || w.sticky) &&
		   !w.hidden &&
		   !w.minimized &&
		   !w.scratchpad_hidden {
			window = id
			break
		}
	}
	if window != 0 {
		if err := backend.focus(state, window); err != "" {
			return err
		}
	} else {
		if err := backend.warp(
			state,
			{d.frame.x + d.frame.w / 2, d.frame.y + d.frame.h / 2},
		); err != "" {
			return err
		}
	}
	if err := backend.activate(state, d); err != "" {
		return err
	}
	state.dirty = true
	return ""
}

// Event snapshots and signal delivery
// ------------------------------------------------------------------------

Event :: struct {
	name, app, title: string,
	window, recent_window: u32,
	pid: i32,
	space, recent_space: u64,
	display, recent_display: u32,
	active: bool,
}

Signal_Window :: struct {
	id: u32,
	pid: i32,
	app, title: string,
	frame: Rect,
	space: u64,
	display: u32,
	focused, minimized: bool,
}
signal_window :: proc(w: Window) -> Signal_Window {
	return {
		w.id,
		w.pid,
		w.app,
		w.title,
		w.frame,
		w.space,
		w.display,
		w.focused,
		w.minimized,
	}
}

Snapshot :: struct {
	allocator: mem.Allocator,
	windows: map[u32]Signal_Window,
	spaces: map[u64]u32,
	displays: map[u32]Rect,
	apps: map[i32]string,
	app_hidden: map[i32]bool,
	focused: u32,
	active_space: u64,
	active_display: u32,
}

snapshot :: proc(
	state: ^State,
	allocator: mem.Allocator = context.temp_allocator,
) -> Snapshot {
	result: Snapshot
	snapshot_update(&result, state, allocator)
	return result
}

snapshot_update :: proc(
	result: ^Snapshot,
	state: ^State,
	allocator: mem.Allocator,
) {
	if result.allocator.procedure == nil {
		result^ = Snapshot {
			allocator  = allocator,
			windows    = make(map[u32]Signal_Window, allocator),
			spaces     = make(map[u64]u32, allocator),
			displays   = make(map[u32]Rect, allocator),
			apps       = make(map[i32]string, allocator),
			app_hidden = make(map[i32]bool, allocator),
		}
	}
	result.focused, result.active_space =
		state.manager.focused, state.manager.active_space
	result.active_display = 0
	if s := space_by_id(&state.manager, result.active_space); s != nil {
		result.active_display = s.display
	}
	for id, old in result.windows {
		if state.manager.windows[id] == nil {
			delete(old.app, result.allocator)
			delete(old.title, result.allocator)
			delete_key(&result.windows, id)
		}
	}
	for id, w in state.manager.windows {
		old, exists := result.windows[id]
		value := signal_window(w^)
		value.app, value.title = old.app, old.title
		if !exists || old.app != w.app {
			delete(old.app, result.allocator)
			value.app = strings.clone(w.app, result.allocator)
		}
		if !exists || old.title != w.title {
			delete(old.title, result.allocator)
			value.title = strings.clone(w.title, result.allocator)
		}
		result.windows[id] = value
	}
	clear(&result.spaces); clear(&result.displays); clear(&result.app_hidden)
	for s in state.manager.spaces { result.spaces[s.id] = s.display }
	for d in state.manager.displays { result.displays[d.id] = d.frame }
	for pid, name in result.apps {
		if _, exists := state.applications[pid]; !exists {
			delete(name, result.allocator); delete_key(&result.apps, pid)
		}
	}
	for pid, app in state.applications {
		old, exists := result.apps[pid]
		if !exists || old != app.name {
			delete(old, result.allocator)
			result.apps[pid] = strings.clone(app.name, result.allocator)
		}
		result.app_hidden[pid] = app.hidden
	}
}

snapshot_destroy :: proc(before: ^Snapshot) {
	for _, w in before.windows {
		delete(w.app, before.allocator); delete(w.title, before.allocator)
	}
	for _, name in before.apps { delete(name, before.allocator) }
	delete(before.windows)
	delete(before.spaces)
	delete(before.displays)
	delete(before.apps)
	delete(before.app_hidden)
	before^ = {}
}

observations_destroy :: proc(state: ^State) {
	snapshot_destroy(&state.observed)
	snapshot_destroy(&state.observation_next)
}

observe_changes :: proc(state: ^State) {
	// Commands update desired state between refreshes. Compare against the last
	// completed observation, which owns its strings beyond the per-tick arena.
	// Alternate two owned snapshots. Unchanged strings and map storage survive
	// refreshes; event callbacks still see independent before/after values.
	snapshot_update(&state.observation_next, state, context.allocator)
	dispatch_changes(state, state.observed, state.observation_next)
	state.observed, state.observation_next =
		state.observation_next, state.observed
}

emit :: proc(state: ^State, event: Event) {
	if state.event_sink != nil {
		state.event_sink(state.event_user, event)
	}
	for signal in state.manager.signals {
		if signal.event != event.name {
			continue
		}
		if !filter_matches(signal.app, event.app) ||
		   !filter_matches(signal.title, event.title) {
			continue
		}
		if active, ok := signal.active.?; ok && active != event.active {
			continue
		}
		launch_signal(signal, event)
	}
}

launch_signal :: proc(signal: Signal, event: Event) {
	environment := make([dynamic]cstring, 0, 64, context.temp_allocator)
	overrides := []string {
		fmt.tprintf("SHOJI_WINDOW_ID=%d", event.window),
		fmt.tprintf("SHOJI_RECENT_WINDOW_ID=%d", event.recent_window),
		fmt.tprintf("SHOJI_PROCESS_ID=%d", event.pid),
		fmt.tprintf("SHOJI_SPACE_ID=%d", event.space),
		fmt.tprintf("SHOJI_RECENT_SPACE_ID=%d", event.recent_space),
		fmt.tprintf("SHOJI_DISPLAY_ID=%d", event.display),
		fmt.tprintf("SHOJI_RECENT_DISPLAY_ID=%d", event.recent_display),
	}
	inherited := _NSGetEnviron()^
	for i := 0; inherited[i] != nil; i += 1 {
		entry := string(inherited[i])
		duplicate := false
		for replacement in overrides {
			at := strings.index_byte(replacement, '=')
			if strings.has_prefix(entry, replacement[:at + 1]) {
				duplicate = true
				break
			}
		}
		if !duplicate {
			append(&environment, inherited[i])
		}
	}
	for value in overrides {
		append(
			&environment,
			strings.clone_to_cstring(value, context.temp_allocator),
		)
	}
	append(&environment, nil)
	argv := [4]cstring {
		"/bin/sh",
		"-c",
		strings.clone_to_cstring(signal.action, context.temp_allocator),
		nil,
	}
	pid: posix.pid_t
	if posix.posix_spawn(
		   &pid,
		   "/bin/sh",
		   nil,
		   nil,
		   &argv[0],
		   raw_data(environment),
	   ) !=
	   nil {
		fmt.eprintf("shoji: failed to launch signal '%s'\n", signal.label)
	}
}

window_event :: proc(
	name: string,
	w: Signal_Window,
	recent: u32 = 0,
) -> Event {
	return Event {
		name = name,
		app = w.app,
		title = w.title,
		window = w.id,
		pid = w.pid,
		space = w.space,
		display = w.display,
		active = w.focused,
		recent_window = recent,
	}
}

emit_changes :: proc(state: ^State, before: Snapshot) {
	after := snapshot(state)
	defer snapshot_destroy(&after)
	dispatch_changes(state, before, after)
}

dispatch_changes :: proc(state: ^State, before, after: Snapshot) {
	if after.active_display != 0 &&
	   before.active_display != 0 &&
	   after.active_display != before.active_display {
		state.manager.last_display = before.active_display
	}
	for event in snapshot_changes(before, after) { emit(state, event) }
}

// Event strings borrow their snapshots; dispatch before releasing either one.
snapshot_changes :: proc(before, after: Snapshot) -> [dynamic]Event {
	events := make([dynamic]Event, context.temp_allocator)
	for pid, app in after.apps {
		if _, existed := before.apps[pid]; !existed {
			append(
				&events,
				Event{name = "application_launched", app = app, pid = pid},
			)
		} else if before.app_hidden[pid] != after.app_hidden[pid] {
			append(
				&events,
				Event {
					name = after.app_hidden[pid] \
						? "application_hidden" \
						: "application_visible",
					app = app,
					pid = pid,
				},
			)
		}
	}
	for pid, app in before.apps {
		if _, exists := after.apps[pid]; !exists {
			append(
				&events,
				Event{name = "application_terminated", app = app, pid = pid},
			)
		}
	}
	for id, w in after.windows {
		old, existed := before.windows[id]
		if !existed {
			append(&events, window_event("window_created", w))
			continue
		}
		if old.title != w.title {
			append(&events, window_event("window_title_changed", w))
		}
		if old.frame.x != w.frame.x || old.frame.y != w.frame.y {
			append(&events, window_event("window_moved", w))
		}
		if old.frame.w != w.frame.w || old.frame.h != w.frame.h {
			append(&events, window_event("window_resized", w))
		}
		if old.minimized != w.minimized {
			append(
				&events,
				window_event(
					w.minimized ? "window_minimized" : "window_deminimized",
					w,
				),
			)
		}
	}
	for id, w in before.windows {
		if _, exists := after.windows[id]; !exists {
			append(&events, window_event("window_destroyed", w))
		}
	}
	if after.focused != before.focused {
		if w, exists := after.windows[after.focused]; exists {
			append(&events, window_event("window_focused", w, before.focused))
			old := before.windows[before.focused]
			if old.pid != w.pid {
				append(&events, window_event("application_front_switched", w))
				append(&events, window_event("application_activated", w))
				if old.pid != 0 {
					append(
						&events,
						window_event("application_deactivated", old),
					)
				}
			}
		}
	}
	for id, display in after.spaces {
		if _, exists := before.spaces[id]; !exists {
			append(
				&events,
				Event{name = "space_created", space = id, display = display},
			)
		}
	}
	for id in before.spaces {
		if _, exists := after.spaces[id]; !exists {
			append(&events, Event{name = "space_destroyed", space = id})
		}
	}
	if after.active_space != before.active_space {
		append(
			&events,
			Event {
				name = "space_changed",
				space = after.active_space,
				recent_space = before.active_space,
				display = after.active_display,
			},
		)
	}
	if after.active_display != 0 &&
	   before.active_display != 0 &&
	   after.active_display != before.active_display {
		append(
			&events,
			Event {
				name = "display_changed",
				display = after.active_display,
				recent_display = before.active_display,
				space = after.active_space,
				recent_space = before.active_space,
			},
		)
	}
	for id, frame in after.displays {
		old, existed := before.displays[id]
		if !existed {
			append(&events, Event{name = "display_added", display = id})
			continue
		}
		if old.x != frame.x || old.y != frame.y {
			append(&events, Event{name = "display_moved", display = id})
		}
		if old.w != frame.w || old.h != frame.h {
			append(&events, Event{name = "display_resized", display = id})
		}
	}
	for id in before.displays {
		if _, exists := after.displays[id]; !exists {
			append(&events, Event{name = "display_removed", display = id})
		}
	}
	return events
}
