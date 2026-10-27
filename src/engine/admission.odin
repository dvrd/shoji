package engine

import "core:math"

Opening_Phase :: enum { Admitted, Pending, Opening, Excluded }
Opening_Wait :: enum { Readiness, Space, Backend }
Opening :: struct {
	phase: Opening_Phase,
	wait: Opening_Wait,
	focus_origin: u32,
	focus_superseded: bool,
	focus_replacement: u32,
	staged: bool,
	minimum: Rect,
	seed: Rect,
	restore_layer: f64,
	original_layer: f64,
}

Opening_Prepare :: proc(m: ^Manager, w: ^Window, seed: Rect) -> (Rect, bool, string)
Opening_Backend :: struct {
	prepare: Opening_Prepare,
	conceal: proc(m: ^Manager, w: ^Window) -> string,
}

// Discovery records intent; admission alone changes layout membership.
discover_window :: proc(m: ^Manager, value: Window) -> ^Window {
	if old := m.windows[value.id]; old != nil {return old}
	value := value
	value.opening = {phase = .Pending, focus_origin = m.focused}
	return add_window(m, value)
}

layout_admitted :: proc(w: ^Window) -> bool {
	return managed(w) && (w.opening.phase == .Admitted || w.opening.phase == .Opening)
}

opening_intended :: proc(w: ^Window) -> bool {
	value := w^;value.ordered_in = nil
	return managed(&value)
}

opening_clone_node :: proc(source, parent: ^Node) -> ^Node {
	if source == nil {return nil}
	n := new(Node);n^ = source^;n.parent = parent;n.zoom = nil
	n.left = opening_clone_node(source.left, n);n.right = opening_clone_node(source.right, n)
	return n
}

opening_apply_seed :: proc(m: ^Manager, w: ^Window, seed: Rect) -> (Rect, bool, string) {
	err := perform(m, {kind = .Frame, window = w.id, frame = seed, direct = true})
	return seed, err == "", err
}

// Conceal during discovery, before a desktop scan can block on another app.
// Planning and membership changes remain deferred until collection completes.
stage_opening :: proc(m: ^Manager, w: ^Window, backend: Opening_Backend = {}) -> (bool, string) {
	if w == nil || w.opening.phase != .Pending || m.suspended || m.gesture_active {return false, ""}
	o := &w.opening
	if w.role == "" || w.subrole == "" {return false, ""}
	if !opening_intended(w) {return false, exclude_opening(m, w)}
	if !o.staged {
		o.original_layer = w.layer == "above" ? 1 : (w.layer == "below" ? -1 : 0)
		o.restore_layer = w.layer_override ? (w.layer == "above" ? 1 : (w.layer == "below" ? -1 : 0)) : -1
		if err := perform(m, {kind = .Layer, window = w.id, value = -1}); err != "" {o.wait = .Backend;return false, err}
		if err := perform(m, {kind = .Order, window = w.id, value = -1}); err != "" {o.wait = .Backend;return false, err}
		o.staged = true;w.layer = "below"
	}
	if backend.conceal != nil {
		if err := backend.conceal(m, w); err != "" {o.wait = .Backend;return false, err}
	}
	return true, ""
}

