package shoji

import "core:math"
import "core:fmt"
import "core:time"

// Accepted-size feedback
// ------------------------------------------------------------------------

// A settled observation applies to one intent/context, not a learned universal
// minimum or maximum. Explicit retries and changed layout contexts invalidate it.
Size_Intent :: struct {
	w, h: f64,
	width_revision, height_revision: u64,
	viewport: Rect,
	space: u64,
	display: u32,
	pid: i32,
	zoomed, tabbed: bool,
}
Size_Feedback :: struct {
	intent: Size_Intent,
	accepted: Rect,
	width_valid, height_valid: bool,
	pending: bool,
	generation: u64,
	expected, sample: Rect,
	requested_at, checked_at, sampled_at: f64,
	observations: int,
}
size_feedback_invalidate :: proc(w: ^Window) {
	f := &w.size_feedback
	i := w.size_intent
	context_changed :=
		f.intent.viewport != i.viewport ||
		f.intent.space != i.space ||
		f.intent.display != i.display ||
		f.intent.pid != i.pid ||
		f.intent.zoomed != i.zoomed ||
		f.intent.tabbed != i.tabbed
	width_changed :=
		context_changed ||
		f.intent.w != i.w ||
		f.intent.width_revision != i.width_revision
	height_changed :=
		context_changed ||
		f.intent.h != i.h ||
		f.intent.height_revision != i.height_revision
	if width_changed || height_changed {
		// Application constraints may couple width and height (for example an
		// aspect ratio), so changing either intent invalidates both adjustments.
		f.width_valid, f.height_valid = false, false
		f.pending = false; f.generation += 1; f.observations = 0
	}
	f.intent = i
}
size_feedback_request :: proc(
	w: ^Window,
	requested, previous: Rect,
	now: f64,
) {
	size_feedback_invalidate(w)
	f := &w.size_feedback
	if math.abs(requested.w - previous.w) <= 1 &&
	   math.abs(requested.h - previous.h) <= 1 {
		return
	}
	if f.pending &&
	   math.abs(f.expected.w - requested.w) <= 1 &&
	   math.abs(f.expected.h - requested.h) <= 1 {
		return
	}
	f.generation += 1
	f.expected, f.requested_at, f.checked_at = requested, now, now
	f.pending, f.observations = true, 0
}
size_feedback_duplicate :: proc(w: ^Window, requested: Rect) -> bool {
	f := &w.size_feedback
	return(
		f.pending &&
		math.abs(f.expected.w - requested.w) <= 1 &&
		math.abs(f.expected.h - requested.h) <= 1 \
	)
}
size_feedback_observe :: proc(
	w: ^Window,
	generation: u64,
	observed: Rect,
	now: f64,
) -> bool {
	f := &w.size_feedback
	if generation != f.generation ||
	   !f.pending ||
	   now - f.requested_at < 0.15 ||
	   now - f.checked_at < 0.06 {
		return false
	}
	f.checked_at = now
	if math.is_nan(observed.w) ||
	   math.is_nan(observed.h) ||
	   math.is_inf(observed.w) ||
	   math.is_inf(observed.h) ||
	   observed.w <= 0 ||
	   observed.h <= 0 {
		return false
	}
	if f.observations == 0 ||
	   math.abs(f.sample.w - observed.w) > 1 ||
	   math.abs(f.sample.h - observed.h) > 1 {
		f.sample, f.sampled_at, f.observations = observed, now, 1
		return false
	}
	if now - f.sampled_at < 0.06 {
		return false
	}
	f.pending = false
	changed := false
	if math.abs(observed.w - f.intent.w) <= 1 {
		if f.width_valid {
			f.width_valid, changed = false, true
		}
	} else if math.abs(observed.w - f.expected.w) > 1 {
		f.accepted.w, f.width_valid, changed = observed.w, true, true
	}
	if math.abs(observed.h - f.intent.h) <= 1 {
		if f.height_valid {
			f.height_valid, changed = false, true
		}
	} else if math.abs(observed.h - f.expected.h) > 1 {
		f.accepted.h, f.height_valid, changed = observed.h, true, true
	}
	if changed {
		w.size_feedback_reflow = true
	}
	return changed
}
// A late client response that matches the original intent supersedes a
// provisional adjustment. This never fabricates a minimum from a failed read.
size_feedback_late_result :: proc(w: ^Window, observed: Rect) -> bool {
	f := &w.size_feedback
	if f.pending {
		return false
	}
	changed := false
	if f.width_valid &&
	   observed.w > 0 &&
	   math.abs(observed.w - f.intent.w) <= 1 {
		f.width_valid, changed = false, true
	}
	if f.height_valid &&
	   observed.h > 0 &&
	   math.abs(observed.h - f.intent.h) <= 1 {
		f.height_valid, changed = false, true
	}
	if changed {
		w.size_feedback_reflow = true
	}
	return changed
}

