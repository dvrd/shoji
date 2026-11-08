package tests

import mac "../src"
import "core:testing"

@(private = "file")
camera_fixture :: proc(m: ^mac.Manager, r: ^Recorder, batch_result: bool) {
	niri_fixture(m, r)
	niri_open(m, 2); niri_open(m, 3)
	mac.execute(m, {"window", "1", "--focus"})
	mac.execute(m, {"config", "scroll_animation", "on"})
	m.animation_duration = 0.5
	m.layout_batch = record_batch
	batch_recorder = {result = batch_result}
	mac.execute(m, {"window", "3", "--focus"})
	resize(&r.actions, 0)
}

@(private = "file")
frame_writes :: proc(r: ^Recorder) -> (count: int) {
	for a in r.actions {if a.kind == .Frame {count += 1}}
	return
}

@(test)
scroll_camera_frames_land_through_one_batch_and_resync_once_settled :: proc(t: ^testing.T) {
	m: mac.Manager; r: Recorder; camera_fixture(&m, &r, true)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	defer delete(batch_recorder.moves)
	for at in ([3]f64{0.04, 0.08, 0.12}) {
		testing.expect_value(t, mac.scroll_motion_tick(&m, at), "")
	}
	testing.expect_value(t, batch_recorder.calls, 3)
	// The camera moved the strip without a single Accessibility write.
	testing.expect_value(t, frame_writes(&r), 0)
	moved := 0
	for _, w in m.windows {if w.ax_stale {moved += 1; testing.expect(t, w.server_placed)}}
	testing.expect(t, moved > 0)
	// Settling sends each stale window its final frame exactly once.
	testing.expect_value(t, mac.scroll_motion_tick(&m, 0.4), "")
	testing.expect(t, !m.spaces[0].view.scroll.motion.active)
	testing.expect_value(t, frame_writes(&r), moved)
	for _, w in m.windows {testing.expect(t, !w.ax_stale)}
	testing.expect_value(t, m.windows[3].frame.x, f64(648))
}

@(test)
scroll_camera_hold_submits_once_with_owned_surfaces :: proc(t: ^testing.T) {
	m: mac.Manager; r: Recorder; camera_fixture(&m, &r, true)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	defer delete(batch_recorder.moves)
	m.camera_hold = true
	testing.expect_value(t, mac.scroll_motion_tick(&m, 0.04), "")
	testing.expect_value(t, batch_recorder.calls, 0)
	testing.expect(t, m.camera_held > 0)
	owned := []mac.Layout_Move{{window = 99, x = 4, y = 5}}
	testing.expect(t, mac.layout_frame_submit(&m, owned))
	testing.expect_value(t, batch_recorder.calls, 1)
	testing.expect_value(t, m.camera_held, 0)
	found := false
	for move in batch_recorder.moves {
		if move.window == 99 {
			found = true
			testing.expect_value(t, move.x, f64(4))
			testing.expect_value(t, move.y, f64(5))
		}
	}
	testing.expect(t, found)
	testing.expect(t, len(batch_recorder.moves) > 1)
}

@(test)
scroll_camera_batch_refusal_falls_back_to_frame_writes :: proc(t: ^testing.T) {
	m: mac.Manager; r: Recorder; camera_fixture(&m, &r, false)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	defer delete(batch_recorder.moves)
	testing.expect_value(t, mac.scroll_motion_tick(&m, 0.04), "")
	testing.expect_value(t, batch_recorder.calls, 1)
	testing.expect(t, frame_writes(&r) > 0)
	for _, w in m.windows {testing.expect(t, !w.ax_stale)}
}

@(private = "file")
stale_windows :: proc(m: ^mac.Manager) -> (count: int) {
	for _, w in m.windows {if w.ax_stale {count += 1}}
	return
}

@(test)
scroll_drag_batches_every_pan_and_spring_off_release_resyncs :: proc(t: ^testing.T) {
	m: mac.Manager; r: Recorder; niri_fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	defer delete(batch_recorder.moves)
	niri_open(&m, 2); niri_open(&m, 3)
	m.layout_batch = record_batch
	batch_recorder = {result = true}
	resize(&r.actions, 0)
	s := m.spaces[0]
	mac.scroll_begin_pan(&m, s)
	for delta in ([3]f64{-100, -150, -200}) {
		testing.expect_value(t, mac.scroll_gesture_pan(&m, s.id, delta), "")
	}
	// The strip followed the fingers with no Accessibility write.
	testing.expect_value(t, batch_recorder.calls, 3)
	testing.expect_value(t, frame_writes(&r), 0)
	moved := stale_windows(&m)
	testing.expect(t, moved > 0)
	// Scroll animation is off: the release snaps and resyncs in one flush.
	testing.expect_value(t, mac.scroll_finish_pan(&m, s, 0), "")
	testing.expect_value(t, stale_windows(&m), 0)
	testing.expect(t, frame_writes(&r) >= moved)
}

@(test)
scroll_drag_release_hands_over_to_the_batched_spring :: proc(t: ^testing.T) {
	m: mac.Manager; r: Recorder; niri_fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	defer delete(batch_recorder.moves)
	niri_open(&m, 2); niri_open(&m, 3)
	mac.execute(&m, {"config", "scroll_animation", "on"})
	m.animation_duration = 0.5
	m.layout_batch = record_batch
	batch_recorder = {result = true}
	resize(&r.actions, 0)
	s := m.spaces[0]
	mac.scroll_begin_pan(&m, s)
	mac.scroll_gesture_pan(&m, s.id, -516)
	testing.expect_value(t, mac.scroll_finish_pan(&m, s, 100), "")
	testing.expect_value(t, mac.scroll_motion_tick(&m, 0.1), "")
	testing.expect_value(t, frame_writes(&r), 0)
	testing.expect(t, stale_windows(&m) > 0)
	testing.expect_value(t, mac.scroll_motion_tick(&m, 0.4), "")
	testing.expect(t, !s.view.scroll.motion.active)
	testing.expect_value(t, stale_windows(&m), 0)
	testing.expect(t, frame_writes(&r) > 0)
}
