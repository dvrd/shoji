package shoji

import "core:strings"

// Scratchpad
// ------------------------------------------------------------------------

// Destination tile position for a window moving to a BSP/Stack Space. The
// window is inserted into the destination tree (staged) so the frame is the
// one flush will apply. Scroll and Float destinations carry no landing.
space_landing :: proc(w: ^Window, source, target: ^Space) -> (landing: Rect, staged: bool) {
	if target == nil || target == source || !layout_admitted(w) ||
	   (target.view.layout != .BSP && target.view.layout != .Stack) {
		return
	}
	if !add(&target.view, w.id) {return}
	view_update(&target.view)
	if n := find(target.view.root, w.id); n != nil {landing = frame_for(n)}
	return landing, true
}

scratchpad_by_label :: proc(m: ^Manager, label: string) -> ^Window {
	if label == "" {
		return nil
	}
	for _, w in m.windows {
		if w.scratchpad == label {
			return w
		}
	}
	return nil
}

scratchpad_show :: proc(m: ^Manager, w: ^Window) -> string {
	s := space_by_id(m, m.active_space)
	if s == nil {
		return "could not locate active space"
	}
	if w.space != s.id {
		if err := perform(m, {kind = .Space, window = w.id, space = s.id});
		   err != "" {
			return err
		}
		if previous := space_by_id(m, w.space); previous != nil {
			remove(&previous.view, w.id)
		}
		w.space, w.display = s.id, s.display
	}
	if err := perform(m, {kind = .Order, window = w.id, value = 1});
	   err != "" {
		return err
	}
	w.scratchpad_hidden = false
	w.ordered_in = true
	if err := perform(m, {kind = .Focus, window = w.id}); err != "" {
		return err
	}
	focus_window(m, w.id)
	return ""
}

scratchpad_toggle :: proc(m: ^Manager, w: ^Window) -> string {
	if w.scratchpad_hidden || (w.space != m.active_space && !w.sticky) {
		return scratchpad_show(m, w)
	}
	if err := perform(m, {kind = .Order, window = w.id, value = 0});
	   err != "" {
		return err
	}
	w.scratchpad_hidden = true
	w.ordered_in = false
	return ""
}

scratchpad_assign :: proc(m: ^Manager, w: ^Window, label: string) -> string {
	if label != "" {
		if scratchpad_by_label(m, label) != nil {
			return "scratchpad label is already assigned"
		}
		copy := strings.clone(label)
		delete(w.scratchpad); w.scratchpad = copy
		w.floating = true; w.manage_override = false
		if s := space_by_id(m, w.space); s != nil {
			remove(&s.view, w.id); return flush(m, s)
		}
	} else {
		if w.scratchpad == "" {
			return "window is not a scratchpad"
		}
		if err := scratchpad_show(m, w); err != "" {
			return err
		}
		delete(w.scratchpad); w.scratchpad = ""
		w.floating = false; w.manage_override = nil
		if w.opening.phase == .Excluded {
			w.opening.phase = .Admitted
		}
		if s := space_by_id(m, w.space); s != nil && layout_admitted(w) {
			add(&s.view, w.id); return flush(m, s)
		}
	}
	return ""
}

scratchpad_recover :: proc(m: ^Manager) -> string {
	for _, w in m.windows {
		if w.scratchpad == "" {
			continue
		}
		if err := perform(m, {kind = .Order, window = w.id, value = 1});
		   err != "" {
			return err
		}
		w.scratchpad_hidden = false
		w.ordered_in = true
	}
	return ""
}
