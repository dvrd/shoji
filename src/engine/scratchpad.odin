package engine

import "core:strings"

scratchpad_by_label :: proc(m: ^Manager, label: string) -> ^Window {
	if label == "" {return nil}
	for _, w in m.windows {if w.scratchpad == label {return w}}
	return nil
}

scratchpad_show :: proc(m: ^Manager, w: ^Window) -> string {
	s := space_by_id(m, m.active_space)
	if s == nil {return "could not locate active space"}
	if w.space != s.id {
		if err := perform(m, {kind = .Space, window = w.id, space = s.id}); err != "" {return err}
		if previous := space_by_id(m, w.space); previous != nil {remove(&previous.view, w.id)}
		w.space, w.display = s.id, s.display
	}
	if err := perform(m, {kind = .Order, window = w.id, value = 1}); err != "" {return err}
	w.scratchpad_hidden = false
	w.ordered_in = true
	if err := perform(m, {kind = .Focus, window = w.id}); err != "" {return err}
	focus_window(m, w.id)
	return ""
}

scratchpad_toggle :: proc(m: ^Manager, w: ^Window) -> string {
	if w.scratchpad_hidden ||
	   (w.space != m.active_space && !w.sticky) {return scratchpad_show(m, w)}
	if err := perform(m, {kind = .Order, window = w.id, value = 0}); err != "" {return err}
	w.scratchpad_hidden = true
	w.ordered_in = false
	return ""
}

scratchpad_assign :: proc(m: ^Manager, w: ^Window, label: string) -> string {
	if label != "" {
		if scratchpad_by_label(m, label) != nil {return "scratchpad label is already assigned"}
		copy := strings.clone(label)
		delete(w.scratchpad);w.scratchpad = copy
		w.floating = true;w.manage_override = false
		if s := space_by_id(m, w.space); s != nil {remove(&s.view, w.id);return flush(m, s)}
	} else {
		if w.scratchpad == "" {return "window is not a scratchpad"}
		if err := scratchpad_show(m, w); err != "" {return err}
		delete(w.scratchpad);w.scratchpad = ""
		w.floating = false;w.manage_override = nil
		if w.opening.phase == .Excluded {w.opening.phase = .Admitted}
		if s := space_by_id(m, w.space);
		   s != nil && layout_admitted(w) {add(&s.view, w.id);return flush(m, s)}
	}
	return ""
}

scratchpad_recover :: proc(m: ^Manager) -> string {
	for _, w in m.windows {
		if w.scratchpad == "" {continue}
		if err := perform(m, {kind = .Order, window = w.id, value = 1}); err != "" {return err}
		w.scratchpad_hidden = false
		w.ordered_in = true
	}
	return ""
}
