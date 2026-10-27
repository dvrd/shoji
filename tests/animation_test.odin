package tests

import e "../src/engine"
import mac "../src/macos"
import "core:testing"
import "core:time"

Animation_Recorder :: struct {
	created, restored, destroyed, updates: int,
	fail_restore, fail_apply:              bool,
	last:                                  e.Rect,
	applied:                               int,
}
proxy_create :: proc(state: ^mac.State, window: u32) -> (mac.Animation_Proxy, string) {
	r := (^Animation_Recorder)(state.event_user);r.created += 1
	return {window = window, surface = {id = window + 100, frame = state.manager.windows[window].frame}}, ""
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
proxy_apply :: proc(state: ^mac.State, window: u32, frame: e.Rect) -> string {
	r := (^Animation_Recorder)(state.event_user)
	if r.fail_apply {return "frame failed"}
	r.last = frame;r.applied += 1
	return ""
}

@(test)
layout_growth_uses_live_frames_including_close_reflow :: proc(t: ^testing.T) {
	state: mac.State;r: Recorder;fixture(&state.manager, &r)
	defer e.manager_destroy(&state.manager);defer delete(r.actions)
	state.manager.windows[1].frame = {0, 0, 500, 800}
	fill := mac.animation_frame_action(&state, {kind = .Frame, window = 1, frame = {0, 0, 1000, 800}, duration = 0.24})
	testing.expect(t, fill.live_resize)
	move := mac.animation_frame_action(&state, {kind = .Frame, window = 1, frame = {100, 0, 500, 800}, duration = 0.24})
	testing.expect(t, !move.live_resize)
	state.animations = make(map[u32]mac.Animation_Job);defer delete(state.animations)
	state.animations[1] = {presentation = mac.Live_Resize{}}
	testing.expect(t, mac.animation_frame_action(&state, move).live_resize)
}

@(test)
live_resize_animates_real_frames_without_capture_or_scaling :: proc(t: ^testing.T) {
	state: mac.State; r: Recorder; animation: Animation_Recorder
	fixture(&state.manager, &r)
	defer e.manager_destroy(&state.manager);defer delete(r.actions)
	defer mac.animation_stop(&state)
	state.event_user = &animation
	state.animation_backend = {proxy_create, proxy_update, proxy_restore, proxy_destroy, proxy_apply}
	state.manager.animation_easing = .Linear
	state.manager.windows[1].frame = {0, 0, 800, 600}
	began := time.now()
	testing.expect_value(t, mac.animation_start_at(&state, {kind = .Frame, window = 1, frame = {0, 0, 1000, 800}, duration = 1, live_resize = true}, began), "")
	testing.expect_value(t, animation.created, 0)
	testing.expect_value(t, animation.applied, 0)
	mac.animation_tick(&state, time.time_add(began, 500 * time.Millisecond))
	testing.expect_value(t, animation.last, e.Rect{0, 0, 900, 700})
	testing.expect_value(t, animation.applied, 1)
	testing.expect_value(t, animation.updates, 0)
	mac.animation_tick(&state, time.time_add(began, time.Second))
	testing.expect_value(t, animation.last, e.Rect{0, 0, 1000, 800})
	testing.expect_value(t, len(state.animations), 0)
	testing.expect_value(t, animation.restored, 0)
	testing.expect_value(t, animation.destroyed, 0)
}

@(test)
live_resize_retargets_and_cleans_up_after_frame_failure :: proc(t: ^testing.T) {
	state: mac.State; r: Recorder; animation: Animation_Recorder
	fixture(&state.manager, &r)
	defer e.manager_destroy(&state.manager);defer delete(r.actions)
	defer mac.animation_stop(&state)
	state.event_user = &animation
	state.animation_backend = {proxy_create, proxy_update, proxy_restore, proxy_destroy, proxy_apply}
	state.manager.animation_easing = .Linear
	state.manager.windows[1].frame = {0, 0, 800, 600}
	began := time.now()
	mac.animation_start_at(&state, {kind = .Frame, window = 1, frame = {0, 0, 1000, 800}, duration = 1, live_resize = true}, began)
	middle := time.time_add(began, 500 * time.Millisecond)
	mac.animation_tick(&state, middle)
	mac.animation_start_at(&state, {kind = .Frame, window = 1, frame = {0, 0, 1200, 800}, duration = 1, live_resize = true}, middle)
	testing.expect_value(t, state.animations[1].from, e.Rect{0, 0, 900, 700})
	animation.fail_apply = true
	mac.animation_tick(&state, time.time_add(middle, 100 * time.Millisecond))
	testing.expect_value(t, len(state.animations), 0)
	testing.expect(t, state.dirty)
	testing.expect_value(t, animation.created, 0)
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

@(test)
rapid_window_animation_retargets_the_existing_proxy_without_restoring :: proc(t: ^testing.T) {
	state: mac.State;recorder: Recorder;animation: Animation_Recorder
	fixture(&state.manager, &recorder)
	defer e.manager_destroy(&state.manager);defer delete(recorder.actions)
	state.event_user = &animation
	state.animation_backend = {proxy_create, proxy_update, proxy_restore, proxy_destroy, proxy_apply}
	state.manager.animation_easing = .Linear
	state.manager.windows[1].frame = {0, 0, 100, 100}
	began := time.now()
	testing.expect_value(t, mac.animation_start_at(&state, {kind = .Frame, window = 1, frame = {100, 50, 200, 200}, duration = 1}, began), "")
	now := time.time_add(began, 500*time.Millisecond)
	testing.expect_value(t, mac.animation_start_at(&state, {kind = .Frame, window = 1, frame = {200, 0, 300, 100}, duration = 1}, now), "")
	testing.expect_value(t, animation.created, 1)
	testing.expect_value(t, animation.restored, 0)
	testing.expect_value(t, animation.destroyed, 0)
	mac.animation_tick(&state, time.time_add(now, 500*time.Millisecond))
	testing.expect_value(t, animation.last, e.Rect{125, 12.5, 225, 125})
	// Retargeting retains the original native-scale capture for clipping.
	testing.expect_value(t, state.animations[1].presentation.(mac.Animation_Proxy).frame, e.Rect{0, 0, 100, 100})
	animation.fail_apply = true
	testing.expect(t, mac.animation_start_at(&state, {kind = .Frame, window = 1, frame = {0, 0, 500, 500}, duration = 1}, now) != "")
	testing.expect_value(t, state.animations[1].target, e.Rect{200, 0, 300, 100})
	animation.fail_apply = false
	mac.animation_tick(&state, time.time_add(now, 2*time.Second))
	testing.expect_value(t, animation.restored, 1)
	testing.expect_value(t, animation.destroyed, 1)
	mac.animation_stop(&state)
}
