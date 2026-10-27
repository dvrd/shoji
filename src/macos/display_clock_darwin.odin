package macos

import "base:intrinsics"
import "base:runtime"
import "core:math"
import objc "core:sys/darwin/Foundation"
import "core:time"

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
	pacer: Frame_Pacer,
}
foreign import display_quartz "system:QuartzCore.framework"
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
display_clock_prepare :: proc(
	clock: ^Display_Clock,
	display: u32,
	moving: bool,
) {
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
	if clock.link == nil && clock.display != display {
		clock.display = display
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
