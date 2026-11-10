package shoji

import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strconv"
import "core:strings"
import objc "core:sys/darwin/Foundation"
import posix "core:sys/posix"
import layout "layout"

// Display and Space discovery
// ------------------------------------------------------------------------

Display_Probe :: struct {
	list:   proc(state: ^State, ids: []u32, count: ^u32) -> i32,
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
	if probe.list(state, ids[:], &count) != 0 || count == 0 || count > len(ids) {
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
			if number(dictionary(CFArrayGetValueAtIndex(spaces, j), "id64")) == 0 {
				return
			}
		}
	}
	seen_displays: [8]Display_Seen
	seen_count := 0
	for &d in m.displays {
		if seen_count >= len(seen_displays) {
			break
		}
		seen_displays[seen_count] = {d.id, strings.clone(d.uuid), d.active_space}
		seen_count += 1
	}
	defer {
		for i in 0 ..< seen_count {delete(seen_displays[i].uuid)}
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
				d.active_space = SLSManagedDisplayGetCurrentSpace(state.connection, string)
				CFRelease(string)
			}
		}
		for j in 0 ..< intrinsics.objc_send(uint, screens, "count") {
			screen := intrinsics.objc_send(^objc.Object, screens, "objectAtIndex:", j)
			description := intrinsics.objc_send(^objc.Object, screen, "deviceDescription")
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
	existed := make(map[u64]bool, context.temp_allocator)
	for s in m.spaces {existed[s.id] = true}
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
	workspace_adopt_new(m, existed)
	if m.workspace_hotplug {
		for s in m.spaces {
			if display_by_id(m, s.display) == nil {
				seen[s.id] = true
			}
		}
	}
	for i := len(m.spaces) - 1; i >= 0; i -= 1 {
		s := m.spaces[i]
		if s.ephemeral {
			continue
		}
		if !seen[s.id] {
			layout.view_destroy(&s.view)
			delete(s.overrides)
			delete(s.uuid)
			delete(s.label)
			delete(s.home_uuid)
			free(s)
			ordered_remove(&m.spaces, i)
		}
	}
	for i in 1 ..< len(m.spaces) {
		for j := i; j > 0 && m.spaces[j - 1].index > m.spaces[j].index; j -= 1 {
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
	workspace_hotplug_finish(m, seen_displays[:seen_count])
}

// Display focus
// ------------------------------------------------------------------------

Display_Focus_Backend :: struct {
	windows:  proc(state: ^State) -> []u32,
	focus:    proc(state: ^State, window: u32) -> string,
	activate: proc(state: ^State, display: ^Display) -> string,
	warp:     proc(state: ^State, point: Point) -> string,
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
	if SLSSetActiveMenuBarDisplayIdentifier(state.connection, uuid, uuid) != 0 {
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
		if err := backend.warp(state, {d.frame.x + d.frame.w / 2, d.frame.y + d.frame.h / 2});
		   err != "" {
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
	name, app, title:        string,
	window, recent_window:   u32,
	pid:                     i32,
	space, recent_space:     u64,
	display, recent_display: u32,
	active:                  bool,
}

Signal_Window :: struct {
	id:                 u32,
	pid:                i32,
	app, title:         string,
	frame:              Rect,
	space:              u64,
	display:            u32,
	focused, minimized: bool,
}
signal_window :: proc(w: Window) -> Signal_Window {
	return {w.id, w.pid, w.app, w.title, w.frame, w.space, w.display, w.focused, w.minimized}
}

Snapshot :: struct {
	allocator:      mem.Allocator,
	windows:        map[u32]Signal_Window,
	spaces:         map[u64]u32,
	displays:       map[u32]Rect,
	apps:           map[i32]string,
	app_hidden:     map[i32]bool,
	focused:        u32,
	active_space:   u64,
	active_display: u32,
}

snapshot :: proc(state: ^State, allocator: mem.Allocator = context.temp_allocator) -> Snapshot {
	result: Snapshot
	snapshot_update(&result, state, allocator)
	return result
}

snapshot_update :: proc(result: ^Snapshot, state: ^State, allocator: mem.Allocator) {
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
	result.focused, result.active_space = state.manager.focused, state.manager.active_space
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
	for s in state.manager.spaces {result.spaces[s.id] = s.display}
	for d in state.manager.displays {result.displays[d.id] = d.frame}
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
	for _, name in before.apps {delete(name, before.allocator)}
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
	state.observed, state.observation_next = state.observation_next, state.observed
}

emit :: proc(state: ^State, event: Event) {
	if state.event_sink != nil {
		state.event_sink(state.event_user, event)
	}
	for signal in state.manager.signals {
		if signal.event != event.name {
			continue
		}
		if !filter_matches(signal.app, event.app) || !filter_matches(signal.title, event.title) {
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

window_event :: proc(name: string, w: Signal_Window, recent: u32 = 0) -> Event {
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
	for event in snapshot_changes(before, after) {emit(state, event)}
}

// Event strings borrow their snapshots; dispatch before releasing either one.
snapshot_changes :: proc(before, after: Snapshot) -> [dynamic]Event {
	events := make([dynamic]Event, context.temp_allocator)
	for pid, app in after.apps {
		if _, existed := before.apps[pid]; !existed {
			append(&events, Event{name = "application_launched", app = app, pid = pid})
		} else if before.app_hidden[pid] != after.app_hidden[pid] {
			append(
				&events,
				Event {
					name = after.app_hidden[pid] ? "application_hidden" : "application_visible",
					app = app,
					pid = pid,
				},
			)
		}
	}
	for pid, app in before.apps {
		if _, exists := after.apps[pid]; !exists {
			append(&events, Event{name = "application_terminated", app = app, pid = pid})
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
				window_event(w.minimized ? "window_minimized" : "window_deminimized", w),
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
					append(&events, window_event("application_deactivated", old))
				}
			}
		}
	}
	for id, display in after.spaces {
		if _, exists := before.spaces[id]; !exists {
			append(&events, Event{name = "space_created", space = id, display = display})
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

// Opt-in Niri-style workspaces. Off unless dynamic_workspaces is set.
// An empty unnamed workspace is a local stand-in until Dock reports the real
// Space. Stand-in ids come from workspace_seq and are never passed to
// Space_Destroy, because Dock did not assign them. Space_Create is anchored
// on a real Space. The next display refresh adopts Dock's id and drops the
// stand-in. Named spaces (a label) and explicitly inserted spaces stay.

WORKSPACE_PENDING_MAX :: 8
WORKSPACE_SEQ_BASE :: u64(0x5e0000000001)
WORKSPACE_LIST_MAX :: 64
OVERVIEW_SPACES :: 32
OVERVIEW_WINDOWS :: 128
OVERVIEW_INSET :: 36.0
OVERVIEW_GAP :: 12.0
OVERVIEW_BAND_H :: 160.0

Display_Seen :: struct {
	id:     u32,
	uuid:   string,
	active: u64,
}

Overview_Window :: struct {
	id:       u32,
	space:    u64,
	display:  u32,
	floating: bool,
	frame:    Rect,
}

Overview_Tree :: struct {
	space:  u64,
	root:   ^layout.Node,
	scroll: layout.Scroll_State,
}

Overview_Band :: struct {
	space: u64,
	frame: Rect,
}

Overview :: struct {
	active:                  bool,
	display:                 u32,
	space:                   u64,
	window:                  u32,
	pan:                     f64,
	focus_was:               u32,
	space_was:               u64,
	windows:                 [OVERVIEW_WINDOWS]Overview_Window,
	window_count:            int,
	trees:                   [OVERVIEW_SPACES]Overview_Tree,
	tree_count:              int,
	bands:                   [OVERVIEW_SPACES]Overview_Band,
	band_count:              int,
	inserted:                [8]u64,
	inserted_count:          int,
	pressing:                bool,
	press_window:            u32,
	press_since:             f64,
	dragging:                u32,
	edge_direction:          int,
	edge_entered, edge_last: f64,
}

workspace_collect :: proc(m: ^Manager, display: u32, tiled: bool, out: []^Space) -> int {
	n := 0
	for s in m.spaces {
		if s.display != display || (tiled && s.fullscreen) {
			continue
		}
		if n >= len(out) {
			break
		}
		out[n] = s
		n += 1
	}
	return n
}

workspace_occupied :: proc(m: ^Manager, s: ^Space) -> bool {
	if s == nil {
		return false
	}
	for _, w in m.windows {
		if w == nil || w.space != s.id || w.floating || w.hidden {
			continue
		}
		if w.minimized || w.fullscreen {
			return true
		}
		if layout.find(s.view.root, w.id) != nil || layout_admitted(w) {
			return true
		}
	}
	return false
}

workspace_reindex :: proc(m: ^Manager) {
	for &d in m.displays {clear(&d.spaces)}
	for space, i in m.spaces {
		space.index = u32(i + 1)
		if d := display_by_id(m, space.display); d != nil {
			append(&d.spaces, space.id)
		}
	}
}

workspace_single_visible :: proc(m: ^Manager) {
	if active := space_by_id(m, m.active_space); active != nil {
		if d := display_by_id(m, active.display); d != nil {
			d.active_space = active.id
		}
	}
	for &d in m.displays {
		chosen := d.active_space
		if s := space_by_id(m, chosen); s == nil || s.display != d.id {
			chosen = 0
			for s in m.spaces {
				if s.display == d.id {
					chosen = s.id; break
				}
			}
			d.active_space = chosen
		}
		for s in m.spaces {
			if s.display == d.id {
				s.visible = s.id == chosen
			}
		}
	}
}

workspace_pending_get :: proc(m: ^Manager, display: u32) -> u64 {
	for i in 0 ..< m.workspace_pending_count {
		if m.workspace_pending_display[i] == display {
			return m.workspace_pending_space[i]
		}
	}
	return 0
}

workspace_pending_set :: proc(m: ^Manager, display: u32, space: u64) {
	for i in 0 ..< m.workspace_pending_count {
		if m.workspace_pending_display[i] == display {
			m.workspace_pending_space[i] = space
			return
		}
	}
	if m.workspace_pending_count >= WORKSPACE_PENDING_MAX {
		return
	}
	i := m.workspace_pending_count
	m.workspace_pending_display[i] = display
	m.workspace_pending_space[i] = space
	m.workspace_pending_count += 1
}

workspace_pending_clear_space :: proc(m: ^Manager, space: u64) {
	for i in 0 ..< m.workspace_pending_count {
		if m.workspace_pending_space[i] != space {
			continue
		}
		last := m.workspace_pending_count - 1
		m.workspace_pending_display[i] = m.workspace_pending_display[last]
		m.workspace_pending_space[i] = m.workspace_pending_space[last]
		m.workspace_pending_count = last
		return
	}
}

workspace_free_space :: proc(m: ^Manager, s: ^Space) {
	if s == nil {
		return
	}
	workspace_pending_clear_space(m, s.id)
	for i := len(m.spaces) - 1; i >= 0; i -= 1 {
		if m.spaces[i] != s {
			continue
		}
		ordered_remove(&m.spaces, i)
		break
	}
	layout.view_destroy(&s.view)
	delete(s.overrides)
	delete(s.uuid)
	delete(s.label)
	delete(s.home_uuid)
	free(s)
}

workspace_neighbor :: proc(m: ^Manager, s: ^Space, direction: int, tiled: bool = true) -> ^Space {
	if s == nil || direction == 0 {
		return nil
	}
	buf: [WORKSPACE_LIST_MAX]^Space
	n := workspace_collect(m, s.display, tiled, buf[:])
	for _, i in buf[:n] {
		if buf[i] != s {
			continue
		}
		j := i + direction
		if j < 0 || j >= n {
			return nil
		}
		return buf[j]
	}
	return nil
}

workspace_focus :: proc(m: ^Manager, s: ^Space) -> string {
	if s == nil {
		return "could not locate space"
	}
	if err := perform(m, {kind = .Space_Focus, space = s.id}); err != "" {
		return err
	}
	if m.active_space != s.id {
		m.last_space = m.active_space
		m.active_space = s.id
	}
	workspace_single_visible(m)
	return ""
}

workspace_place_after :: proc(m: ^Manager, s, anchor: ^Space) {
	if s == nil || anchor == nil || s == anchor {
		return
	}
	from := -1
	for space, i in m.spaces {
		if space == s {
			from = i; break
		}
	}
	if from < 0 {
		return
	}
	ordered_remove(&m.spaces, from)
	at := len(m.spaces)
	for space, i in m.spaces {
		if space == anchor {
			at = i + 1; break
		}
	}
	append(&m.spaces, nil)
	for j := len(m.spaces) - 1; j > at; j -= 1 {m.spaces[j] = m.spaces[j - 1]}
	m.spaces[at] = s
}

workspace_create_after :: proc(m: ^Manager, anchor: ^Space) -> (^Space, string) {
	if anchor == nil {
		return nil, "could not locate space"
	}
	id := m.workspace_seq
	if id < WORKSPACE_SEQ_BASE {
		id = WORKSPACE_SEQ_BASE
	}
	for space_by_id(m, id) != nil {id += 1}
	m.workspace_seq = id + 1
	s := add_space(m, id, anchor.display, anchor.index, anchor.view.frame)
	s.ephemeral = true
	s.view.layout = anchor.view.layout
	s.view.gap = anchor.view.gap
	s.view.frame = anchor.view.frame
	workspace_place_after(m, s, anchor)
	workspace_reindex(m)
	real := anchor
	if real.ephemeral {
		buf: [WORKSPACE_LIST_MAX]^Space
		n := workspace_collect(m, anchor.display, true, buf[:])
		real = nil
		for i := n - 1; i >= 0; i -= 1 {
			if buf[i] != s && !buf[i].ephemeral {
				real = buf[i]; break
			}
		}
	}
	if real != nil && !real.ephemeral {
		if err := perform(m, {kind = .Space_Create, space = real.id}); err != "" {
			workspace_free_space(m, s)
			workspace_reindex(m)
			return nil, err
		}
		workspace_pending_set(m, anchor.display, s.id)
	}
	return s, ""
}

workspace_move_floats :: proc(m: ^Manager, from, to: ^Space) {
	if from == nil || to == nil {
		return
	}
	for _, w in m.windows {
		if w == nil || w.space != from.id {
			continue
		}
		layout.remove(&from.view, w.id)
		w.space, w.display = to.id, to.display
		if layout_admitted(w) {
			layout.add(&to.view, w.id, 0)
		}
	}
}

workspace_destroy_space :: proc(m: ^Manager, s, fallback: ^Space) -> string {
	if s == nil {
		return ""
	}
	if !s.ephemeral {
		if err := perform(m, {kind = .Space_Destroy, space = s.id}); err != "" {
			return err
		}
	}
	if m.active_space == s.id && fallback != nil {
		if err := workspace_focus(m, fallback); err != "" {
			return err
		}
	}
	workspace_move_floats(m, s, fallback)
	workspace_free_space(m, s)
	workspace_reindex(m)
	return ""
}

workspace_reconcile :: proc(m: ^Manager) {
	if !m.dynamic_workspaces || m.workspace_reconciling || m.overview.active {
		return
	}
	m.workspace_reconciling = true
	defer m.workspace_reconciling = false
	displays: [16]u32
	count := 0
	for d in m.displays {
		if count >= len(displays) {
			break
		}
		displays[count] = d.id
		count += 1
	}
	for i in 0 ..< count {workspace_reconcile_display(m, displays[i])}
}

workspace_reconcile_display :: proc(m: ^Manager, display: u32) {
	for {
		buf: [WORKSPACE_LIST_MAX]^Space
		n := workspace_collect(m, display, true, buf[:])
		if n == 0 {
			return
		}
		last := buf[n - 1]
		keeper: ^Space
		if !workspace_occupied(m, last) && last.label == "" && !last.kept {
			keeper = last
		}
		victim: ^Space
		fallback: ^Space
		for i in 0 ..< n {
			s := buf[i]
			if s == keeper || s.label != "" || s.kept || workspace_occupied(m, s) {
				continue
			}
			if n <= 1 {
				break
			}
			victim = s
			if keeper != nil && keeper != s {
				fallback = keeper
			}
			if fallback == nil {
				for j in 0 ..< n {
					if buf[j] != s {
						fallback = buf[j]; break
					}
				}
			}
			break
		}
		if victim == nil {
			break
		}
		if err := workspace_destroy_space(m, victim, fallback); err != "" {
			return
		}
	}
	buf: [WORKSPACE_LIST_MAX]^Space
	n := workspace_collect(m, display, true, buf[:])
	if n == 0 {
		return
	}
	last := buf[n - 1]
	if workspace_occupied(m, last) || last.label != "" || last.kept {
		// The pending stand-in is the one Dock will adopt. Keep that id once a
		// window lands on it, and still append a new empty trailer.
		pending_id := workspace_pending_get(m, display)
		pending := space_by_id(m, pending_id)
		if pending != nil &&
		   pending.ephemeral &&
		   !workspace_occupied(m, pending) &&
		   pending.label == "" &&
		   !pending.kept {
			return
		}
		created, _ := workspace_create_after(m, last)
		if pending != nil && pending.ephemeral && created != nil {
			workspace_pending_set(m, display, pending.id)
		}
	}
}

workspace_drop_ephemeral :: proc(m: ^Manager) {
	for {
		found: ^Space
		for s in m.spaces {
			if s.ephemeral {
				found = s; break
			}
		}
		if found == nil {
			break
		}
		fallback: ^Space
		for s in m.spaces {
			if s.display == found.display && s != found && !s.ephemeral {
				fallback = s; break
			}
		}
		workspace_move_floats(m, found, fallback)
		if m.active_space == found.id && fallback != nil {
			workspace_focus(m, fallback)
		}
		workspace_free_space(m, found)
	}
	m.workspace_pending_count = 0
	workspace_reindex(m)
}

workspace_adopt_space :: proc(m: ^Manager, real: ^Space) {
	if real == nil || real.ephemeral {
		return
	}
	pending := workspace_pending_get(m, real.display)
	eph := space_by_id(m, pending)
	if eph == nil || !eph.ephemeral {
		if pending != 0 {
			workspace_pending_clear_space(m, pending)
		}
		return
	}
	real.kept = eph.kept
	for _, w in m.windows {
		if w == nil || w.space != eph.id {
			continue
		}
		layout.remove(&eph.view, w.id)
		w.space, w.display = real.id, real.display
		if layout_admitted(w) {
			layout.add(&real.view, w.id, 0)
		}
	}
	if m.active_space == eph.id {
		m.active_space = real.id
		if d := display_by_id(m, real.display); d != nil {
			d.active_space = real.id
		}
	}
	workspace_free_space(m, eph)
	workspace_reindex(m)
}

workspace_adopt_new :: proc(m: ^Manager, existed: map[u64]bool) {
	fresh: [16]^Space
	n := 0
	for s in m.spaces {
		if existed[s.id] || s.ephemeral {
			continue
		}
		if n >= len(fresh) {
			break
		}
		fresh[n] = s
		n += 1
	}
	for i in 0 ..< n {workspace_adopt_space(m, fresh[i])}
}

workspace_follow :: proc(m: ^Manager, s: ^Space) {
	if d := display_by_id(m, s.display); d != nil {
		s.view.frame = usable_frame(m, d)
	}
	for _, w in m.windows {
		if w != nil && w.space == s.id {
			w.display = s.display
		}
	}
}

workspace_migrate_away :: proc(m: ^Manager, id: u32, uuid: string) {
	fallback: ^Display
	for &d in m.displays {
		if d.id == id {
			continue
		}
		if fallback == nil || d.id == m.main_display {
			fallback = &d
		}
	}
	if fallback == nil {
		return
	}
	for s in m.spaces {
		if s.display != id {
			continue
		}
		if s.home_uuid == "" && uuid != "" {
			s.home_uuid = strings.clone(uuid)
		}
		s.home_visible = s.visible || s.id == m.active_space
		s.display = fallback.id
		workspace_follow(m, s)
	}
}

workspace_migrate_home :: proc(m: ^Manager, d: ^Display) {
	if d == nil || d.uuid == "" {
		return
	}
	for s in m.spaces {
		if s.home_uuid != d.uuid {
			continue
		}
		visible := s.home_visible
		s.display = d.id
		s.home_visible = false
		delete(s.home_uuid)
		s.home_uuid = ""
		workspace_follow(m, s)
		if visible {
			d.active_space = s.id
		}
	}
}

workspace_unplug :: proc(m: ^Manager, id: u32) -> string {
	d := display_by_id(m, id)
	if d == nil {
		return "could not locate display"
	}
	others := 0
	for other in m.displays {
		if other.id != id {
			others += 1
		}
	}
	if others == 0 {
		return "cannot unplug the only display"
	}
	uuid := strings.clone(d.uuid)
	defer delete(uuid)
	workspace_migrate_away(m, id, uuid)
	for i := len(m.displays) - 1; i >= 0; i -= 1 {
		if m.displays[i].id != id {
			continue
		}
		delete(m.displays[i].uuid)
		delete(m.displays[i].label)
		delete(m.displays[i].spaces)
		ordered_remove(&m.displays, i)
	}
	workspace_reindex(m)
	workspace_single_visible(m)
	return ""
}

workspace_replug :: proc(m: ^Manager, d: Display) -> string {
	if d.id == 0 {
		return "could not locate display"
	}
	if display_by_id(m, d.id) != nil {
		return "display already exists"
	}
	append(&m.displays, d)
	added := display_by_id(m, d.id)
	workspace_migrate_home(m, added)
	workspace_reindex(m)
	workspace_single_visible(m)
	return ""
}

workspace_hotplug_finish :: proc(m: ^Manager, before: []Display_Seen) {
	if m.workspace_hotplug {
		for old in before {
			if display_by_id(m, old.id) != nil {
				continue
			}
			workspace_migrate_away(m, old.id, old.uuid)
		}
		for &d in m.displays {workspace_migrate_home(m, &d)}
		workspace_reindex(m)
		workspace_single_visible(m)
	}
	if m.dynamic_workspaces {
		workspace_reconcile(m)
	}
}

workspace_vertical :: proc(m: ^Manager, s: ^Space, operand: string) -> string {
	if s == nil {
		return "could not locate space"
	}
	switch operand {
	case "up", "down":
		next := workspace_neighbor(m, s, operand == "down" ? 1 : -1)
		if next == nil {
			return ""
		}
		return workspace_focus(m, next)
	case "back":
		return workspace_focus(m, space_by_id(m, m.last_space))
	}
	index, ok := strconv.parse_int(operand)
	if !ok || index < 1 {
		return "vertical expects up, down, back, or a workspace index"
	}
	buf: [WORKSPACE_LIST_MAX]^Space
	n := workspace_collect(m, s.display, true, buf[:])
	if index > n {
		return "could not locate space"
	}
	return workspace_focus(m, buf[index - 1])
}

workspace_retarget :: proc(m: ^Manager, w: ^Window, target: ^Space) -> string {
	if w == nil || target == nil {
		return "could not locate space"
	}
	if w.space == target.id {
		return ""
	}
	source := space_by_id(m, w.space)
	if err := perform(m, {kind = .Space, window = w.id, space = target.id}); err != "" {
		return err
	}
	if source != nil {
		layout.remove(&source.view, w.id)
	}
	w.space, w.display = target.id, target.display
	w.scroll_frame = {}
	if layout_admitted(w) && !layout.add(&target.view, w.id, 0) {
		return "destination tiling tree is full"
	}
	return ""
}

workspace_send :: proc(m: ^Manager, operand: string, column: bool) -> string {
	direction := operand == "up" ? -1 : (operand == "down" ? 1 : 0)
	if direction == 0 {
		return "send expects up or down"
	}
	w := m.windows[m.focused]
	if w == nil {
		return "could not locate window"
	}
	source := space_by_id(m, w.space)
	target := workspace_neighbor(m, source, direction)
	if target == nil {
		return "could not locate space"
	}
	ids: [layout.MAX_STACK]u32
	count := 1
	ids[0] = w.id
	width: f64
	tabbed, full := false, false
	if column {
		if n := layout.find(source.view.root, w.id); n != nil && n.count > 0 {
			count = n.count
			ids = n.windows
			width = n.column_width
			tabbed, full = n.column_tabbed, n.column_full
		}
	}
	moved := 0
	for i in 0 ..< count {
		window := m.windows[ids[i]]
		if window == nil {
			continue
		}
		if err := perform(m, {kind = .Space, window = window.id, space = target.id}); err != "" {
			for j := moved - 1; j >= 0; j -= 1 {
				perform(m, {kind = .Space, window = ids[j], space = source.id})
			}
			return err
		}
		moved += 1
	}
	for i in 0 ..< count {
		window := m.windows[ids[i]]
		if window == nil {
			continue
		}
		if source != nil {
			layout.remove(&source.view, window.id)
		}
		window.space, window.display = target.id, target.display
		window.scroll_frame = {}
	}
	if column && count > 1 {
		first := ids[0]
		if layout_admitted(m.windows[first]) {
			layout.add(&target.view, first, 0)
		}
		node := layout.find(target.view.root, first)
		for i in 1 ..< count {
			if node != nil {
				layout.stack_push(node, ids[i])
			}
		}
		if node != nil {
			node.count = count
			node.windows = ids
			node.order = ids
			node.column_width, node.column_resolved = width, width
			node.column_tabbed, node.column_full = tabbed, full
		}
	} else if layout_admitted(w) {
		layout.add(&target.view, w.id, 0)
	}
	if source != nil {
		flush(m, source)
	}
	flush(m, target)
	workspace_reconcile(m)
	return ""
}

workspace_nudge :: proc(m: ^Manager, s: ^Space, operand: string) -> string {
	direction := operand == "up" ? -1 : (operand == "down" ? 1 : 0)
	if s == nil || direction == 0 {
		return "nudge expects up or down"
	}
	// Include native fullscreen spaces so a nudge stops on them instead of jumping over.
	other := workspace_neighbor(m, s, direction, false)
	if other == nil {
		return ""
	}
	if s.fullscreen || other.fullscreen {
		return "cannot reorder native fullscreen spaces"
	}
	if err := perform(m, {kind = .Space_Move, space = s.id, destination = other.id}); err != "" {
		return err
	}
	a, b := -1, -1
	for space, i in m.spaces {
		if space == s {
			a = i
		}
		if space == other {
			b = i
		}
	}
	if a >= 0 && b >= 0 {
		m.spaces[a], m.spaces[b] = m.spaces[b], m.spaces[a]
	}
	workspace_reindex(m)
	return ""
}

overview_free_trees :: proc(m: ^Manager) {
	for i in 0 ..< m.overview.tree_count {
		layout.node_destroy(m.overview.trees[i].root)
		m.overview.trees[i].root = nil
	}
}

overview_free_for_destroy :: proc(m: ^Manager) {
	overview_free_trees(m)
	m.overview = {}
}

overview_layout :: proc(m: ^Manager) -> string {
	if !m.overview.active {
		return ""
	}
	d := display_by_id(m, m.overview.display)
	if d == nil {
		return "could not locate display"
	}
	buf: [OVERVIEW_SPACES]^Space
	n := workspace_collect(m, d.id, true, buf[:])
	usable := d.usable
	inner_w := max(1, usable.w - 2 * OVERVIEW_INSET)
	content := 2 * OVERVIEW_INSET + f64(n) * OVERVIEW_BAND_H + OVERVIEW_GAP * f64(max(n - 1, 0))
	m.overview.pan = clamp(m.overview.pan, 0, max(0, content - usable.h))
	m.overview.band_count = n
	for index in 0 ..< n {
		s := buf[index]
		y :=
			usable.y +
			OVERVIEW_INSET +
			f64(index) * (OVERVIEW_BAND_H + OVERVIEW_GAP) -
			m.overview.pan
		band := Rect{usable.x + OVERVIEW_INSET, y, inner_w, OVERVIEW_BAND_H}
		m.overview.bands[index] = {s.id, band}
		ids: [layout.MAX_STACK * 4]u32
		count := 0
		for node := layout.first(s.view.root); node != nil; node = layout.next(node) {
			for i in 0 ..< node.count {
				if count >= len(ids) {
					break
				}
				ids[count] = node.windows[i]
				count += 1
			}
		}
		slots := max(count, 1)
		slot_w := band.w / f64(slots)
		for i in 0 ..< count {
			w := m.windows[ids[i]]
			if w == nil {
				continue
			}
			frame := Rect {
				band.x + f64(i) * slot_w + 4,
				band.y + 4,
				max(1, slot_w - 8),
				max(1, band.h - 8),
			}
			w.frame = frame
			if err := perform(m, {kind = .Frame, window = w.id, frame = frame, direct = true});
			   err != "" {
				return err
			}
		}
		for _, w in m.windows {
			if w == nil || w.space != s.id || !w.floating {
				continue
			}
			frame := Rect{band.x + band.w - 88, band.y + 8, 80, 48}
			w.frame = frame
			if err := perform(m, {kind = .Frame, window = w.id, frame = frame, direct = true});
			   err != "" {
				return err
			}
		}
	}
	return ""
}

overview_enter :: proc(m: ^Manager, s: ^Space) -> string {
	if m.overview.active {
		return "overview is already open"
	}
	if s == nil {
		return "could not locate space"
	}
	d := display_by_id(m, s.display)
	if d == nil {
		return "could not locate display"
	}
	buf: [OVERVIEW_SPACES]^Space
	n := workspace_collect(m, d.id, true, buf[:])
	if n == 0 {
		return "could not locate space"
	}
	windows := 0
	for _, w in m.windows {
		if w != nil && w.display == d.id {
			windows += 1
		}
	}
	if windows > OVERVIEW_WINDOWS {
		return "too many windows for overview"
	}
	m.overview = {
		display   = d.id,
		space     = s.id,
		window    = m.focused,
		focus_was = m.focused,
		space_was = m.active_space,
	}
	for i in 0 ..< n {
		space := buf[i]
		m.overview.trees[i] = {
			space  = space.id,
			root   = opening_clone_node(space.view.root, nil),
			scroll = space.view.scroll,
		}
	}
	m.overview.tree_count = n
	saved := 0
	for _, w in m.windows {
		if w == nil || w.display != d.id || saved >= OVERVIEW_WINDOWS {
			continue
		}
		m.overview.windows[saved] = {w.id, w.space, w.display, w.floating, w.frame}
		saved += 1
	}
	m.overview.window_count = saved
	m.overview.active = true
	if err := overview_layout(m); err != "" {
		overview_cancel(m)
		return err
	}
	return ""
}

overview_restore_windows :: proc(m: ^Manager) {
	for i in 0 ..< m.overview.window_count {
		saved := m.overview.windows[i]
		w := m.windows[saved.id]
		if w == nil {
			continue
		}
		w.space, w.display, w.floating, w.frame =
			saved.space, saved.display, saved.floating, saved.frame
	}
}

overview_cancel :: proc(m: ^Manager) -> string {
	if !m.overview.active {
		return ""
	}
	focus, space := m.overview.focus_was, m.overview.space_was
	for i in 0 ..< m.overview.tree_count {
		tree := m.overview.trees[i]
		s := space_by_id(m, tree.space)
		if s == nil {
			layout.node_destroy(tree.root)
		} else {
			layout.node_destroy(s.view.root)
			s.view.root = tree.root
			s.view.scroll = tree.scroll
		}
		m.overview.trees[i].root = nil
	}
	overview_restore_windows(m)
	for i in 0 ..< m.overview.inserted_count {
		if s := space_by_id(m, m.overview.inserted[i]); s != nil && s.ephemeral {
			workspace_free_space(m, s)
		}
	}
	m.overview = {}
	workspace_reindex(m)
	if w := m.windows[focus]; w != nil {
		focus_window(m, focus)
	}
	if err := workspace_focus(m, space_by_id(m, space)); err != "" && space != 0 {
		return err
	}
	for s in m.spaces {flush(m, s)}
	workspace_reconcile(m)
	return ""
}

overview_commit :: proc(m: ^Manager) -> string {
	if !m.overview.active {
		return ""
	}
	space := space_by_id(m, m.overview.space)
	window := m.overview.window
	overview_free_trees(m)
	m.overview = {}
	err := ""
	if space != nil {
		err = workspace_focus(m, space)
	}
	if window != 0 && m.windows[window] != nil {
		if focus_err := perform(m, {kind = .Focus, window = window});
		   focus_err != "" && err == "" {
			err = focus_err
		}
		focus_window(m, window)
	}
	for s in m.spaces {flush(m, s)}
	workspace_reconcile(m)
	return err
}

overview_step :: proc(m: ^Manager, operand: string) -> string {
	if !m.overview.active {
		return "overview is closed"
	}
	buf: [OVERVIEW_SPACES]^Space
	n := workspace_collect(m, m.overview.display, true, buf[:])
	index := 0
	for _, i in buf[:n] {
		if buf[i].id == m.overview.space {
			index = i; break
		}
	}
	switch operand {
	case "up":
		if index > 0 {
			index -= 1
		}
	case "down":
		if index + 1 < n {
			index += 1
		}
	case "left", "right":
		return overview_step_window(m, operand == "right")
	case:
		return(
			"overview expects enter, cancel, done, up, down, left, right, insert, pan-up, or pan-down" \
		)
	}
	if n == 0 {
		return "could not locate space"
	}
	m.overview.space = buf[index].id
	m.overview.window = overview_first_window(m, buf[index])
	return ""
}

overview_first_window :: proc(m: ^Manager, s: ^Space) -> u32 {
	if s == nil {
		return 0
	}
	if n := layout.first(s.view.root); n != nil && n.count > 0 {
		return n.windows[0]
	}
	for _, w in m.windows {
		if w != nil && w.space == s.id {
			return w.id
		}
	}
	return 0
}

overview_step_window :: proc(m: ^Manager, next: bool) -> string {
	s := space_by_id(m, m.overview.space)
	if s == nil {
		return "could not locate space"
	}
	ids: [OVERVIEW_WINDOWS]u32
	count := 0
	for node := layout.first(s.view.root); node != nil; node = layout.next(node) {
		for i in 0 ..< node.count {
			if count >= len(ids) {
				break
			}
			ids[count] = node.windows[i]
			count += 1
		}
	}
	if count == 0 {
		m.overview.window = 0
		return ""
	}
	at := 0
	for id, i in ids[:count] {
		if id == m.overview.window {
			at = i; break
		}
	}
	if next {
		if at + 1 < count {
			at += 1
		}
	} else if at > 0 {
		at -= 1
	}
	m.overview.window = ids[at]
	return ""
}

overview_insert :: proc(m: ^Manager) -> string {
	if !m.overview.active {
		return "overview is closed"
	}
	anchor := space_by_id(m, m.overview.space)
	created, err := workspace_create_after(m, anchor)
	if err != "" || created == nil {
		return err
	}
	created.kept = true
	if m.overview.inserted_count < len(m.overview.inserted) {
		m.overview.inserted[m.overview.inserted_count] = created.id
		m.overview.inserted_count += 1
	}
	m.overview.space = created.id
	m.overview.window = 0
	return overview_layout(m)
}

overview_pan :: proc(m: ^Manager, down: bool) -> string {
	if !m.overview.active {
		return "overview is closed"
	}
	m.overview.pan += down ? 80 : -80
	return overview_layout(m)
}

workspace_overview_command :: proc(m: ^Manager, s: ^Space, operand: string) -> string {
	switch operand {
	case "enter":
		return overview_enter(m, s)
	case "cancel":
		return overview_cancel(m)
	case "done":
		return overview_commit(m)
	case "insert":
		return overview_insert(m)
	case "pan-up":
		return overview_pan(m, false)
	case "pan-down":
		return overview_pan(m, true)
	case "up", "down", "left", "right":
		return overview_step(m, operand)
	case:
		return(
			"overview expects enter, cancel, done, up, down, left, right, insert, pan-up, or pan-down" \
		)
	}
}

overview_hit :: proc(m: ^Manager, point: Mouse_Point) -> (space: u64, window: u32) {
	for i in 0 ..< m.overview.band_count {
		band := m.overview.bands[i]
		for _, w in m.windows {
			if w == nil || w.space != band.space {
				continue
			}
			r := w.frame
			if point.x >= r.x && point.x <= r.x + r.w && point.y >= r.y && point.y <= r.y + r.h {
				return w.space, w.id
			}
		}
	}
	for i in 0 ..< m.overview.band_count {
		r := m.overview.bands[i].frame
		if point.x >= r.x && point.x <= r.x + r.w && point.y >= r.y && point.y <= r.y + r.h {
			return m.overview.bands[i].space, 0
		}
	}
	return 0, 0
}

overview_drop :: proc(m: ^Manager, window: u32, space: u64) -> string {
	if !m.overview.active {
		return "overview is closed"
	}
	w := m.windows[window]
	target := space_by_id(m, space)
	if w == nil || target == nil {
		return "could not locate window"
	}
	if w.space != target.id {
		if err := workspace_retarget(m, w, target); err != "" {
			return err
		}
	}
	m.overview.space = target.id
	m.overview.window = window
	return overview_layout(m)
}

overview_pointer :: proc(m: ^Manager, point: Mouse_Point, pressed: bool, now: f64) -> string {
	if !m.overview.active {
		return ""
	}
	if math.is_nan(now) || math.is_inf(now) || math.is_nan(point.x) || math.is_nan(point.y) {
		return ""
	}
	_, window := overview_hit(m, point)
	space, _ := overview_hit(m, point)
	if pressed {
		// The grabbed window stays until release. A later hit is only the drop
		// target, chosen when the button comes up. Leaving the thumbnail must
		// not restart the press.
		if m.overview.dragging != 0 {
			return ""
		}
		if !m.overview.pressing || window != m.overview.press_window {
			m.overview.pressing = true
			m.overview.press_window = window
			m.overview.press_since = now
			m.overview.dragging = 0
			return ""
		}
		// Unix-second floats can round a true 100ms gap to just under the delay.
		if window != 0 && now - m.overview.press_since + 1e-4 >= m.mouse.edge.delay {
			m.overview.dragging = window
		}
		return ""
	}
	dragging := m.overview.dragging
	m.overview.pressing = false
	m.overview.dragging = 0
	m.overview.press_window = 0
	if dragging != 0 && space != 0 {
		return overview_drop(m, dragging, space)
	}
	if window != 0 {
		m.overview.window = window
		m.overview.space = space
	} else if space != 0 {
		m.overview.space = space
		m.overview.window = overview_first_window(m, space_by_id(m, space))
	}
	return ""
}

overview_edge :: proc(m: ^Manager, point: Mouse_Point, now: f64) -> string {
	if !m.overview.active || !m.mouse.edge.enabled {
		return ""
	}
	if math.is_nan(now) || math.is_inf(now) || math.is_nan(point.x) || math.is_nan(point.y) {
		m.overview.edge_direction = 0
		return ""
	}
	d := display_by_id(m, m.overview.display)
	if d == nil {
		return ""
	}
	r := d.usable
	width := min(m.mouse.edge.width, r.h / 2)
	distance := min(point.y - r.y, r.y + r.h - point.y)
	inside := point.x >= r.x && point.x <= r.x + r.w && point.y >= r.y && point.y <= r.y + r.h
	if !inside || width <= 0 || distance >= width {
		m.overview.edge_direction = 0
		return ""
	}
	direction := point.y < r.y + r.h / 2 ? -1 : 1
	if m.overview.edge_direction != direction || now < m.overview.edge_last {
		m.overview.edge_direction = direction
		m.overview.edge_entered = now
		m.overview.edge_last = now
		return ""
	}
	previous := m.overview.edge_last
	m.overview.edge_last = now
	dt := clamp(now - max(previous, m.overview.edge_entered + m.mouse.edge.delay), 0, .05)
	if dt <= 0 {
		return ""
	}
	before := m.overview.pan
	m.overview.pan += f64(direction) * m.mouse.edge.speed * (1 - distance / width) * dt
	if err := overview_layout(m); err != "" {
		return err
	}
	if m.overview.pan == before {
		return ""
	}
	return ""
}

drag_hold_activate :: proc(m: ^Manager, mouse: ^Mouse_State, target: u32, now: f64) {
	if mouse == nil || math.is_nan(now) || math.is_inf(now) {
		return
	}
	if target == 0 || target == mouse.drag.window || mouse.drag.action != .Move {
		mouse.hold_window = 0
		mouse.hold_fired = false
		return
	}
	if mouse.hold_window != target {
		mouse.hold_window = target
		mouse.hold_since = now
		mouse.hold_fired = false
		return
	}
	if mouse.hold_fired || now - mouse.hold_since + 1e-4 < m.mouse.edge.delay {
		return
	}
	mouse.hold_fired = true
	w := m.windows[target]
	if w == nil {
		return
	}
	focus_window(m, target)
	if !m.overview.active {
		return
	}
	m.overview.window = target
	m.overview.space = w.space
	overview_layout(m)
}
