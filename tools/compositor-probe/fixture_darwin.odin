package main

import e "../../src/engine"
import mac "../../src/macos"
import "core:os"
import objc "core:sys/darwin/Foundation"
import "core:sys/posix"
import "core:time"

fixture :: proc(parent: int) -> int {
	// OS-enforced lifetime still disposes both windows if AppKit blocks or the
	// controller crashes. SIGALRM's default disposition terminates this fixture.
	posix.signal(.SIGALRM, nil)
	alarm(45)
	mac.NSApplicationLoad()
	pool := mac.pool_push(); defer mac.pool_pop(pool)
	app := send(^objc.Object, Application, "sharedApplication")
	send(bool, app, "setActivationPolicy:", int(1))
	send(nil, app, "finishLaunching")
	connection := mac.SLSMainConnectionID()
	if connection == 0 {
		emit({event = "no_windowserver", pid = mac.getpid()}); return 3
	}
	back := make_window("Shoji clip probe — BLUE background", true)
	defer close_window(back)
	front := make_window("Shoji clip probe — disposable GREEN target", false)
	defer close_window(front)
	if back == nil || front == nil {
		emit({event = "window_creation_failed"}); return 3
	}
	id := u32(send(int, front, "windowNumber"))
	background := u32(send(int, back, "windowNumber"))
	if id == 0 || background == 0 {
		emit({event = "window_creation_failed"}); return 3
	}
	// A new AppKit window can return success with zero WindowServer bounds
	// before its initial updates have been processed. Never clip that rectangle.
	geometry := Geometry_Context{app, id, background}
	frame, frame_code, geometry_ready := await_geometry(
		&geometry,
		native_geometry,
		geometry_pump,
		connection,
		id,
		200,
	)
	if !geometry_ready {
		emit(
			{
				event = "geometry_unavailable",
				phase = "geometry",
				pid = mac.getpid(),
				connection = connection,
				window = id,
				background = background,
				code = frame_code,
				frame = frame,
			},
		)
		return 3
	}
	// A disposable fixture gets an explicit rectangular baseline. We never
	// assume nil resets clipping, nor apply a guessed baseline to a user's app.
	full := e.Rect{0, 0, frame.w, frame.h}
	emit(
		{
			event = "baseline_requested",
			phase = "baseline",
			pid = mac.getpid(),
			connection = connection,
			window = id,
			background = background,
			frame = frame,
			expected_clip = full,
		},
	)
	baseline: mac.Ref
	if CGSNewRegionWithRect(&full, &baseline) != 0 || baseline == nil {
		return 3
	}
	defer CGSReleaseRegion(baseline)
	SLSSetWindowClipShape(connection, id, baseline)
	defer SLSSetWindowClipShape(connection, id, baseline)
	ready := wait_for_clip(
		app,
		"ready",
		"baseline",
		connection,
		id,
		background,
		full,
	)
	if !clip_matches(ready, full) {
		ready.event = "baseline_unverified"; emit(ready); return 3
	}
	emit(ready)
	phase := "baseline"
	active := false
	began := time.now(); phase_began := began; last_observation := began
	for time.diff(began, time.now()) < 45 * time.Second &&
	    os.get_ppid() == parent {
		pump(app, phase, id, background)
		available, pipe_err := os.pipe_has_data(os.stdin)
		if pipe_err != nil {
			return 0
		}
		if available {
			command: [1]u8
			n, err := os.read(os.stdin, command[:])
			if err != nil || n != 1 {
				return 0
			}
			switch command[0] {
			case 'Q':
				return 0
			case 'P', 'F':
				if active {
					return 3
				}
				phase = command[0] == 'P' ? "owned_clip" : "foreign_clip"
				phase_began = time.now(); active = true
				if command[0] == 'P' {
					half := full; half.w *= 0.5
					region: mac.Ref
					if CGSNewRegionWithRect(&half, &region) != 0 ||
					   region == nil {
						return 3
					}
					code := SLSSetWindowClipShape(connection, id, region)
					CGSReleaseRegion(region)
					emit(
						{
							event = "setter_return",
							phase = phase,
							code = code,
							window = id,
							pid = mac.getpid(),
							connection = connection,
						},
					)
				} else {
					emit(
						{
							event = "foreign_armed",
							phase = phase,
							window = id,
							pid = mac.getpid(),
						},
					)
				}
			}
		}
		if active && time.diff(last_observation, time.now()) >= time.Second {
			emit(observe("readback", phase, connection, id, background))
			last_observation = time.now()
		}
		if active && time.diff(phase_began, time.now()) >= 10 * time.Second {
			SLSSetWindowClipShape(connection, id, baseline)
			o := wait_for_clip(
				app,
				"restored",
				phase,
				connection,
				id,
				background,
				full,
			)
			if !clip_matches(o, full) {
				o.event = "restore_unverified"; emit(o); return 3
			}
			emit(o); active = false; phase = "baseline"
		}
	}
	return 0
}
