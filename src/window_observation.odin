package shoji

import "core:fmt"
import "core:strings"

foreign import window_sls "system:SkyLight.framework"

// Window observations
// ------------------------------------------------------------------------

// A single native read, with unknown values retained explicitly. Borrowed
// strings remain valid for the refresh tick; reconciliation owns model strings.
Window_Appearance :: struct {
	sub_level: Maybe(i32),
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
) -> Window {
	result: Window
	sid := window_space(state, id)
	display: u32
	if s := space_by_id(&state.manager, sid); s != nil {
		display = s.display
	}
	w := &result
	frame := window_frame(element)
	root, parent := window_is_root(state, id, element, app.element)
	w^ = {
		id                    = id,
		pid                   = pid,
		app                   = app.name,
		title                 = attribute_text(element, "AXTitle"),
		ordered_in            = window_ordered_in(state, id),
		root_window           = root,
		parent                = parent,
		frame                 = frame.? or_else Rect{},
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
	result.tags, result.level = window_query_appearance(state.connection, id)
	result.sub_level = window_sublevel(state.connection, id)
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
	value: Window,
) -> (
	^Window,
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
		remove_window(m, value.id)
	}
	window_reference_update(state, value.id, element, app.observer)
	return reconcile_window_model(m, value)
}

// Native queries stay in collection. Unknown capabilities and spaces preserve
// the previous observation; a failed query must not revoke a known capability.
reconcile_window_model :: proc(
	m: ^Manager,
	value: Window,
) -> (
	^Window,
	bool,
) {
	w := m.windows[value.id]
	created := w == nil
	if created {
		w = add_window(m, value)
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
		w.parent = value.parent
		w.hidden, w.minimized, w.fullscreen =
			value.hidden, value.minimized, value.fullscreen
		if (value.frame_valid.? or_else true) && valid_frame(value.frame) {
			w.frame = value.frame
			w.frame_valid = true
			size_feedback_late_result(w, value.frame)
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
	w: ^Window,
	appearance: Window_Appearance,
) {
	if tags, known := appearance.tags.?; known {
		w.sticky = tags & (1 << 11) != 0; w.shadow = tags & (1 << 3) == 0
	}
	if level, known := appearance.level.?; known {
		w.level = level
	}
	if sub_level, known := appearance.sub_level.?; known {
		w.sub_level = sub_level
		w.layer =
			sub_level < 0 ? "below" : (sub_level > 0 ? "above" : "normal")
	}
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

refresh_window_rules :: proc(m: ^Manager, w: ^Window) {
	previous_error := strings.clone(w.rule_error, context.temp_allocator)
	if err := apply_rules(m, w); err != "" && err != previous_error {
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
		window: ^Window,
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
	window: ^Window,
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
