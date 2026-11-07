package shoji

import "core:fmt"
import "core:time"
import layout "layout"

// Scroll layout and viewport
// ------------------------------------------------------------------------

foreign import scroll_cg "system:CoreGraphics.framework"
foreign scroll_cg {
	CGEventGetTimestamp :: proc "c" (event: Ref) -> u64 ---
}

mouse_scroll_event :: proc(state: ^State, event: Ref, now: time.Time) -> bool {
	m := &state.manager
	space := u64(0)
	mode := layout.Layout.Float
	if display := display_by_id(m, m.mouse_display); display != nil {
		if s := space_by_id(m, display.active_space);
		   s != nil && (s.view.layout == .Scroll || s.view.layout == .BSP) {
			space = s.id
			mode = s.view.layout
		}
	}
	// CGEventTypes.h: continuous events report pixel deltas; ordinary wheels
	// report lines. Use exactly one representation, never sum both fields.
	continuous := CGEventGetIntegerValueField(event, 88) != 0
	xfield, yfield := u32(12), u32(11)
	if continuous {
		xfield, yfield = 97, 96
	}
	x := f64(CGEventGetIntegerValueField(event, xfield))
	y := f64(CGEventGetIntegerValueField(event, yfield))
	if !continuous {
		x *= 24; y *= 24
	}
	old_space := state.mouse.scroll.space
	phase := u64(CGEventGetIntegerValueField(event, 99))
	momentum := CGEventGetIntegerValueField(event, 123)
	seconds := time.duration_seconds(time.diff(time.Time{}, now))
	event_seconds := f64(CGEventGetTimestamp(event)) / 1e9
	consume, delta, direction := layout_gesture_route(
		&state.mouse.scroll,
		{x, y, CGEventGetFlags(event) & MOUSE_MODIFIERS, phase, momentum},
		space,
		mode,
		m.mouse.modifier,
		m.mouse.scroll && !(m.mouse.three_finger_horizontal && state.stack_touch.library != nil),
		seconds,
	)
	if consume {
		motion_trace_record(
			&m.motion_trace,
			{
				kind = "input",
				source_time = event_seconds,
				space = state.mouse.scroll.space,
				value = delta,
			},
		)
		if old_space != state.mouse.scroll.space {
			state.mouse.scroll_delta = 0
		}
		if state.mouse.scroll.layout == .Scroll && momentum == 0 {
			mouse := &state.mouse
			if !mouse.scroll_tracking ||
			   old_space != mouse.scroll.space ||
			   phase & 1 != 0 {
				mouse.scroll_velocity = {}
				mouse.scroll_delta = 0
				mouse.scroll_tracking, mouse.scroll_begin, mouse.scroll_end =
					true, true, false
			}
			mouse.scroll_phase_less = phase == 0
			if continuous {
				if s := space_by_id(m, mouse.scroll.space); s != nil {
					delta *= s.view.scroll.viewport.w / 1200
				}
			}
			mouse.scroll_delta += delta
			scroll_velocity_add(&mouse.scroll_velocity, delta, event_seconds)
			mouse.scroll_last = seconds
			if phase & (4 | 8) != 0 {
				mouse.scroll_end = true
			}
		}
		if direction != 0 && state.mouse.space_direction == 0 {
			state.mouse.space_origin = state.mouse.scroll.space
			state.mouse.space_direction = direction
		}
	}
	return consume
}

scroll_input_tick :: proc(state: ^State, now: time.Time) {
	mouse := &state.mouse
	if !mouse.scroll_tracking {
		return
	}
	m := &state.manager
	s := space_by_id(m, mouse.scroll.space)
	if s == nil ||
	   !s.visible ||
	   s.view.layout != .Scroll ||
	   m.suspended ||
	   m.gesture_active {
		if s != nil {
			s.view.scroll.dragging = false
		}
		mouse.scroll_tracking, mouse.scroll_begin, mouse.scroll_end =
			false, false, false
		mouse.scroll_delta = 0
		return
	}
	seconds := time.duration_seconds(time.diff(time.Time{}, now))
	if (mouse.scroll_phase_less && seconds - mouse.scroll_last >= 0.12) ||
	   seconds - mouse.scroll_last > 1 {
		scroll_velocity_add(&mouse.scroll_velocity, 0, seconds)
		mouse.scroll_end = true
	}
	if !mouse.scroll_begin && mouse.scroll_delta == 0 && !mouse.scroll_end {
		return
	}
	if err := frame_updates_begin(state); err != "" {
		fmt.eprintln("shoji: scroll:", err); return
	}
	defer {
		if err := frame_updates_end(state); err != "" {
			fmt.eprintln("shoji: scroll:", err)
		}
	}
	started: time.Tick
	if m.motion_trace.active {
		started = time.tick_now()
	}
	defer motion_trace_record(
		&m.motion_trace,
		{
			kind = "gesture-sample",
			space = s.id,
			duration_ms = m.motion_trace.active \
				? f64(time.tick_since(started)) / 1e6 \
				: 0,
		},
	)
	motion_trace_record(
		&m.motion_trace,
		{kind = "input-consume", space = s.id, value = mouse.scroll_delta},
	)
	if mouse.scroll_begin {
		scroll_begin_pan(m, s); mouse.scroll_begin = false
	}
	delta := mouse.scroll_delta; mouse.scroll_delta = 0
	if delta != 0 {
		if err := scroll_gesture_pan(m, s.id, delta); err != "" {
			fmt.eprintln("shoji: scroll:", err); s.view.scroll.dragging = false
			mouse.scroll_tracking = false; return
		}
	}
	if mouse.scroll_end {
		mouse.scroll_end, mouse.scroll_tracking = false, false
		if err := scroll_finish_pan(
			m,
			s,
			scroll_velocity_get(&mouse.scroll_velocity),
		); err != "" {
			fmt.eprintln("shoji: scroll release:", err)
		}
	}
}

scroll_native_tick :: proc(state: ^State, now: time.Time) {
	active := false
	for s in state.manager.spaces {
		if s.view.scroll.motion.active || s.view.scroll.geometry_active {
			active = true; break
		}
	}
	if !active {
		return
	}
	started: time.Tick
	if state.manager.motion_trace.active {
		started = time.tick_now()
	}
	defer motion_trace_record(
		&state.manager.motion_trace,
		{
			kind = "sample",
			duration_ms = state.manager.motion_trace.active \
				? f64(time.tick_since(started)) / 1e6 \
				: 0,
		},
	)
	if err := frame_updates_begin(state); err != "" {
		fmt.eprintln("shoji: scroll:", err); return
	}
	defer {
		if err := frame_updates_end(state); err != "" {
			fmt.eprintln("shoji: scroll:", err)
		}
	}
	if err := scroll_motion_tick(
		&state.manager,
		time.duration_seconds(time.diff(time.Time{}, now)),
	); err != "" {
		fmt.eprintln("shoji: scroll motion:", err)
	}
}
