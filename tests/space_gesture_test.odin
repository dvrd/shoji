package tests

import e "../src/engine"
import mac "../src/macos"
import "core:testing"

@(test)
bsp_modified_swipe_switches_once_and_swallows_momentum :: proc(t: ^testing.T) {
	state: mac.State; r: Recorder; fixture(&state.manager, &r)
	defer e.manager_destroy(&state.manager); defer delete(r.actions)
	m := &state.manager
	e.add_space(m, 200, 10, 2, {0, 0, 1000, 800})
	m.mouse.scroll = true
	event := CGEventCreateScrollWheelEvent(nil, 0, 2, 0, i32(-45))
	testing.expect(t, event != nil)
	if event == nil {
		return
	}
	defer mac.CFRelease(event)
	CGEventSetLocation(event, {10, 10})
	CGEventSetFlags(event, m.mouse.modifier)
	CGEventSetIntegerValueField(event, 88, 1)
	CGEventSetIntegerValueField(event, 96, 0)
	CGEventSetIntegerValueField(event, 97, -45)
	CGEventSetIntegerValueField(event, 99, 1)
	testing.expect_value(
		t,
		mac.mouse_callback(nil, 22, event, &state),
		mac.Ref(nil),
	)
	CGEventSetIntegerValueField(event, 99, 2)
	testing.expect_value(
		t,
		mac.mouse_callback(nil, 22, event, &state),
		mac.Ref(nil),
	)
	mac.mouse_tick(&state)
	testing.expect_value(t, len(r.actions), 1)
	if len(r.actions) > 0 {
		testing.expect_value(t, r.actions[0].kind, e.Action_Kind.Space_Focus)
		testing.expect_value(t, r.actions[0].space, u64(200))
	}
	CGEventSetFlags(event, 0)
	CGEventSetIntegerValueField(event, 99, 0)
	CGEventSetIntegerValueField(event, 123, 2)
	for _ in 0 ..< 4 {
		testing.expect_value(
			t,
			mac.mouse_callback(nil, 22, event, &state),
			mac.Ref(nil),
		)
		mac.mouse_tick(&state)
	}
	testing.expect_value(t, len(r.actions), 1)
}

@(test)
space_swipe_threshold_direction_and_layout_stay_latched :: proc(
	t: ^testing.T,
) {
	g: e.Scroll_Gesture
	modifier := u64(1 << 23)
	owned, pan, direction := e.layout_gesture_route(
		&g,
		{x = 45, modifiers = modifier, phase = 1},
		100,
		.BSP,
		modifier,
		true,
		1,
	)
	testing.expect(t, owned); testing.expect_value(t, pan, f64(0))
	testing.expect_value(t, direction, 0)
	owned, pan, direction = e.layout_gesture_route(
		&g,
		{x = 45, modifiers = modifier, phase = 2},
		100,
		.BSP,
		modifier,
		true,
		1.01,
	)
	testing.expect(t, owned); testing.expect_value(t, direction, -1)
	owned, pan, direction = e.layout_gesture_route(
		&g,
		{x = -200, modifiers = modifier, phase = 2},
		200,
		.Scroll,
		modifier,
		true,
		1.02,
	)
	testing.expect(t, owned); testing.expect_value(t, pan, f64(0))
	testing.expect_value(t, direction, 0)
	testing.expect_value(t, g.space, u64(100))
	owned, pan, direction = e.layout_gesture_route(
		&g,
		{x = -90, modifiers = modifier, phase = 1},
		200,
		.Scroll,
		modifier,
		true,
		2,
	)
	testing.expect(t, owned); testing.expect_value(t, pan, f64(90))
	testing.expect_value(t, direction, 0)
}

@(test)
space_swipe_ignores_ordinary_vertical_and_cancelled_input :: proc(
	t: ^testing.T,
) {
	g: e.Scroll_Gesture
	modifier := u64(1 << 23)
	owned, _, _ := e.layout_gesture_route(
		&g,
		{x = -100, phase = 1},
		100,
		.BSP,
		modifier,
		true,
		1,
	)
	testing.expect(t, !owned)
	owned, _, _ = e.layout_gesture_route(
		&g,
		{x = -100, y = 200, modifiers = modifier, phase = 1},
		100,
		.BSP,
		modifier,
		true,
		2,
	)
	testing.expect(t, !owned)
	e.layout_gesture_route(
		&g,
		{x = -20, modifiers = modifier, phase = 1},
		100,
		.BSP,
		modifier,
		true,
		3,
	)
	_, _, direction := e.layout_gesture_route(
		&g,
		{x = -100, modifiers = modifier, phase = 8},
		100,
		.BSP,
		modifier,
		true,
		3.01,
	)
	testing.expect_value(t, direction, 0)
	owned, _, _ = e.layout_gesture_route(
		&g,
		{x = -100, modifiers = modifier, phase = 1},
		100,
		.BSP,
		modifier,
		false,
		4,
	)
	testing.expect(t, !owned)
}

@(test)
space_swipe_selects_adjacent_and_wraps_on_same_display :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	e.add_space(&m, 300, 20, 2, {0, 0, 1000, 800})
	next := e.add_space(&m, 200, 10, 3, {0, 0, 1000, 800})
	testing.expect_value(t, e.space_gesture_switch(&m, 100, -1), "")
	testing.expect_value(t, len(r.actions), 1)
	if len(r.actions) == 0 {return}
	testing.expect_value(t, r.actions[0].space, u64(200))
	resize(&r.actions, 0)
	testing.expect_value(t, e.space_gesture_switch(&m, 100, 1), "")
	testing.expect_value(t, r.actions[0].space, u64(200))
	resize(&r.actions, 0)
	m.displays[0].active_space = 200
	m.spaces[0].visible = false; next.visible = true
	testing.expect_value(t, e.space_gesture_switch(&m, 100, 1), "")
	testing.expect_value(t, len(r.actions), 0)
	testing.expect_value(t, e.space_gesture_switch(&m, 200, 1), "")
	testing.expect_value(t, len(r.actions), 1)
	if len(r.actions) == 0 {return}
	testing.expect_value(t, r.actions[0].space, u64(100))
	resize(&r.actions, 0)
	testing.expect_value(t, e.space_gesture_switch(&m, 200, -1), "")
	testing.expect_value(t, r.actions[0].space, u64(100))
	r.fail = true
	testing.expect(t, e.space_gesture_switch(&m, 200, -1) != "")
	testing.expect_value(t, m.displays[0].active_space, u64(200))
}

@(test)
space_swipe_single_space_does_not_refocus_itself_or_cross_display :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	e.add_space(&m, 200, 20, 2, {0, 0, 1000, 800})
	testing.expect_value(t, e.space_gesture_switch(&m, 100, 1), "")
	testing.expect_value(t, e.space_gesture_switch(&m, 100, -1), "")
	testing.expect_value(t, len(r.actions), 0)
}
