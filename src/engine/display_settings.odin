package engine

usable_frame :: proc(m: ^Manager, d: ^Display) -> Rect {
	r := d.usable
	if m.external_bar == .All || (m.external_bar == .Main && d.id == m.main_display) {
		r.y += m.bar_top
		r.h = max(1, r.h - m.bar_top - m.bar_bottom)
	}
	return r
}

order_displays :: proc(m: ^Manager) {
	for i in 1 ..< len(m.displays) {
		for j := i; j > 0; j -= 1 {
			a, b := m.displays[j - 1], m.displays[j]
			ax, ay := a.frame.x + a.frame.w / 2, a.frame.y + a.frame.h / 2
			bx, by := b.frame.x + b.frame.w / 2, b.frame.y + b.frame.h / 2
			after := a.native_index > b.native_index
			switch m.display_order {
			case .Default:
			case .Vertical:
				after = ay > by || (ay == by && ax > bx)
			case .Horizontal:
				after = ax > bx || (ax == bx && ay > by)
			}
			if !after {break}
			m.displays[j - 1], m.displays[j] = b, a
		}
	}
	for &d, i in m.displays {d.index = u32(i + 1)}
}

apply_window_shadows :: proc(m: ^Manager) -> string {
	for _, w in m.windows {
		desired := m.shadow_mode == .On || (m.shadow_mode == .Float && !managed(w))
		if w.shadow == desired {continue}
		if err := perform(m, {kind = .Shadow, window = w.id, flag = desired});
		   err != "" {return err}
		w.shadow = desired
	}
	return ""
}

apply_window_layers :: proc(m: ^Manager) -> string {
	for _, w in m.windows {
		if w.layer_override {continue}
		below := managed(w)
		desired := below ? "below" : "normal"
		if w.layer == desired {continue}
		if err := perform(m, {kind = .Layer, window = w.id, value = below ? -1 : 0});
		   err != "" {return err}
		w.layer = desired
	}
	return ""
}
