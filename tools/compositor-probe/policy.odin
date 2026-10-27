package main

import e "../../src/engine"
import "core:fmt"
import "core:math"

await_geometry :: proc(
	user: rawptr,
	query: proc(
		user: rawptr,
		connection: i32,
		window: u32,
		frame: ^e.Rect,
	) -> i32,
	pump_events: proc(user: rawptr),
	connection: i32,
	window: u32,
	attempts: int,
) -> (
	frame: e.Rect,
	code: i32,
	ready: bool,
) {
	code = -1
	for _ in 0 ..< attempts {
		pump_events(user)
		frame = {}
		code = query(user, connection, window, &frame)
		if code == 0 &&
		   frame.w > 0 &&
		   frame.h > 0 &&
		   frame.w < 10000 &&
		   frame.h < 10000 {
			return frame, code, true
		}
	}
	return
}

failure_message :: proc(o: Observation) -> string {
	return fmt.tprintf(
		"Probe stopped: %s during %s. Clip requested=%v; observed=%v; current frame=%v; readback=%d, region bounds=%d, region present=%v. No foreign clipping capability established.",
		o.event,
		o.phase,
		o.expected_clip,
		o.clip,
		o.frame,
		o.code,
		o.bounds_code,
		o.clip_present,
	)
}

clip_matches :: proc(o: Observation, expected: e.Rect) -> bool {
	return(
		o.code == 0 &&
		o.clip_present &&
		o.bounds_code == 0 &&
		math.abs(o.clip.x - expected.x) < 0.5 &&
		math.abs(o.clip.y - expected.y) < 0.5 &&
		math.abs(o.clip.w - expected.w) < 0.5 &&
		math.abs(o.clip.h - expected.h) < 0.5 \
	)
}

hit_matches :: proc(o: Observation) -> bool {
	return(
		o.left_hit_code == 0 &&
		o.right_hit_code == 0 &&
		o.left_hit == o.window &&
		o.right_hit == o.background &&
		o.left_owner == o.connection &&
		o.right_owner == o.connection \
	)
}

valid_fixture :: proc(o: Observation, child_pid: int, caller: i32) -> bool {
	return(
		o.event == "ready" &&
		o.pid == i32(child_pid) &&
		o.window != 0 &&
		o.background != 0 &&
		o.window != o.background &&
		o.connection != 0 &&
		o.owner == o.connection &&
		o.connection != caller &&
		o.frame.w > 0 &&
		o.frame.h > 0 &&
		o.frame.w < 10000 &&
		o.frame.h < 10000 \
	)
}