// All discovery sources call this same admission boundary. A candidate view is
// private until preparation succeeds, so existing tiles keep their geometry.
admit_window :: proc(m: ^Manager, w: ^Window, backend: Opening_Backend = {}) -> (bool, string) {
	staged, stage_error := stage_opening(m, w, backend)
	if !staged {return false, stage_error}
	o := &w.opening
	if w.rules_pending {o.wait = .Readiness;return false, ""}
	if m.focused != o.focus_origin && m.focused != w.id {o.focus_superseded = true}
	s := space_by_id(m, w.space)
	if s == nil || !s.visible || !(w.ordered_in.? or_else true) || w.frame.w <= 0 || w.frame.h <= 0 {o.wait = .Readiness;return false, ""}
	if s.view.layout == .Float {return false, exclude_opening(m, w)}
	v := s.view;v.root = opening_clone_node(s.view.root, nil)
	defer view_destroy(&v)
	zooms := capture_zooms(&s.view);restore_zooms(&v, zooms[:])
	if !add(&v, w.id, window_insertion(m, &v)) {o.wait = .Space;return false, ""}
	if v.layout == .BSP {
		if !bsp_constraints(m, &v) {o.wait = .Space;return false, ""}
		view_update(&v)
	}
	if v.layout == .Scroll {
		v.scroll.geometry_enabled = false
		scroll_constraints(m, &v);view_update(&v);scroll_rows(m, &v)
		if m.focused == w.id && !o.focus_superseded {scroll_reveal(&v, w.id);scroll_update(&v);scroll_rows(m, &v)}
	}
	n := find(v.root, w.id)
	target := v.layout == .Scroll ? scroll_window_frame(&v, n, w.id, false) : frame_for(n)
	if v.layout == .Scroll && target.h > v.scroll.viewport.h {o.wait = .Space;return false, ""}
	vertical := v.layout == .Scroll || n.parent == nil || n.parent.split == .Vertical
	trailing := v.layout == .Scroll || n.parent == nil || n == n.parent.right
	seed := target
	if vertical {seed.w = max(1, target.w * 0.5)} else {seed.h = max(1, target.h * 0.5)}
	seed.w = max(seed.w, max(w.min_width, o.minimum.w));seed.h = max(seed.h, max(w.min_height, o.minimum.h))
	if trailing {
		if vertical {seed.x = target.x + target.w - seed.w}
		else {seed.y = target.y + target.h - seed.h}
	}
	prepare: Opening_Prepare = opening_apply_seed
	if backend.prepare != nil {prepare = backend.prepare}
	accepted, ready, err := prepare(m, w, seed)
	if err != "" {o.wait = .Backend;return false, err}
	if !ready {o.wait = .Readiness;return false, ""}
	if math.is_nan(accepted.w) || math.is_nan(accepted.h) || accepted.w <= 0 || accepted.h <= 0 {o.wait = .Readiness;return false, ""}
	if accepted.w > seed.w + 1 {o.minimum.w = max(o.minimum.w, accepted.w)}
	if accepted.h > seed.h + 1 {o.minimum.h = max(o.minimum.h, accepted.h)}
	if accepted.w > target.w + 1 || accepted.h > target.h + 1 {o.wait = .Space;return false, ""}
	aligned := accepted;aligned.x, aligned.y = target.x, target.y
	if trailing {
		if vertical {aligned.x = target.x + target.w - accepted.w}
		else {aligned.y = target.y + target.h - accepted.h}
	}
	if !scroll_rect_near(aligned, accepted, 1) {
		_, _, err := prepare(m, w, aligned)
		o.wait = .Readiness;return false, err
	}
	w.frame = accepted;o.seed = accepted
	if v.layout == .Scroll {
		world := accepted;world.x += v.scroll.motion.initialized ? v.scroll.motion.position : v.scroll.offset
		w.scroll_frame = {valid = true, space = s.id, from = world, current = world, target = world}
	}
	old := s.view;s.view = v;v = old
	o.phase = .Opening
	if err := flush(m, s); err != "" {return true, err}
	return true, ""
}

opening_note_focus :: proc(m: ^Manager, id: u32, deliberate: bool = false) {
	if id == 0 {return}
	for _, w in m.windows {
		if (w.opening.phase == .Pending || w.opening.phase == .Opening) && id != w.id && (deliberate || id != w.opening.focus_origin || m.focused != id) {
			w.opening.focus_superseded = true;w.opening.focus_replacement = id
		}
	}
}

exclude_opening :: proc(m: ^Manager, w: ^Window) -> string {
	if w.opening.staged {
		if err := perform(m, {kind = .Layer, window = w.id, value = w.opening.original_layer}); err != "" {return err}
		w.layer = w.opening.original_layer == 0 ? "normal" : (w.opening.original_layer > 0 ? "above" : "below")
	}
	w.opening.phase = .Excluded
	return ""
}

finish_opening :: proc(m: ^Manager, w: ^Window) -> string {
	if w == nil || w.opening.phase != .Opening {return ""}
	if w.opening.restore_layer != -1 {
		if err := perform(m, {kind = .Layer, window = w.id, value = w.opening.restore_layer}); err != "" {return err}
		w.layer = w.opening.restore_layer == 1 ? "above" : "normal"
	}
	if !w.opening.focus_superseded && m.focused == w.id {
		if err := perform(m, {kind = .Order, window = w.id, value = 1}); err != "" {return err}
	}
	w.opening.phase = .Admitted
	return ""
}
