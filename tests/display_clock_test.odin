package tests

import mac "../src"
import "core:math"
import "core:testing"
import "core:time"
import ipc "../src/ipc"

@(test)
display_pacer_coalesces_pulses_and_consumes_once :: proc(t: ^testing.T) {
	p: mac.Frame_Pacer
	mac.frame_pacer_pulse(&p, 10.016, 10, 1.0 / 60)
	mac.frame_pacer_pulse(&p, 10.033, 10.017, 1.0 / 60)
	mac.frame_pacer_pulse(&p, 10.050, 10.034, 1.0 / 60)
	testing.expect_value(t, p.superseded, u64(2))
	ready, at, fallback := mac.frame_pacer_take(&p, 10.035, true)
	testing.expect(t, ready && !fallback)
	testing.expect_value(t, at, 10.050)
	ready, _, _ = mac.frame_pacer_take(&p, 10.036, true)
	testing.expect(t, !ready)
	mac.frame_pacer_pulse(&p, 10.050, 10.04, 1.0 / 60)
	ready, _, _ = mac.frame_pacer_take(&p, 10.04, true)
	testing.expect(t, !ready)
}

@(test)
display_pacer_skips_obsolete_work_and_has_throttled_fallback :: proc(
	t: ^testing.T,
) {
	p: mac.Frame_Pacer
	mac.frame_pacer_pulse(&p, 10.016, 10, 1.0 / 60)
	ready, at, fallback := mac.frame_pacer_take(&p, 10.080, true)
	testing.expect(t, ready && !fallback)
	testing.expect_value(t, at, 10.080)
	ready, _, _ = mac.frame_pacer_take(&p, 10.090, true)
	testing.expect(t, !ready)
	ready, at, fallback = mac.frame_pacer_take(&p, 10.101, true)
	testing.expect(t, ready && fallback)
	testing.expect_value(t, at, 10.101)
	ready, _, _ = mac.frame_pacer_take(&p, 10.102, false)
	testing.expect(t, !ready)
	ready, _, fallback = mac.frame_pacer_take(&p, 10.12, false)
	testing.expect(t, ready && fallback)
}

@(test)
display_pacer_rejects_invalid_timestamps_and_config_is_explicit :: proc(
	t: ^testing.T,
) {
	p: mac.Frame_Pacer
	for at in ([4]f64 {
			math.nan_f64(),
			math.inf_f64(1),
			11,
			9,
		}) { mac.frame_pacer_pulse(&p, at, 10, 1.0 / 60) }
	testing.expect(t, !p.pending)
	m: mac.Manager; r: Recorder; fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	testing.expect(
		t,
		!mac.execute(&m, {"config", "scroll_frame_pacing", "on"}).failed,
	)
	testing.expect(t, m.scroll_frame_pacing)
	testing.expect_value(
		t,
		mac.execute(&m, {"config", "scroll_frame_pacing"}).text,
		"on",
	)
	testing.expect(
		t,
		mac.execute(&m, {"config", "scroll_frame_pacing", "maybe"}).failed,
	)
	testing.expect(
		t,
		mac.execute(&m, {"config", "--space", "100", "scroll_frame_pacing", "on"}).failed,
	)
}

@(test)
pending_scroll_input_defers_rediscovery_until_presentation :: proc(
	t: ^testing.T,
) {
	state: mac.State; r: Recorder
	state.event_user = &r; state.dirty = true
	state.mouse.scroll_tracking = true
	last := time.now(); now := time.time_add(last, time.Second)
	mac.desktop_refresh_tick(&state, &last, now, resize_collect)
	testing.expect_value(t, r.calls, 0)
	testing.expect(t, state.dirty)
	state.mouse.scroll_tracking = false
	mac.desktop_refresh_tick(&state, &last, now, resize_collect)
	testing.expect_value(t, r.calls, 1)
}

@(test)
paced_input_coalesces_native_events_without_early_frame_writes :: proc(
	t: ^testing.T,
) {
	state: mac.State; r: Recorder; niri_fixture(&state.manager, &r)
	m := &state.manager
	defer mac.manager_destroy(m); defer delete(r.actions)
	niri_open(m, 2); niri_open(m, 3)
	mac.execute(m, {"window", "1", "--focus"})
	m.mouse.scroll = true
	clear(&r.actions)
	event := CGEventCreateScrollWheelEvent(nil, 0, 2, 0, i32(-120))
	if !testing.expect(t, event != nil) {
		return
	}
	defer mac.CFRelease(event)
	CGEventSetLocation(event, {10, 10})
	CGEventSetFlags(event, m.mouse.modifier)
	CGEventSetIntegerValueField(event, 88, 1)
	CGEventSetIntegerValueField(event, 96, 0)
	CGEventSetIntegerValueField(event, 97, -120)
	CGEventSetIntegerValueField(event, 99, 1)
	mac.mouse_callback(nil, 22, event, &state)
	mac.mouse_tick(&state, false)
	testing.expect_value(t, len(r.actions), 0)
	first := state.mouse.scroll_delta
	CGEventSetIntegerValueField(event, 99, 2)
	mac.mouse_callback(nil, 22, event, &state)
	mac.mouse_tick(&state, false)
	testing.expect_value(t, state.mouse.scroll_delta, first * 2)
	testing.expect_value(t, len(r.actions), 0)
	mac.mouse_tick(&state, true, time.now())
	testing.expect_value(t, state.mouse.scroll_delta, f64(0))
	testing.expect(t, len(r.actions) > 0)
	testing.expect(t, m.spaces[0].view.scroll.dragging)
}

@(test)
queued_resize_uses_execution_time_after_a_slow_refresh :: proc(t: ^testing.T) {
	m: mac.Manager; r: Recorder; niri_fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2)
	mac.execute(&m, {"config", "scroll_animation", "on"})
	m.animation_duration = 0.5
	now := time.duration_seconds(time.diff(time.Time{}, time.now()))
	// Model the stale loop timestamp left behind by synchronous discovery.
	m.scroll_time = now - 2
	before := m.windows[1].frame.w
	fds: [2]i32
	if !testing.expect_value(t, socketpair(1, 1, 0, &fds), i32(0)) {
		return
	}
	defer mac.close(fds[0])
	mac.prepare_socket(fds[0])
	server: mac.Command_Server
	defer mac.command_server_stop(&server)
	if !testing.expect(t, mac.command_accept(&server, fds[1])) {
		return
	}
	data, valid := ipc.encode_message(
		{"window", "1", "--column-width", "abs:900"},
	)
	if !testing.expect(t, valid) {
		return
	}
	defer delete(data)
	testing.expect(t, mac.write_all(fds[0], data))
	mac.command_server_tick(&server, &m)
	testing.expect(t, m.spaces[0].view.scroll.geometry_began >= now)
	mac.scroll_motion_tick(&m, now + .05)
	testing.expect(
		t,
		m.windows[1].frame.w > before && m.windows[1].frame.w < 900,
	)
}

@(test)
failed_display_link_creation_retries_on_the_same_display_with_backoff :: proc(
	t: ^testing.T,
) {
	clock := mac.Display_Clock {
		display = 10,
	}
	testing.expect(t, mac.display_clock_should_create(&clock, 10, 1))
	testing.expect(t, !mac.display_clock_should_create(&clock, 10, 1.01))
	testing.expect(t, mac.display_clock_should_create(&clock, 10, 1.5))
	testing.expect(t, !mac.display_clock_should_create(&clock, 10, 1.6))
	testing.expect(t, mac.display_clock_should_create(&clock, 20, 1.6))
}
