package shoji

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:math"
import objc "core:sys/darwin/Foundation"
import "core:time"

foreign import display_quartz "system:QuartzCore.framework"
foreign import frame_updates_sls "system:SkyLight.framework"

// Display clock and frame pacing
// ------------------------------------------------------------------------

// All callbacks and consumers run on the main run loop. One replaceable pulse
// avoids queuing obsolete animation work when a client blocks the daemon.
Frame_Pacer :: struct {
	pending: bool,
	target, last_callback, last_take, consumed_target: f64,
	period: f64,
	superseded: u64,
}
frame_pacer_pulse :: proc(p: ^Frame_Pacer, target, now, period: f64) {
	if math.is_nan(target) ||
	   math.is_inf(target) ||
	   target < now - 0.1 ||
	   target > now + 0.1 {
		return
	}
	if target <= p.consumed_target {
		return
	}
	if p.pending {
		p.superseded += 1
	}
	p.pending, p.target, p.last_callback = true, target, now
	if period > 0 && period <= .1 {
		p.period = period
	}
}
frame_pacer_take :: proc(
	p: ^Frame_Pacer,
	now: f64,
	linked: bool,
) -> (
	ready: bool,
	target: f64,
	fallback: bool,
) {
	if linked && p.pending {
		p.pending = false
		p.last_take, p.consumed_target = now, p.target
		return true, max(now, p.target), false
	}
	// A missing/paused display must not strand windows. Throttle fallback too.
	if (!linked || now - p.last_callback >= 0.1) &&
	   now - p.last_take >= 1.0 / 60 {
		p.last_take = now
		return true, now, true
	}
	return false, now, false
}
Display_Clock :: struct {
	listener, link: ^objc.Object,
	display: u32,
	running: bool,
	retry_at: f64,
	pacer: Frame_Pacer,
}
foreign display_quartz { CACurrentMediaTime :: proc "c" () -> f64 --- }
display_listener_class: objc.Class
display_listeners: map[rawptr]^Display_Clock

display_clock_callback :: proc "c" (
	object: ^objc.Object,
	_: objc.SEL,
	sender: ^objc.Object,
) {
	context = runtime.default_context()
	clock := display_listeners[rawptr(object)]
	if clock == nil || !clock.running {
		return
	}
	frame_pacer_pulse(
		&clock.pacer,
		intrinsics.objc_send(f64, sender, "targetTimestamp"),
		CACurrentMediaTime(),
		intrinsics.objc_send(f64, sender, "duration"),
	)
}
display_clock_stop :: proc(clock: ^Display_Clock) {
	if clock.link != nil {
		intrinsics.objc_send(nil, clock.link, "invalidate")
		intrinsics.objc_send(nil, clock.link, "release")
	}
	if clock.listener != nil {
		delete_key(&display_listeners, rawptr(clock.listener))
		intrinsics.objc_send(nil, clock.listener, "release")
	}
	clock^ = {}
	if len(display_listeners) == 0 {
		delete(display_listeners); display_listeners = nil
	}
}
// An unsuccessful creation records a retry deadline, not permanent success.
display_clock_should_create :: proc(
	clock: ^Display_Clock,
	display: u32,
	now: f64,
) -> bool {
	if clock.link != nil {
		return false
	}
	if clock.display != display {
		clock.display = display; clock.retry_at = 0
	}
	if now < clock.retry_at {
		return false
	}
	clock.retry_at = now + .5
	return true
}
display_clock_prepare :: proc(
	clock: ^Display_Clock,
	display: u32,
	moving: bool,
	now: f64 = 0,
) {
	now := now
	if now == 0 {
		now = CACurrentMediaTime()
	}
	if clock.display != display {
		display_clock_stop(clock)
	}
	if !moving {
		if clock.link != nil && clock.running {
			intrinsics.objc_send(nil, clock.link, "setPaused:", bool(true))
		}
		clock.running = false; clock.pacer.pending = false
		return
	}
	if display_clock_should_create(clock, display, now) {
		created := false
		defer {
			if !created {
				retry, pacer := clock.retry_at, clock.pacer
				display_clock_stop(clock)
				clock.display, clock.retry_at = display, retry
				clock.pacer = pacer
			}
		}
		if display_listener_class == nil {
			display_listener_class = objc.objc_allocateClassPair(
				objc.objc_lookUpClass("NSObject"),
				"ShojiDisplayClock",
				0,
			)
			if display_listener_class == nil {
				return
			}
			if !objc.class_addMethod(
				display_listener_class,
				objc.sel_registerName("frame:"),
				cast(objc.IMP)display_clock_callback,
				"v@:@",
			) {
				objc.objc_disposeClassPair(display_listener_class)
				display_listener_class = nil
				return
			}
			objc.objc_registerClassPair(display_listener_class)
		}
		screens := intrinsics.objc_send(
			^objc.Object,
			(^objc.Object)(objc.objc_lookUpClass("NSScreen")),
			"screens",
		)
		count := intrinsics.objc_send(int, screens, "count")
		screen: ^objc.Object
		for i in 0 ..< count {
			candidate := intrinsics.objc_send(
				^objc.Object,
				screens,
				"objectAtIndex:",
				i,
			)
			description := intrinsics.objc_send(
				^objc.Object,
				candidate,
				"deviceDescription",
			)
			key := cf_string("NSScreenNumber")
			number := intrinsics.objc_send(
				^objc.Object,
				description,
				"objectForKey:",
				(^objc.Object)(key),
			); CFRelease(key)
			if intrinsics.objc_send(u32, number, "unsignedIntValue") ==
			   display {
				screen = candidate; break
			}
		}
		if screen == nil ||
		   !intrinsics.objc_send(
				   bool,
				   screen,
				   "respondsToSelector:",
				   objc.sel_registerName("displayLinkWithTarget:selector:"),
			   ) {
			return
		}
		clock.listener = intrinsics.objc_send(
			^objc.Object,
			(^objc.Object)(display_listener_class),
			"new",
		)
		if clock.listener == nil {
			return
		}
		if display_listeners == nil {
			display_listeners = make(map[rawptr]^Display_Clock)
		}
		display_listeners[rawptr(clock.listener)] = clock
		clock.link = intrinsics.objc_send(
			^objc.Object,
			screen,
			"displayLinkWithTarget:selector:",
			clock.listener,
			objc.sel_registerName("frame:"),
		)
		if clock.link == nil {
			return
		}
		intrinsics.objc_send(nil, clock.link, "retain")
		intrinsics.objc_send(
			nil,
			clock.link,
			"addToRunLoop:forMode:",
			objc.RunLoop_mainRunLoop(),
			objc.RunLoopCommonModes,
		)
		created = true
	}
	if clock.link != nil && !clock.running {
		clock.running = true
		clock.pacer.last_callback = CACurrentMediaTime()
		intrinsics.objc_send(nil, clock.link, "setPaused:", bool(false))
	}
}
// Convert only the short relative prediction; CA uptime and wall time are
// different epochs. Action processing keeps its actual-time clock separately.
display_clock_take :: proc(
	clock: ^Display_Clock,
	now: time.Time,
) -> (
	bool,
	time.Time,
	bool,
) {
	ready, target, fallback := frame_pacer_take(
		&clock.pacer,
		CACurrentMediaTime(),
		clock.link != nil && clock.running,
	)
	lead := clamp(target - CACurrentMediaTime(), 0, .05)
	return ready,
		time.time_add(now, time.Duration(lead * f64(time.Second))),
		fallback
}

