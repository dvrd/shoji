package engine

import "core:math"

// One camera trajectory drives the strip; column geometry stays in target
// coordinates and presentation translates every row by the same displacement.
Scroll_Motion :: struct {
	initialized, active: bool,
	position, target, velocity: f64,
	from, initial_velocity, began: f64,
	anchor: u32,
}
SCROLL_SPRING_OMEGA :: 28.2842712474619 // sqrt(800), unit mass, critical damping
SCROLL_SPRING_DURATION :: 0.3256347067030293 // -ln(0.0001) / sqrt(800)

scroll_motion_sample :: proc(motion: ^Scroll_Motion, now: f64) {
	if !motion.active {
		return
	}
	t := max(0, now - motion.began)
	if t >= SCROLL_SPRING_DURATION {
		motion.position, motion.velocity, motion.active =
			motion.target, 0, false
		return
	}
	y := motion.from - motion.target
	b := motion.initial_velocity + SCROLL_SPRING_OMEGA * y
	decay := math.exp(-SCROLL_SPRING_OMEGA * t)
	motion.position = motion.target + (y + b * t) * decay
	motion.velocity =
		(motion.initial_velocity - SCROLL_SPRING_OMEGA * b * t) * decay
}
scroll_motion_prepare :: proc(v: ^View, now: f64, animate: bool) {
	motion := &v.scroll.motion
	if !motion.initialized || !animate || v.scroll.dragging {
		motion^ = {
			initialized = true,
			position    = v.scroll.offset,
			target      = v.scroll.offset,
			anchor      = v.scroll.anchor,
		}
		return
	}
	if motion.target != v.scroll.offset ||
	   (!motion.active && motion.velocity != 0) {
		scroll_motion_sample(motion, now)
		motion.from, motion.initial_velocity = motion.position, motion.velocity
		motion.target, motion.began, motion.active = v.scroll.offset, now, true
	}
	motion.anchor = v.scroll.anchor
}
scroll_motion_tick :: proc(m: ^Manager, now: f64) -> string {
	m.scroll_time = now
	for s in m.spaces {
		if !s.view.scroll.motion.active && !s.view.scroll.geometry_active {
			continue
		}
		if !m.scroll_animate ||
		   s.view.layout != .Scroll ||
		   !s.visible ||
		   m.suspended ||
		   m.gesture_active {
			s.view.scroll.motion.active = false
			s.view.scroll.motion.position = s.view.scroll.offset
			s.view.scroll.motion.velocity = 0
			scroll_geometry_finish(m, s)
			continue
		}
		scroll_motion_sample(&s.view.scroll.motion, now)
		if err := flush(m, s); err != "" {
			s.view.scroll.motion.active = false
			s.view.scroll.motion.position = s.view.scroll.offset
			s.view.scroll.motion.velocity = 0
			scroll_geometry_finish(m, s)
			return err
		}
	}
	return ""
}
scroll_begin_pan :: proc(m: ^Manager, s: ^Space) {
	v := &s.view
	if m.scroll_animate && v.scroll.motion.initialized {
		scroll_motion_sample(&v.scroll.motion, m.scroll_time)
		v.scroll.offset = v.scroll.motion.position
	}
	v.scroll.anchor = 0
	v.scroll.dragging = true
	v.scroll.motion.active = false
	scroll_update(v)
	scroll_anchor(v, v.scroll.focused)
}

