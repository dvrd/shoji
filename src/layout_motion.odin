package shoji

import "core:math"
import "core:encoding/json"
import "core:time"

// Window animation
// ------------------------------------------------------------------------

Easing :: enum {
	Linear,
	In_Sine,
	Out_Sine,
	In_Out_Sine,
	In_Quad,
	Out_Quad,
	In_Out_Quad,
	In_Cubic,
	Out_Cubic,
	In_Out_Cubic,
	In_Quart,
	Out_Quart,
	In_Out_Quart,
	In_Quint,
	Out_Quint,
	In_Out_Quint,
	In_Expo,
	Out_Expo,
	In_Out_Expo,
	In_Circ,
	Out_Circ,
	In_Out_Circ,
}
EASING_NAMES := []string {
	"linear",
	"ease_in_sine",
	"ease_out_sine",
	"ease_in_out_sine",
	"ease_in_quad",
	"ease_out_quad",
	"ease_in_out_quad",
	"ease_in_cubic",
	"ease_out_cubic",
	"ease_in_out_cubic",
	"ease_in_quart",
	"ease_out_quart",
	"ease_in_out_quart",
	"ease_in_quint",
	"ease_out_quint",
	"ease_in_out_quint",
	"ease_in_expo",
	"ease_out_expo",
	"ease_in_out_expo",
	"ease_in_circ",
	"ease_out_circ",
	"ease_in_out_circ",
}

ease :: proc(kind: Easing, t: f64) -> f64 {
	t := clamp(t, 0, 1)
	if t == 0 || t == 1 {return t}
	#partial switch kind {
	case .Linear:
		return t
	case .In_Sine:
		return 1 - math.cos(t * math.PI / 2)
	case .Out_Sine:
		return math.sin(t * math.PI / 2)
	case .In_Out_Sine:
		return (1 - math.cos(t * math.PI)) / 2
	case .In_Expo:
		return math.pow(2, 10 * t - 10)
	case .Out_Expo:
		return 1 - math.pow(2, -10 * t)
	case .In_Out_Expo:
		return t < 0.5 ? math.pow(2, 20 * t - 10) / 2 : (2 - math.pow(2, -20 * t + 10)) / 2
	case .In_Circ:
		return 1 - math.sqrt(1 - t * t)
	case .Out_Circ:
		return math.sqrt(1 - (t - 1) * (t - 1))
	case .In_Out_Circ:
		return(
			t < 0.5 \
			? (1 - math.sqrt(1 - 4 * t * t)) / 2 \
			: (math.sqrt(1 - math.pow(-2 * t + 2, 2)) + 1) / 2 \
		)
	case:
	}
	index := int(kind) - int(Easing.In_Quad)
	power := f64(index / 3 + 2)
	switch index % 3 {
	case 0:
		return math.pow(t, power)
	case 1:
		return 1 - math.pow(1 - t, power)
	case 2:
		return(
			t < 0.5 \
			? math.pow(2, power - 1) * math.pow(t, power) \
			: 1 - math.pow(-2 * t + 2, power) / 2 \
		)
	}
	return t
}

interpolate_frame :: proc(from, to: Rect, progress: f64, kind: Easing) -> Rect {
	t := ease(kind, progress)
	return {
		from.x + (to.x - from.x) * t,
		from.y + (to.y - from.y) * t,
		from.w + (to.w - from.w) * t,
		from.h + (to.h - from.h) * t,
	}
}

// Viewport springs
// ------------------------------------------------------------------------

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
scroll_finish_pan :: proc(m: ^Manager, s: ^Space, velocity: f64, prevent_overshoot: bool = false, step: i32 = 0) -> string {
	velocity := velocity
	v := &s.view
	if math.is_nan(velocity) || math.is_inf(velocity) {
		velocity = 0
	}
	velocity = clamp(velocity, -100000, 100000)
	v.scroll.dragging = false
	snap := scroll_snap_target(v, v.scroll.offset, velocity)
	if step != 0 {
		current := find(v.root, m.focused)
		neighbor := step > 0 ? next(current) : previous(current)
		if neighbor != nil && neighbor.count > 0 {
			// Reveal only the adjacent column, independently of fling speed.
			before := v.scroll.offset
			scroll_reveal(v, neighbor.order[0])
			snap = {offset = v.scroll.offset, window = neighbor.order[0]}
			v.scroll.offset = before; scroll_update(v)
		}
	}
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
	if prevent_overshoot {
		distance := snap.offset - v.scroll.motion.position
		velocity = distance >= 0 \
			? clamp(velocity, 0, SCROLL_SPRING_OMEGA * distance) \
			: clamp(velocity, SCROLL_SPRING_OMEGA * distance, 0)
	}
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

// Animated geometry
// ------------------------------------------------------------------------

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

// Motion traces
// ------------------------------------------------------------------------

// Opt-in bounded memory capture: no file I/O or logging on the animation path.
// Native bounds and AX completion are observations, not display presentation.
MOTION_TRACE_LIMIT :: 8192
MOTION_TRACE_SECONDS :: 30.0
Motion_Event :: struct {
	kind: string,
	at_ms, duration_ms, source_time, value: f64,
	space: u64,
	window: u32,
	requested, observed: Rect,
	status: i32,
}
Motion_Trace :: struct {
	active, full, expired: bool,
	started: time.Tick,
	events: [dynamic]Motion_Event,
}
Motion_Export :: struct {
	version: int,
	active, full, expired: bool,
	limit: int,
	clock: string,
	events: []Motion_Event,
}
motion_trace_record :: proc(trace: ^Motion_Trace, event: Motion_Event, now: time.Tick = {}) {
	if !trace.active {return}
	now := now
	if now == (time.Tick{}) {now = time.tick_now()}
	elapsed := time.duration_seconds(time.tick_diff(trace.started, now))
	if elapsed >= MOTION_TRACE_SECONDS {trace.active = false; trace.expired = true; return}
	if len(trace.events) >= MOTION_TRACE_LIMIT {trace.active = false; trace.full = true; return}
	event := event
	event.at_ms = elapsed * 1000
	append(&trace.events, event)
}
motion_debug :: proc(m: ^Manager, args: []string) -> Response {
	if len(args) != 2 || args[0] != "motion" {return failure("debug expects motion start|stop|dump|clear")}
	t := &m.motion_trace
	switch args[1] {
	case "start":
		delete(t.events)
		t^ = {active = true, started = time.tick_now(), events = make([dynamic]Motion_Event, 0, MOTION_TRACE_LIMIT)}
		return success("motion capture started (30 seconds or 8192 events)")
	case "stop": t.active = false; return success("motion capture stopped")
	case "clear": delete(t.events); t^ = {}; return success()
	case "dump":
		motion_trace_record(t, {kind = "dump"})
		data, err := json.marshal(Motion_Export{1, t.active, t.full, t.expired, MOTION_TRACE_LIMIT, "monotonic milliseconds since capture start; source_time is CGEvent uptime for input, Core Animation uptime for presentation-tick", t.events[:]}, allocator = context.temp_allocator)
		if err != nil {return failure("could not encode motion trace")}
		return success(string(data))
	}
	return failure("debug expects motion start|stop|dump|clear")
}
