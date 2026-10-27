package macos

import e "../engine"
import "core:fmt"
import "core:mem"
import "core:strings"
import posix "core:sys/posix"

Event :: struct {
	name, app, title:        string,
	window, recent_window:   u32,
	pid:                     i32,
	space, recent_space:     u64,
	display, recent_display: u32,
	active:                  bool,
}

Signal_Window :: struct {
	id: u32,
	pid: i32,
	app, title: string,
	frame: e.Rect,
	space: u64,
	display: u32,
	focused, minimized: bool,
}
signal_window :: proc(w: e.Window) -> Signal_Window {
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
	displays: map[u32]e.Rect,
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
	result := Snapshot {
		allocator    = allocator,
		windows      = make(map[u32]Signal_Window, allocator),
		spaces       = make(map[u64]u32, allocator),
		displays     = make(map[u32]e.Rect, allocator),
		apps         = make(map[i32]string, allocator),
		app_hidden   = make(map[i32]bool, allocator),
		focused      = state.manager.focused,
		active_space = state.manager.active_space,
	}
	if s := e.space_by_id(&state.manager, result.active_space); s != nil {
		result.active_display = s.display
	}
	for id, w in state.manager.windows {
		copy := signal_window(w^)
		copy.app = strings.clone(w.app, allocator)
		copy.title = strings.clone(w.title, allocator)
		result.windows[id] = copy
	}
	for s in state.manager.spaces {
		result.spaces[s.id] = s.display
	}
	for d in state.manager.displays {
		result.displays[d.id] = d.frame
	}
	for pid, app in state.applications {
		result.apps[pid] = strings.clone(app.name, allocator)
		result.app_hidden[pid] = app.hidden
	}
	return result
}

snapshot_destroy :: proc(before: ^Snapshot) {
	for _, w in before.windows {delete(w.app, before.allocator);delete(w.title, before.allocator)}
	for _, name in before.apps {delete(name, before.allocator)}
	delete(before.windows)
	delete(before.spaces)
	delete(before.displays)
	delete(before.apps)
	delete(before.app_hidden)
	before^ = {}
}

observe_changes :: proc(state: ^State) {
	// Commands update desired state between refreshes. Compare against the last
	// completed observation, which owns its strings beyond the per-tick arena.
	after := snapshot(state, context.allocator)
	dispatch_changes(state, state.observed, after)
	snapshot_destroy(&state.observed)
	state.observed = after
}

emit :: proc(state: ^State, event: Event) {
	if state.event_sink != nil {
		state.event_sink(state.event_user, event)
	}
	for signal in state.manager.signals {
		if signal.event != event.name {
			continue
		}
		if !e.filter_matches(signal.app, event.app) ||
		   !e.filter_matches(signal.title, event.title) {
			continue
		}
		if active, ok := signal.active.?; ok && active != event.active {
			continue
		}
		launch_signal(signal, event)
	}
}

launch_signal :: proc(signal: e.Signal, event: Event) {
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
