package engine

import "core:math"

Scroll_Frame :: struct {
	valid: bool,
	snap_width, snap_height: bool,
	space: u64,
	from, target, current, velocity, initial_velocity: Rect,
	progress: f64,
}
scroll_rect_near :: proc(a, b: Rect, tolerance: f64 = 0.001) -> bool {
	return(
		math.abs(a.x - b.x) <= tolerance &&
		math.abs(a.y - b.y) <= tolerance &&
		math.abs(a.w - b.w) <= tolerance &&
		math.abs(a.h - b.h) <= tolerance \
	)
}
scroll_small_resize :: proc(current, target, velocity, limit: f64) -> bool {
	delta := target - current
	if math.abs(delta) > limit {
		return false
	}
	// Only cancel slow motion already heading toward the new size. A fast
	// reversal retains its velocity rather than popping into a nearby target.
	if delta == 0 {
		return math.abs(velocity) < .001
	}
	return(
		velocity * delta >= 0 &&
		math.abs(velocity) <= SCROLL_SPRING_OMEGA * math.abs(delta) \
	)
}
scroll_frame_sample :: proc(frame: ^Scroll_Frame, elapsed: f64) {
	if elapsed >= SCROLL_SPRING_DURATION {
		frame.current, frame.velocity, frame.progress = frame.target, {}, 1
		return
	}
	t := max(0, elapsed)
	decay := math.exp(-SCROLL_SPRING_OMEGA * t)
	a, b := (1 + SCROLL_SPRING_OMEGA * t) * decay, t * decay
	// Content blending follows the animation clock, independent of retained
	// geometry velocity (which can move through the target before settling).
	frame.progress = clamp(1 - a, 0, 1)
	c, d :=
		-SCROLL_SPRING_OMEGA *
		SCROLL_SPRING_OMEGA *
		t *
		decay,
		(1 - SCROLL_SPRING_OMEGA * t) *
		decay
	from := [4]f64{frame.from.x, frame.from.y, frame.from.w, frame.from.h}
	target := [4]f64 {
		frame.target.x,
		frame.target.y,
		frame.target.w,
		frame.target.h,
	}
	velocity := [4]f64 {
		frame.initial_velocity.x,
		frame.initial_velocity.y,
		frame.initial_velocity.w,
		frame.initial_velocity.h,
	}
	positions, speeds: [4]f64
	for i in 0 ..< 4 {
		positions[i] = target[i] + (from[i] - target[i]) * a + velocity[i] * b
		speeds[i] = (from[i] - target[i]) * c + velocity[i] * d
	}
	frame.current = {positions[0], positions[1], positions[2], positions[3]}
	frame.velocity = {speeds[0], speeds[1], speeds[2], speeds[3]}
	if frame.snap_width {
		frame.current.w = frame.target.w; frame.velocity.w = 0
	}
	if frame.snap_height {
		frame.current.h = frame.target.h; frame.velocity.h = 0
	}
}
scroll_world_target :: proc(v: ^View, n: ^Node, w: ^Window) -> Rect {
	r := size_feedback_frame(w, scroll_window_frame(v, n, w.id, false))
	r.x += v.scroll.offset
	return r
}
scroll_geometry_prepare :: proc(m: ^Manager, s: ^Space) {
	v := &s.view
	changed := false
	for n := first(v.root); n != nil; n = next(n) {
		for i in 0 ..< n.count {
			w := m.windows[n.windows[i]]
			if w == nil {
				continue
			}
			target := scroll_world_target(v, n, w)
			if w.scroll_frame.valid &&
			   w.scroll_frame.space == s.id &&
			   !scroll_rect_near(w.scroll_frame.target, target) {
				changed = true
			}
		}
	}
	previously_active := v.scroll.geometry_active
	active := false
	for n := first(v.root); n != nil; n = next(n) {
		for i in 0 ..< n.count {
			w := m.windows[n.windows[i]]
			if w == nil {
				continue
			}
			target := scroll_world_target(v, n, w)
			f := &w.scroll_frame
			if !f.valid || f.space != s.id || !v.scroll.geometry_enabled {
				f^ = {
					valid    = true,
					space    = s.id,
					from     = target,
					target   = target,
					current  = target,
					progress = 1,
				}
				continue
			}
			if previously_active {
				scroll_frame_sample(f, m.scroll_time - v.scroll.geometry_began)
			}
			if changed {
				// A small resize can resolve in one content update while existing
				// position motion continues. Cap the cutoff to the gap so a growing
				// body uses only the available spacing during catch-up motion.
				cutoff := min(10.0, scroll_gap(v))
				if f.target.w != target.w {
					f.snap_width = scroll_small_resize(
						f.current.w,
						target.w,
						f.velocity.w,
						cutoff,
					)
				}
				if f.target.h != target.h {
					f.snap_height = scroll_small_resize(
						f.current.h,
						target.h,
						f.velocity.h,
						cutoff,
					)
				}
				f.from, f.initial_velocity, f.target =
					f.current, f.velocity, target
				f.progress = 0
				if f.snap_width {
					f.current.w, f.from.w = target.w, target.w
					f.velocity.w, f.initial_velocity.w = 0, 0
				}
				if f.snap_height {
					f.current.h, f.from.h = target.h, target.h
					f.velocity.h, f.initial_velocity.h = 0, 0
				}
			}
			if !scroll_rect_near(f.current, f.target) ||
			   !scroll_rect_near(f.velocity, {}) {
				active = true
			}
		}
	}
	if changed {
		v.scroll.geometry_began = m.scroll_time
	}
	v.scroll.geometry_active = active
}
scroll_geometry_finish :: proc(m: ^Manager, s: ^Space) {
	s.view.scroll.geometry_active = false
	for _, w in m.windows {
		if w.space == s.id {
			w.scroll_frame.current, w.scroll_frame.velocity =
				w.scroll_frame.target, {}
			w.scroll_frame.progress = 1
		}
	}
}
