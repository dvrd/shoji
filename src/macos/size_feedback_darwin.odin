package macos

import e "../engine"
import "core:fmt"
import "core:time"

frame_size_feedback_tick :: proc(state: ^State, now: time.Time) {
	seconds := time.duration_seconds(time.diff(time.Time{}, now))
	m := &state.manager
	for id, w in m.windows {
		f := &w.size_feedback
		if !e.managed(w) {
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
		s := e.space_by_id(m, w.space)
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
		observed: e.Rect
		if SLSGetWindowBounds(state.connection, id, &observed) != 0 {
			f.checked_at = seconds; continue
		}
		if e.size_feedback_observe(w, generation, observed, seconds) {
			// The app is already at its accepted size. Correct layout occupancy
			// immediately instead of animating neighbors through that native frame.
			w.frame = observed
			if err := e.flush(m, s, true); err != "" {
				fmt.eprintln("shoji: accepted size:", err)
			}
			state.dirty = true
		}
	}
}
