package main

import e "../../src/engine"
import mac "../../src/macos"
import "base:intrinsics"
import "core:encoding/json"
import "core:os"
import objc "core:sys/darwin/Foundation"
import "core:time"

// ABI is pinned to the read-only inspection in docs/COMPOSITOR_PROBE_ABI.md.
foreign import skylight "system:SkyLight.framework"
@(default_calling_convention = "c")
foreign skylight {
	SLSSetWindowClipShape :: proc(connection: i32, window: u32, region: mac.Ref) -> i32 ---
	SLSCopyWindowClipShape :: proc(connection: i32, window: u32, region: ^mac.Ref) -> i32 ---
	SLSGetWindowOwner :: proc(connection: i32, window: u32, owner: ^i32) -> i32 ---
	CGSNewRegionWithRect :: proc(rect: ^e.Rect, region: ^mac.Ref) -> i32 ---
	CGSReleaseRegion :: proc(region: mac.Ref) -> i32 ---
	CGSGetRegionBounds :: proc(region: mac.Ref, bounds: ^e.Rect) -> i32 ---
	SLSFindWindowAndOwner :: proc(connection, filter, traversal, options: i32, point, local: ^mac.Point, window: ^u32, owner: ^i32) -> i32 ---
}

@(objc_class = "NSApplication")
Application :: struct {
	using _: objc.Object,
}
@(objc_class = "NSWindow")
Window :: struct {
	using _: objc.Object,
}
@(objc_class = "NSColor")
Color :: struct {
	using _: objc.Object,
}
@(objc_class = "NSTextField")
Label :: struct {
	using _: objc.Object,
}
@(objc_class = "NSDate")
Date :: struct {
	using _: objc.Object,
}
send :: intrinsics.objc_send

Geometry_Context :: struct {
	app: ^objc.Object,
	target, background: u32,
}
native_geometry :: proc(
	_: rawptr,
	connection: i32,
	window: u32,
	frame: ^e.Rect,
) -> i32 {
	return mac.SLSGetWindowBounds(connection, window, frame)
}
geometry_pump :: proc(user: rawptr) {
	g := (^Geometry_Context)(user)
	pump(g.app, "geometry", g.target, g.background)
}
foreign import system "system:System"
foreign system { alarm :: proc "c" (seconds: u32) -> u32 --- }

Observation :: struct {
	event, phase: string,
	pid, connection, owner: i32,
	window, background: u32,
	code, bounds_code: i32,
	clip_present: bool,
	clip, frame: e.Rect,
	expected_clip: e.Rect,
	location: mac.Point,
	left_hit, right_hit: u32,
	left_hit_code, right_hit_code, left_owner, right_owner: i32,
}

emit :: proc(o: Observation, file: ^os.File = os.stdout) {
	bytes, err := json.marshal(o)
	if err != nil {
		return
	}
	defer delete(bytes)
	os.write(file, bytes)
	os.write(file, []u8{'\n'})
}

close_window :: proc(w: ^objc.Object) {
	if w != nil {
		send(nil, w, "close"); send(nil, w, "release")
	}
}

make_window :: proc(title: string, blue: bool) -> ^objc.Object {
	w := send(^objc.Object, Window, "alloc")
	w = send(
		^objc.Object,
		w,
		"initWithContentRect:styleMask:backing:defer:",
		e.Rect{180, 200, 520, 300},
		uint(1),
		uint(2),
		bool(false),
	)
	if w == nil {
		return nil
	}
	send(nil, w, "setReleasedWhenClosed:", bool(false))
	send(nil, w, "setLevel:", int(3))
	t := mac.cf_string(title); send(nil, w, "setTitle:", (^objc.Object)(t))
	mac.CFRelease(t)
	color := send(
		^objc.Object,
		Color,
		"colorWithCalibratedRed:green:blue:alpha:",
		blue ? f64(0.15) : f64(0.2),
		blue ? f64(0.4) : f64(0.65),
		blue ? f64(0.85) : f64(0.25),
		f64(1),
	)
	send(nil, w, "setBackgroundColor:", color)
	text := mac.cf_string(
		blue \
			? "BLUE BACKGROUND: clipped clicks should land here" \
			: "GREEN TARGET: watch the right half disappear",
	)
	label := send(
		^objc.Object,
		Label,
		"labelWithString:",
		(^objc.Object)(text),
	); mac.CFRelease(text)
	send(nil, label, "setFrame:", e.Rect{20, 120, 490, 40})
	view := send(^objc.Object, w, "contentView")
	send(nil, view, "addSubview:", label)
	send(nil, w, "orderFrontRegardless")
	return w
}

