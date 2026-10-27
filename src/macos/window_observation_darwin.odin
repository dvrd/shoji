package macos

import e "../engine"
import "core:fmt"
import "core:strings"

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
		frame                 = window_frame(element),
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
	if old := state.manager.windows[id]; old == nil || old.pid != pid || old.role == "" || old.subrole == "" {
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
		if w.role == "" {w.role = strings.clone(value.role)}
		if w.subrole == "" {w.subrole = strings.clone(value.subrole)}
		if value.ordered_in != nil {
			w.ordered_in = value.ordered_in
		}
		if value.can_resize != nil {
			w.can_resize = value.can_resize
		}
		w.root_window = value.root_window
		w.hidden, w.minimized, w.fullscreen =
			value.hidden, value.minimized, value.fullscreen
		w.frame = value.frame
		e.size_feedback_late_result(w, value.frame)
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
