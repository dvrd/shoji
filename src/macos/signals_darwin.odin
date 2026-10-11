package macos

import e "../engine"
import "core:fmt"
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

Snapshot :: struct {
	windows:      map[u32]e.Window,
	spaces:       map[u64]bool,
	displays:     map[u32]e.Rect,
	apps:         map[i32]string,
	app_hidden:   map[i32]bool,
	focused:      u32,
	active_space: u64,
}

snapshot :: proc(state: ^State) -> Snapshot {
	result := Snapshot {
		windows      = make(map[u32]e.Window, context.temp_allocator),
		spaces       = make(map[u64]bool, context.temp_allocator),
		displays     = make(map[u32]e.Rect, context.temp_allocator),
		apps         = make(map[i32]string, context.temp_allocator),
		app_hidden   = make(map[i32]bool, context.temp_allocator),
		focused      = state.manager.focused,
		active_space = state.manager.active_space,
	}
	for id, w in state.manager.windows {
		copy := w^
		copy.app = strings.clone(w.app, context.temp_allocator)
		copy.title = strings.clone(w.title, context.temp_allocator)
		result.windows[id] = copy
	}
	for s in state.manager.spaces {
		result.spaces[s.id] = true
	}
	for d in state.manager.displays {
		result.displays[d.id] = d.frame
	}
	for pid, app in state.applications {
		result.apps[pid] = strings.clone(app.name, context.temp_allocator)
		result.app_hidden[pid] = app.hidden
	}
	return result
}

emit :: proc(state: ^State, event: Event) {
	if state.event_sink != nil {state.event_sink(state.event_user, event)}
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
		environment := make([dynamic]cstring, 0, 64, context.temp_allocator)
		overrides := []string {
			fmt.tprintf("YABAI_WINDOW_ID=%d", event.window),
			fmt.tprintf("YABAI_RECENT_WINDOW_ID=%d", event.recent_window),
			fmt.tprintf("YABAI_PROCESS_ID=%d", event.pid),
			fmt.tprintf("YABAI_SPACE_ID=%d", event.space),
			fmt.tprintf("YABAI_RECENT_SPACE_ID=%d", event.recent_space),
			fmt.tprintf("YABAI_DISPLAY_ID=%d", event.display),
			fmt.tprintf("YABAI_RECENT_DISPLAY_ID=%d", event.recent_display),
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
			append(&environment, strings.clone_to_cstring(value, context.temp_allocator))
		}
		append(&environment, nil)
		argv := [4]cstring {
			"/bin/sh",
			"-c",
			strings.clone_to_cstring(signal.action, context.temp_allocator),
			nil,
		}
		pid: posix.pid_t
		if posix.posix_spawn(&pid, "/bin/sh", nil, nil, &argv[0], raw_data(environment)) != nil {
			fmt.eprintf("shoji: failed to launch signal '%s'\n", signal.label)
		}
	}
}

emit_window :: proc(state: ^State, name: string, w: e.Window, recent: u32 = 0) {
	emit(
		state,
		Event {
			name = name,
			app = w.app,
			title = w.title,
			window = w.id,
			pid = w.pid,
			space = w.space,
			display = w.display,
			active = w.focused,
			recent_window = recent,
		},
	)
}

emit_changes :: proc(state: ^State, before: Snapshot) {
	m := &state.manager
	for pid, app in state.applications {
		if _, existed := before.apps[pid]; !existed {
			emit(state, Event{name = "application_launched", app = app.name, pid = pid})
		} else if before.app_hidden[pid] != app.hidden {
			emit(
				state,
				Event {
					name = app.hidden ? "application_hidden" : "application_visible",
					app = app.name,
					pid = pid,
				},
			)
		}
	}
	for pid, app in before.apps {
		if _, exists := state.applications[pid]; !exists {
			emit(state, Event{name = "application_terminated", app = app, pid = pid})
		}
	}
	for id, w in m.windows {
		old, existed := before.windows[id]
		if !existed {
			emit_window(state, "window_created", w^)
			continue
		}
		if old.title != w.title {
			emit_window(state, "window_title_changed", w^)
		}
		if old.frame.x != w.frame.x || old.frame.y != w.frame.y {
			emit_window(state, "window_moved", w^)
		}
		if old.frame.w != w.frame.w || old.frame.h != w.frame.h {
			emit_window(state, "window_resized", w^)
		}
		if old.minimized != w.minimized {
			emit_window(state, w.minimized ? "window_minimized" : "window_deminimized", w^)
		}
	}
	for id, w in before.windows {
		if _, exists := m.windows[id]; !exists {
			emit_window(state, "window_destroyed", w)
		}
	}
	if m.focused != before.focused {
		if w := m.windows[m.focused]; w != nil {
			emit_window(state, "window_focused", w^, before.focused)
			old := before.windows[before.focused]
			if old.pid != w.pid {
				emit_window(state, "application_front_switched", w^)
				emit_window(state, "application_activated", w^)
				if old.pid != 0 {
					emit_window(state, "application_deactivated", old)
				}
			}
		}
	}
	for s in m.spaces {
		if !before.spaces[s.id] {
			emit(state, Event{name = "space_created", space = s.id, display = s.display})
		}
	}
	for id in before.spaces {
		if e.space_by_id(m, id) == nil {
			emit(state, Event{name = "space_destroyed", space = id})
		}
	}
	if m.active_space != before.active_space {
		old := e.space_by_id(m, before.active_space)
		fresh := e.space_by_id(m, m.active_space)
		if old != nil &&
		   fresh != nil &&
		   old.display != fresh.display {m.last_display = old.display}
		emit(
			state,
			Event {
				name = "space_changed",
				space = m.active_space,
				recent_space = before.active_space,
			},
		)
	}
	for d in m.displays {
		old, existed := before.displays[d.id]
		if !existed {
			emit(state, Event{name = "display_added", display = d.id})
			continue
		}
		if old.x != d.frame.x || old.y != d.frame.y {
			emit(state, Event{name = "display_moved", display = d.id})
		}
		if old.w != d.frame.w || old.h != d.frame.h {
			emit(state, Event{name = "display_resized", display = d.id})
		}
	}
	for id in before.displays {
		if e.display_by_id(m, id) == nil {
			emit(state, Event{name = "display_removed", display = id})
		}
	}
}
