package main

import e "../../src/engine"
import "core:os"
import "core:strings"
import "core:testing"

Geometry_Replay :: struct {
	calls, pumps: int,
}
replay_geometry :: proc(user: rawptr, _: i32, _: u32, frame: ^e.Rect) -> i32 {
	replay := (^Geometry_Replay)(user)
	replay.calls += 1
	frame^ = replay.calls < 3 ? e.Rect{} : e.Rect{180, 589, 520, 328}
	return 0
}
replay_pump :: proc(user: rawptr) { (^Geometry_Replay)(user).pumps += 1 }

@(test)
fixture_waits_for_nonempty_geometry_despite_success_code :: proc(
	t: ^testing.T,
) {
	replay: Geometry_Replay
	frame, _, ready := await_geometry(
		&replay,
		replay_geometry,
		replay_pump,
		1,
		2,
		4,
	)
	testing.expect(t, ready && frame.w == 520 && frame.h == 328)
	testing.expect(t, replay.pumps > 0)
	// The same successful API response is not usable if the window never
	// acquires dimensions within the allowed polling budget.
	replay = {}
	empty, code, exhausted := await_geometry(
		&replay,
		replay_geometry,
		replay_pump,
		1,
		2,
		2,
	)
	testing.expect(t, !exhausted && code == 0 && empty.w == 0 && empty.h == 0)
}

@(test)
baseline_failure_reports_requested_and_observed_geometry :: proc(
	t: ^testing.T,
) {
	o := Observation {
		event         = "baseline_unverified",
		phase         = "baseline",
		code          = 0,
		bounds_code   = 0,
		clip_present  = true,
		expected_clip = {0, 0, 520, 322},
		clip          = {0, 0, 520, 328},
		frame         = {180, 589, 520, 328},
	}
	message := failure_message(o)
	testing.expect(t, strings.contains(message, "baseline_unverified"))
	testing.expect(t, strings.contains(message, "322"))
	testing.expect(t, strings.contains(message, "328"))
	testing.expect(t, strings.contains(message, "requested"))
	testing.expect(t, strings.contains(message, "observed"))
}

@(test)
fixture_ownership_gate :: proc(t: ^testing.T) {
	valid := Observation {
		event      = "ready",
		pid        = 123,
		connection = 41,
		owner      = 41,
		window     = 70,
		background = 71,
		frame      = {180, 200, 520, 322},
	}
	testing.expect(t, valid_fixture(valid, 123, 40))
	for field in 0 ..< 8 {
		bad := valid
		switch field {
		case 0:
			bad.pid = 124
		case 1:
			bad.owner = 40
		case 2:
			bad.connection = 40; bad.owner = 40
		case 3:
			bad.window = 0
		case 4:
			bad.background = bad.window
		case 5:
			bad.frame.w = -1
		case 6:
			bad.frame.h = 20000
		case 7:
			bad.event = "readback"
		}
		testing.expect(t, !valid_fixture(bad, 123, 40))
	}
}

@(test)
setter_success_is_not_clip_readback :: proc(t: ^testing.T) {
	expected := e.Rect{0, 0, 260, 322}
	valid := Observation {
		code         = 0,
		bounds_code  = 0,
		clip_present = true,
		clip         = expected,
	}
	testing.expect(t, clip_matches(valid, expected))
	for field in 0 ..< 5 {
		bad := valid
		switch field {
		case 0:
			bad.code = 1000
		case 1:
			bad.bounds_code = 1000
		case 2:
			bad.clip_present = false
		case 3:
			bad.clip.w = 520
		case 4:
			bad.clip.x = 100
		}
		testing.expect(t, !clip_matches(bad, expected))
	}
}

@(test)
clip_geometry_does_not_prove_input_routing :: proc(t: ^testing.T) {
	o := Observation {
		window      = 70,
		background  = 71,
		connection  = 41,
		left_hit    = 70,
		right_hit   = 71,
		left_owner  = 41,
		right_owner = 41,
	}
	testing.expect(t, hit_matches(o))
	o.right_hit = 70
	testing.expect(t, !hit_matches(o))
	o.right_hit = 71; o.right_owner = 42
	testing.expect(t, !hit_matches(o))
	o.right_owner = 41; o.right_hit_code = 1000
	testing.expect(t, !hit_matches(o))
}

@(test)
fixture_protocol_handles_fragmented_and_multiple_records :: proc(
	t: ^testing.T,
) {
	r, w, err := os.pipe()
	if !testing.expect(t, err == nil) {
		return
	}
	defer os.close(r); defer os.close(w)
	reader: Reader; defer delete(reader.data)
	first := `{"event":"ready"`
	os.write(w, transmute([]u8)first)
	_, received, failed := next_observation(&reader, r)
	testing.expect(t, !received && !failed)
	rest := ",\"pid\":123}\n{\"event\":\"readback\"}\n"
	os.write(w, transmute([]u8)rest)
	o, got_first, bad_first := next_observation(&reader, r)
	defer delete(o.event); defer delete(o.phase)
	testing.expect(
		t,
		got_first && !bad_first && o.event == "ready" && o.pid == 123,
	)
	second, got_second, bad_second := next_observation(&reader, r)
	defer delete(second.event); defer delete(second.phase)
	testing.expect(t, got_second && !bad_second && second.event == "readback")
	invalid := "{\"event\":\"partial\", invalid}\n"
	os.write(w, transmute([]u8)invalid)
	_, got_bad, rejected := next_observation(&reader, r)
	testing.expect(t, !got_bad && rejected)
}
