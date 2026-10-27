package tests

import e "../src/engine"
import mac "../src/macos"
import "core:testing"

foreign import scroll_test_cg "system:CoreGraphics.framework"
foreign scroll_test_cg {
	CGEventCreateScrollWheelEvent :: proc "c" (source: mac.Ref, units: u32, count: u32, wheel: i32, #c_vararg rest: ..any) -> mac.Ref ---
}

@(test)
scroll_gesture_owns_only_modified_horizontal_input_and_its_momentum :: proc(
	t: ^testing.T,
) {
	g: e.Scroll_Gesture
	modifier := u64(1 << 23)
	owned, _ := e.scroll_gesture_route(
		&g,
		{x = 20, phase = 1},
		100,
		modifier,
		true,
		0,
	)
	testing.expect(t, !owned)
	owned, _ = e.scroll_gesture_route(
		&g,
		{x = 20, momentum = 1},
		100,
		modifier,
		true,
		0.1,
	)
	testing.expect(t, !owned)
	owned, _ = e.scroll_gesture_route(
		&g,
		{x = 1, y = 20, modifiers = modifier, phase = 1},
		100,
		modifier,
		true,
		0.2,
	)
	testing.expect(t, !owned)
	delta: f64
	owned, delta = e.scroll_gesture_route(
		&g,
		{x = -25, modifiers = modifier, phase = 2},
		100,
		modifier,
		true,
		0.3,
	)
	testing.expect(t, owned); testing.expect_value(t, delta, f64(25))
	owned, _ = e.scroll_gesture_route(
		&g,
		{phase = 4},
		100,
		modifier,
		true,
		0.4,
	)
	testing.expect(t, owned)
	owned, delta = e.scroll_gesture_route(
		&g,
		{x = -10, momentum = 1},
		200,
		modifier,
		true,
		0.5,
	)
	testing.expect(t, owned); testing.expect_value(t, delta, f64(10))
	testing.expect_value(t, g.space, u64(100))
	owned, _ = e.scroll_gesture_route(
		&g,
		{momentum = 3},
		200,
		modifier,
		true,
		0.6,
	)
	testing.expect(t, owned); testing.expect(t, !g.owned)
	owned, _ = e.scroll_gesture_route(
		&g,
		{x = 10, momentum = 2},
		200,
		modifier,
		true,
		0.7,
	)
	testing.expect(t, !owned)
}

@(test)
native_scroll_callback_routes_and_coalesces_pixels_without_app_scroll_capture :: proc(
	t: ^testing.T,
) {
	state: mac.State; r: Recorder; niri_fixture(&state.manager, &r)
	defer e.manager_destroy(&state.manager); defer delete(r.actions)
	state.manager.mouse.scroll = true
	event := CGEventCreateScrollWheelEvent(nil, 0, 2, 0, i32(-40))
	testing.expect(t, event != nil)
	if event == nil {
		return
	}
	defer mac.CFRelease(event)
	state.manager.mouse_display = 10
	CGEventSetIntegerValueField(event, 88, 1)
	CGEventSetIntegerValueField(event, 97, -40)
	CGEventSetIntegerValueField(event, 96, 0)
	CGEventSetIntegerValueField(event, 99, 1)
	CGEventSetFlags(event, 0)
	testing.expect_value(t, mac.mouse_callback(nil, 22, event, &state), event)
	CGEventSetFlags(event, state.manager.mouse.modifier)
	testing.expect_value(
		t,
		mac.mouse_callback(nil, 22, event, &state),
		mac.Ref(nil),
	)
	testing.expect_value(t, state.mouse.scroll_delta, f64(40) * 1280 / 1200)
	CGEventSetIntegerValueField(event, 99, 2)
	CGEventSetIntegerValueField(event, 97, -10)
	testing.expect_value(
		t,
		mac.mouse_callback(nil, 22, event, &state),
		mac.Ref(nil),
	)
	testing.expect(t, state.mouse.scroll_delta > 53.33 && state.mouse.scroll_delta < 53.34)
	testing.expect_value(t, state.mouse.scroll.space, u64(100))
}

@(test)
immediate_scroll_interrupt_restores_proxy_and_drops_stale_animation_target :: proc(
	t: ^testing.T,
) {
	state: mac.State; r: Animation_Recorder
	e.manager_init(&state.manager)
	defer e.manager_destroy(&state.manager)
	state.event_user = &r
	state.animation_backend = {
		proxy_create,
		proxy_update,
		proxy_restore,
		proxy_destroy,
		proxy_apply,
	}
	state.animations = make(map[u32]mac.Animation_Job)
	defer delete(state.animations)
	state.animations[1] = {
		presentation = mac.Live_Resize{current = {0, 0, 400, 400}},
		target      = {100, 0, 400, 400},
	}
	testing.expect_value(t, mac.animation_interrupt(&state, 1), "")
	testing.expect_value(t, r.applied, 0)
	state.animations[1] = {
		presentation = mac.Animation_Proxy{window = 1},
	}
	r.fail_restore = true
	testing.expect(t, mac.animation_interrupt(&state, 1) != "")
	testing.expect_value(t, len(state.animations), 1)
	r.fail_restore = false
	testing.expect_value(t, mac.animation_interrupt(&state, 1), "")
	testing.expect_value(t, r.restored, 1)
	testing.expect_value(t, r.destroyed, 1)
	testing.expect_value(t, len(state.animations), 0)
}

@(test)
scroll_gesture_cancellation_disable_and_new_application_sequence_release_ownership :: proc(
	t: ^testing.T,
) {
	g: e.Scroll_Gesture
	modifier := u64(1 << 23)
	e.scroll_gesture_route(
		&g,
		{x = 20, modifiers = modifier, phase = 1},
		100,
		modifier,
		true,
		0,
	)
	owned, _ := e.scroll_gesture_route(
		&g,
		{phase = 8},
		100,
		modifier,
		true,
		0.1,
	)
	testing.expect(t, owned); testing.expect(t, !g.owned)
	e.scroll_gesture_route(
		&g,
		{x = 20, modifiers = modifier, phase = 1},
		100,
		modifier,
		true,
		0.2,
	)
	owned, _ = e.scroll_gesture_route(
		&g,
		{x = 20, phase = 1},
		100,
		modifier,
		true,
		0.3,
	)
	testing.expect(t, !owned)
	e.scroll_gesture_route(
		&g,
		{x = 20, modifiers = modifier, phase = 1},
		100,
		modifier,
		true,
		0.4,
	)
	owned, _ = e.scroll_gesture_route(
		&g,
		{x = 20, momentum = 1},
		100,
		modifier,
		false,
		0.5,
	)
	testing.expect(t, !owned); testing.expect(t, !g.owned)
}

@(test)
scroll_gesture_pan_is_immediate_without_changing_keyboard_focus_or_duration :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	m.animation_duration = 0.18
	resize(&r.actions, 0)
	testing.expect_value(t, e.scroll_gesture_pan(&m, 100, -200), "")
	testing.expect_value(t, m.focused, u32(3))
	testing.expect_value(t, m.animation_duration, f64(0.18))
	testing.expect(t, len(r.actions) > 0)
	for a in r.actions {
		if a.kind == .Frame {
			testing.expect_value(t, a.duration, f64(0))
		}
	}
}