Scroll_Snap :: struct {
	offset: f64,
	window: u32,
	centered: bool,
}
scroll_snap_target :: proc(v: ^View, position, velocity: f64) -> Scroll_Snap {
	projected := position + velocity * 0.332833083
	gap, width := scroll_gap(v), v.scroll.viewport.w
	leading, trailing := first(v.root), last(v.root)
	if leading == nil || leading.count == 0 {
		return {position, 0, false}
	}
	first_x := leading.frame.x - v.scroll.viewport.x + v.scroll.offset
	last_x := trailing.frame.x - v.scroll.viewport.x + v.scroll.offset
	minimum := first_x - min(gap, max(0, (width - leading.column_width) * 0.5))
	maximum := max(
		minimum,
		last_x +
		trailing.column_width -
		width +
		min(gap, max(0, (width - trailing.column_width) * 0.5)),
	)
	best := Scroll_Snap {
		offset = minimum,
		window = leading.order[0],
	}
	best_distance := f64(1e300)
	for n := leading; n != nil; n = next(n) {
		if n.count == 0 {
			continue
		}
		x := n.frame.x - v.scroll.viewport.x + v.scroll.offset
		padding := min(gap, max(0, (width - n.column_width) * 0.5))
		center :=
			v.scroll_options.center == .Always ||
			(v.scroll_options.center_single && leading == trailing)
		if v.scroll_options.center == .On_Overflow {
			left, right := previous(n), next(n)
			center =
				(left != nil &&
					left.column_width + n.column_width + 3 * gap > width) ||
				(right != nil &&
						right.column_width + n.column_width + 3 * gap > width)
		}
		candidates := [2]f64 {
			clamp(x - padding, minimum, maximum),
			clamp(x + n.column_width - width + padding, minimum, maximum),
		}
		if center {
			candidates = {
				n.column_width < width \
					? x + (n.column_width - width) * 0.5 \
					: x,
				n.column_width < width \
					? x + (n.column_width - width) * 0.5 \
					: x,
			}
		}
		for candidate in candidates {
			distance := math.abs(projected - candidate)
			if distance < best_distance ||
			   (distance == best_distance && candidate < best.offset) {
				best = {candidate, n.order[0], center}
				best_distance = distance
			}
		}
	}
	if !best.centered {
		for n := leading; n != nil; n = next(n) {
			x :=
				n.frame.x - v.scroll.viewport.x + v.scroll.offset - best.offset
			padding := min(gap, max(0, (width - n.column_width) * 0.5))
			if x >= padding - 0.001 &&
			   x + n.column_width <= width - padding + 0.001 {
				best.window = n.order[0]
				if projected < position {
					break
				}
			}
		}
	}
	return best
}
scroll_finish_pan :: proc(m: ^Manager, s: ^Space, velocity: f64) -> string {
	velocity := velocity
	v := &s.view
	if math.is_nan(velocity) || math.is_inf(velocity) {
		velocity = 0
	}
	velocity = clamp(velocity, -100000, 100000)
	v.scroll.dragging = false
	snap := scroll_snap_target(v, v.scroll.offset, velocity)
	if snap.window == 0 {
		return ""
	}
	if snap.window != m.focused {
		if err := perform(m, {kind = .Focus, window = snap.window});
		   err != "" {
			return err
		}
		focus_window(m, snap.window)
	}
	v.scroll.anchor = 0
	v.scroll.offset = snap.offset
	scroll_update(v)
	scroll_anchor(v, snap.window)
	v.scroll.focused, v.scroll.reveal = snap.window, false
	v.scroll.motion.velocity = velocity
	return flush(m, s)
}

Scroll_Velocity :: struct {
	samples: [64]struct {
		at, position: f64,
	},
	count: int,
	position: f64,
}
scroll_velocity_add :: proc(v: ^Scroll_Velocity, delta, at: f64) {
	if v.count > 0 && at <= v.samples[v.count - 1].at {
		return
	}
	v.position += delta
	start := 0
	for start < v.count && at - v.samples[start].at > 0.15 { start += 1 }
	if start > 0 {
		copy(v.samples[:], v.samples[start:v.count]); v.count -= start
	}
	if v.count == len(v.samples) {
		copy(v.samples[:], v.samples[1:]); v.count -= 1
	}
	v.samples[v.count] = {at, v.position}; v.count += 1
}
scroll_velocity_get :: proc(v: ^Scroll_Velocity) -> f64 {
	if v.count < 2 {
		return 0
	}
	a, b := v.samples[0], v.samples[v.count - 1]
	return (b.position - a.position) / (b.at - a.at)
}

pointer_follows_focus :: proc(m: ^Manager, w: ^Window) -> bool {
	if override, known := w.mouse_follows_focus.?; known {
		return override
	}
	if s := space_by_id(m, w.space);
	   s != nil &&
	   s.view.layout == .Scroll &&
	   !s.view.scroll_options.warp_pointer {
		return false
	}
	return m.mouse.follows_focus
}