// Nested presentation batches
// ------------------------------------------------------------------------

Frame_Updates :: struct {
	depth: int,
	user: rawptr,
	set_enabled: proc(user: rawptr, connection: i32, enabled: bool) -> i32,
}

foreign frame_updates_sls {
	SLSDisableUpdate :: proc "c" (connection: i32) -> i32 ---
	SLSReenableUpdate :: proc "c" (connection: i32) -> i32 ---
}

frame_updates_set :: proc(state: ^State, enabled: bool) -> i32 {
	if state.frame_updates.set_enabled != nil {
		return state.frame_updates.set_enabled(
			state.frame_updates.user,
			state.connection,
			enabled,
		)
	}
	if state.connection == 0 {
		return 0
	}
	return(
		enabled \
			? SLSReenableUpdate(state.connection) \
			: SLSDisableUpdate(state.connection) \
	)
}

frame_updates_begin :: proc(state: ^State) -> string {
	if state.frame_updates.depth == 0 {
		if code := frame_updates_set(state, false); code != 0 {
			return fmt.tprintf(
				"could not begin frame presentation batch (%d)",
				code,
			)
		}
	}
	state.frame_updates.depth += 1
	return ""
}

frame_updates_end :: proc(state: ^State) -> string {
	if state.frame_updates.depth <= 0 {
		return "unbalanced frame presentation batch"
	}
	state.frame_updates.depth -= 1
	if state.frame_updates.depth == 0 {
		if code := frame_updates_set(state, true); code != 0 {
			return fmt.tprintf("could not present frame batch (%d)", code)
		}
	}
	return ""
}

// Coordinated motion ticks
// ------------------------------------------------------------------------

motion_active :: proc(state: ^State) -> bool {
	if len(state.animations) > 0 ||
	   len(state.resize_covers) > 0 ||
	   state.mouse.scroll_tracking ||
	   stack_touch_has_pending() ||
	   state.mouse.drag.window != 0 {
		return true
	}
	for s in state.manager.spaces {
		if s.visible &&
		   s.view.layout == .Scroll &&
		   (s.view.scroll.dragging || s.view.scroll.motion.active || s.view.scroll.geometry_active) {
			return true
		}
	}
	return false
}

// One display pulse, one fixed sample time and one presentation batch for
// native geometry and its content covers. Nested AX/scroll batches stay inside
// this boundary; no overlay is presented ahead of its corresponding frame.
motion_frame_tick :: proc(
	state: ^State,
	ready: bool,
	sample_now: time.Time,
	uptime: f64,
) {
	if !ready {
		mouse_tick(state, false, sample_now)
		if !state.manager.resize_fade || state.resize_cover_cancel {
			resize_cover_tick(state, uptime)
		}
		focus_ring_tick(state)
		return
	}
	active := motion_active(state)
	if active {
		if err := frame_updates_begin(state); err != "" {
			fmt.eprintln("shoji: motion:", err); return
		}
	}
	defer {
		if active {
			if err := frame_updates_end(state); err != "" {
				fmt.eprintln("shoji: motion:", err)
			}
		}
	}
	// Registered after the update-end defer, so the submit runs first and
	// still inside the disabled section. The hold stays off unless a batch
	// exists, which keeps tests and unbatched flushes on the immediate path.
	hold := active && state.manager.layout_batch != nil
	state.manager.camera_hold = hold
	state.frame_owned_count = 0
	defer {
		if hold {
			owned := state.frame_owned[:state.frame_owned_count]
			if !layout_frame_submit(&state.manager, owned) {
				feedback_owned_fallback(state)
			}
		}
		state.manager.camera_hold = false
		state.frame_owned_count = 0
	}
	state.manager.scroll_time = time.duration_seconds(
		time.diff(time.Time{}, sample_now),
	)
	animation_tick(state, sample_now)
	mouse_tick(state, true, sample_now)
	scroll_native_tick(state, sample_now)
	resize_cover_tick(state, uptime)
	focus_ring_tick(state)
}
