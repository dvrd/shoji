package tests

import e "../src/engine"
import mac "../src/macos"
import "core:testing"
import "core:time"

Animation_Recorder :: struct {
	created, restored, destroyed, updates: int,
	fail_restore, fail_apply:              bool,
	last:                                  e.Rect,
}
proxy_create :: proc(state: ^mac.State, window: u32) -> (mac.Animation_Proxy, string) {
	r := (^Animation_Recorder)(state.event_user);r.created += 1
	return {window = window, id = window + 100, frame = state.manager.windows[window].frame}, ""
}
proxy_update :: proc(state: ^mac.State, proxy: mac.Animation_Proxy, frame: e.Rect) -> string {
	r := (^Animation_Recorder)(state.event_user);r.updates += 1;r.last = frame;return ""
}
proxy_restore :: proc(state: ^mac.State, proxy: mac.Animation_Proxy) -> string {
	r := (^Animation_Recorder)(state.event_user)
	if r.fail_restore {return "restore unavailable"};r.restored += 1;return ""
}
proxy_destroy :: proc(state: ^mac.State, proxy: mac.Animation_Proxy) {r := (^Animation_Recorder)(
		state.event_user,
	)
	r.destroyed += 1}
proxy_apply :: proc(state: ^mac.State, action: e.Action) -> string {
	r := (^Animation_Recorder)(state.event_user)
	if r.fail_apply {return "frame failed"};return ""
}

@(test)
proxy_animation_interpolates_and_restores_before_destroying :: proc(t: ^testing.T) {
	state: mac.State;recorder: Recorder;animation: Animation_Recorder
	fixture(&state.manager, &recorder)
	defer e.manager_destroy(&state.manager);defer delete(recorder.actions)
	state.event_user = &animation
	state.animation_backend = {
		proxy_create,
		proxy_update,
		proxy_restore,
		proxy_destroy,
		proxy_apply,
	}
	state.manager.animation_easing = .Linear
	state.manager.windows[1].frame = {0, 0, 100, 100}
	testing.expect_value(
		t,
		mac.animation_start(
			&state,
			{kind = .Frame, window = 1, frame = {100, 50, 200, 200}, duration = 1},
		),
		"",
	)
	job := state.animations[1]
	mac.animation_tick(&state, time.time_add(job.began, 500 * time.Millisecond))
	testing.expect_value(t, animation.last, e.Rect{50, 25, 150, 150})
	animation.fail_restore = true
	mac.animation_tick(&state, time.time_add(job.began, 2 * time.Second))
	testing.expect_value(t, animation.destroyed, 0)
	testing.expect_value(t, len(state.animations), 1)
	animation.fail_restore = false
	mac.animation_tick(&state, time.time_add(job.began, 2 * time.Second))
	testing.expect_value(t, animation.restored, 1)
	testing.expect_value(t, animation.destroyed, 1)
	mac.animation_stop(&state)
}

@(test)
proxy_frame_failure_restores_and_releases_resources :: proc(t: ^testing.T) {
	state: mac.State;recorder: Recorder;animation: Animation_Recorder
	fixture(&state.manager, &recorder)
	defer e.manager_destroy(&state.manager);defer delete(recorder.actions)
	state.event_user = &animation;animation.fail_apply = true
	state.animation_backend = {
		proxy_create,
		proxy_update,
		proxy_restore,
		proxy_destroy,
		proxy_apply,
	}
	testing.expect(
		t,
		mac.animation_start(
			&state,
			{kind = .Frame, window = 1, frame = {0, 0, 200, 200}, duration = 1},
		) !=
		"",
	)
	testing.expect_value(t, animation.restored, 1)
	testing.expect_value(t, animation.destroyed, 1)
	testing.expect_value(t, len(state.animations), 0)
	mac.animation_stop(&state)
}

@(test)
easing_curves_have_exact_endpoints_and_monotonic_frames :: proc(t: ^testing.T) {
	for _, index in e.EASING_NAMES {
		kind := e.Easing(index)
		testing.expect_value(t, e.ease(kind, 0), f64(0))
		testing.expect_value(t, e.ease(kind, 1), f64(1))
		previous: f64
		for i in 1 ..= 100 {
			value := e.ease(kind, f64(i) / 100)
			testing.expect(t, value >= previous && value >= 0 && value <= 1);previous = value
		}
	}
}