scroll_feedback_prepare :: proc(m: ^Manager, s: ^Space) {
	v := &s.view
	for n := first(v.root); n != nil; n = next(n) {
		n.column_observed = 0
		any_observed := false
		footprint: f64
		for i in 0 ..< n.count {
			w := m.windows[n.windows[i]]
			if w == nil {
				continue
			}
			width, height := n.column_width, n.row_heights[i]
			if n.column_tabbed {
				height = n.frame.h
				if v.tab_indicator_top {
					height = max(1, height - tab_indicator_gutter(v, n))
				} else {
					width = max(1, width - tab_indicator_gutter(v, n))
				}
			}
			if n.zoom != nil {
				width, height = v.scroll.viewport.w, v.scroll.viewport.h
			}
			w.size_intent = {
				w               = width,
				h               = height,
				width_revision  = n.column_revision,
				height_revision = w.row_revision,
				viewport        = v.scroll.viewport,
				space           = s.id,
				display         = s.display,
				pid             = w.pid,
				tabbed          = n.column_tabbed,
				zoomed          = n.zoom != nil,
			}
			size_feedback_invalidate(w)
			if w.size_feedback.width_valid && n.zoom == nil {
				gutter := v.tab_indicator_top ? f64(0) : tab_indicator_gutter(v, n)
				footprint = max(footprint, w.size_feedback.accepted.w + gutter)
				any_observed = true
			} else {
				footprint = max(footprint, n.column_width)
			}
		}
		if any_observed {
			n.column_observed = footprint
		}
	}
}

size_feedback_frame :: proc(w: ^Window, frame: Rect) -> Rect {
	r := frame
	if w.size_feedback.width_valid {
		r.w = w.size_feedback.accepted.w
	}
	if w.size_feedback.height_valid {
		r.h = w.size_feedback.accepted.h
	}
	return r
}


// Accepted-size feedback
// ------------------------------------------------------------------------

frame_size_feedback_tick :: proc(state: ^State, now: time.Time) {
	seconds := time.duration_seconds(time.diff(time.Time{}, now))
	m := &state.manager
	for id, w in m.windows {
		f := &w.size_feedback
		if !managed(w) {
			if f.pending || f.width_valid || f.height_valid {
				f.pending, f.width_valid, f.height_valid = false, false, false
				f.generation += 1
			}
			continue
		}
		if !f.pending ||
		   seconds - f.requested_at < 0.15 ||
		   seconds - f.checked_at <
			   (seconds - f.requested_at > 3 ? f64(0.5) : f64(0.06)) {
			continue
		}
		s := space_by_id(m, w.space)
		if s == nil ||
		   !s.visible ||
		   s.view.layout != .Scroll ||
		   s.view.scroll.dragging ||
		   s.view.scroll.motion.active ||
		   s.view.scroll.geometry_active ||
		   m.suspended ||
		   m.gesture_active ||
		   w.grabbed ||
		   m.native_resize_window == id {
			continue
		}
		generation := f.generation
		owner, known := animation_recovery_query_owner(state.connection, id)
		pid: i32
		if !known || SLSConnectionGetPID(owner, &pid) != 0 {
			f.checked_at = seconds; continue
		}
		if pid != w.pid {
			f.pending, f.width_valid, f.height_valid = false, false, false
			state.dirty = true; continue
		}
		observed: Rect
		if SLSGetWindowBounds(state.connection, id, &observed) != 0 {
			f.checked_at = seconds; continue
		}
		if size_feedback_observe(w, generation, observed, seconds) {
			// The app is already at its accepted size. Correct layout occupancy
			// immediately instead of animating neighbors through that native frame.
			w.frame = observed
			if err := flush(m, s, true); err != "" {
				fmt.eprintln("shoji: accepted size:", err)
			}
			state.dirty = true
		}
	}
}