pump :: proc(app: ^objc.Object, phase: string, target, background: u32) {
	// Local dispatch observes real mouse events; no synthetic click can escape
	// the fixture into an unrelated application.
	for _ in 0 ..< 32 {
		until := send(
			^objc.Object,
			Date,
			"dateWithTimeIntervalSinceNow:",
			f64(0),
		)
		event := send(
			^objc.Object,
			app,
			"nextEventMatchingMask:untilDate:inMode:dequeue:",
			~uint(0),
			until,
			(^objc.Object)(mac.kCFRunLoopDefaultMode),
			bool(true),
		)
		if event == nil {
			break
		}
		if send(uint, event, "type") == 1 {
			id := u32(send(int, event, "windowNumber"))
			if id == target || id == background {
				emit(
					{
						event = "mouse_down",
						phase = phase,
						pid = mac.getpid(),
						window = id,
						background = background,
						location = send(mac.Point, event, "locationInWindow"),
					},
				)
			}
		}
		send(nil, app, "sendEvent:", event)
		if send(uint, event, "type") == 1 &&
		   u32(send(int, event, "windowNumber")) == background {
			// Clicking the exposed background must not leave it covering the
			// target for the rest of the experiment.
			front := send(
				^objc.Object,
				app,
				"windowWithWindowNumber:",
				int(target),
			)
			if front != nil {
				send(nil, front, "orderFrontRegardless")
			}
		}
	}
	mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, 0.01, true)
}

observe :: proc(
	event, phase: string,
	connection: i32,
	target, background: u32,
) -> Observation {
	o := Observation {
		event      = event,
		phase      = phase,
		pid        = mac.getpid(),
		connection = connection,
		window     = target,
		background = background,
	}
	SLSGetWindowOwner(connection, target, &o.owner)
	mac.SLSGetWindowBounds(connection, target, &o.frame)
	region: mac.Ref
	o.code = SLSCopyWindowClipShape(connection, target, &region)
	o.clip_present = region != nil
	o.bounds_code = -1
	if region != nil {
		o.bounds_code = CGSGetRegionBounds(region, &o.clip)
		CGSReleaseRegion(region)
	}
	left := mac.Point {
		o.frame.x + o.frame.w * 0.25,
		o.frame.y + o.frame.h * 0.5,
	}
	right := mac.Point {
		o.frame.x + o.frame.w * 0.75,
		o.frame.y + o.frame.h * 0.5,
	}
	local: mac.Point
	o.left_hit_code = SLSFindWindowAndOwner(
		connection,
		0,
		1,
		0,
		&left,
		&local,
		&o.left_hit,
		&o.left_owner,
	)
	o.right_hit_code = SLSFindWindowAndOwner(
		connection,
		0,
		1,
		0,
		&right,
		&local,
		&o.right_hit,
		&o.right_owner,
	)
	return o
}

wait_for_clip :: proc(
	app: ^objc.Object,
	event, phase: string,
	connection: i32,
	target, background: u32,
	expected: e.Rect,
) -> Observation {
	began := time.now()
	o: Observation
	for {
		pump(app, phase, target, background)
		o = observe(event, phase, connection, target, background)
		o.expected_clip = expected
		if clip_matches(o, expected) ||
		   time.diff(began, time.now()) >= 2 * time.Second {
			return o
		}
	}
}
