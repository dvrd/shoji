package tests

import mac "../src"
import "core:testing"
import "core:time"

@(test)
read_only_inspection_rejects_backend_mutations_before_native_calls :: proc(t: ^testing.T) {
	state := mac.State {
		read_only = true,
	}
	testing.expect(t, mac.perform_native(&state, {kind = .Frame, window = 1}) != "")
	testing.expect(t, mac.perform_native(&state, {kind = .Space_Focus, space = 100}) != "")
	testing.expect(t, mac.perform_native(&state, {kind = .Expose, window = 1}) != "")
}

Event_Recorder :: struct {
	events: [dynamic]string,
}
record_event :: proc(user: rawptr, event: mac.Event) {
	r := (^Event_Recorder)(user);append(&r.events, event.name)
}

@(test)
mission_control_suspends_layout_until_exit :: proc(t: ^testing.T) {
	state: mac.State;recorder: Recorder
	fixture(&state.manager, &recorder)
	defer mac.manager_destroy(&state.manager);defer delete(recorder.actions)
	mac.workspace_record(&state, "AXExposeShowAllWindows")
	mac.workspace_tick(&state, detect_dock = false)
	testing.expect(t, state.manager.suspended)
	testing.expect_value(t, mac.flush(&state.manager, mac.space_by_id(&state.manager, 100)), "")
	testing.expect_value(t, len(recorder.actions), 0)
	mac.workspace_record(&state, "AXExposeExit")
	mac.workspace_tick(&state, detect_dock = false)
	testing.expect(t, !state.manager.suspended)
	testing.expect_value(t, mac.flush(&state.manager, mac.space_by_id(&state.manager, 100)), "")
	testing.expect(t, len(recorder.actions) > 0)
}

@(test)
workspace_notifications_coalesce_and_request_refresh :: proc(t: ^testing.T) {
	state: mac.State
	recorder: Event_Recorder
	state.event_sink, state.event_user = record_event, &recorder
	defer delete(recorder.events)
	mac.manager_init(&state.manager)
	defer mac.manager_destroy(&state.manager)
	mac.workspace_record(&state, "NSWorkspaceDidWakeNotification")
	mac.workspace_record(&state, "NSWorkspaceDidWakeNotification")
	mac.workspace_record(&state, "com.apple.dock.prefchanged")
	mac.workspace_record(&state, "NSWorkspaceActiveSpaceDidChangeNotification")
	mac.workspace_tick(&state, detect_dock = false)
	testing.expect(t, state.dirty)
	testing.expect_value(t, state.workspace_events.pending, mac.Workspace_Events{})
	testing.expect_value(t, len(recorder.events), 2)
	testing.expect_value(t, recorder.events[0], "system_woke")
	testing.expect_value(t, recorder.events[1], "dock_did_change_pref")
}

@(test)
application_visibility_signals_follow_snapshot_transitions :: proc(t: ^testing.T) {
	state: mac.State;recorder: Recorder;events: Event_Recorder
	fixture(&state.manager, &recorder)
	defer mac.manager_destroy(
		&state.manager,
	);defer delete(recorder.actions);defer delete(events.events)
	state.applications = make(map[i32]mac.Application)
	defer delete(state.applications)
	state.applications[42] = mac.Application {
		name = "Terminal",
	}
	state.event_sink, state.event_user = record_event, &events
	before := mac.snapshot(&state)
	state.applications[42] = mac.Application {
		name   = "Terminal",
		hidden = true,
	}
	mac.emit_changes(&state, before)
	testing.expect_value(t, len(events.events), 1)
	testing.expect_value(t, events.events[0], "application_hidden")
	before = mac.snapshot(&state)
	state.applications[42] = mac.Application {
		name = "Terminal",
	}
	mac.emit_changes(&state, before)
	testing.expect_value(t, events.events[1], "application_visible")
}

@(test)
workspace_observer_registers_and_cleans_up_without_desktop_changes :: proc(t: ^testing.T) {
	state: mac.State
	mac.manager_init(&state.manager)
	defer mac.manager_destroy(&state.manager)
	testing.expect(t, mac.workspace_start(&state))
	mac.workspace_stop(&state)
	testing.expect(t, state.workspace_events.listener == nil)
}

@(test)
wake_releases_stale_trackpad_subscription_and_scroll_drag :: proc(t: ^testing.T) {
	state: mac.State; recorder: Recorder
	niri_fixture(&state.manager, &recorder)
	defer mac.manager_destroy(&state.manager); defer delete(recorder.actions)
	state.manager.mouse.three_finger_horizontal = true
	s := state.manager.spaces[0]
	s.view.scroll.dragging = true
	state.stack_touch.attempted = true
	state.stack_touch.horizontal_active = true
	state.stack_touch.horizontal_space = s.id
	mac.workspace_record(&state, "NSWorkspaceDidWakeNotification")
	mac.workspace_tick(&state, detect_dock = false)
	testing.expect(t, !state.stack_touch.attempted)
	testing.expect(t, !state.stack_touch.horizontal_active)
	testing.expect(t, !s.view.scroll.dragging)
	testing.expect(t, state.manager.mouse.three_finger_horizontal)
}

Touch_Wake_Recorder :: struct { calls, failures: int }
touch_wake_start :: proc(state: ^mac.State) -> bool {
	r := (^Touch_Wake_Recorder)(state.event_user)
	r.calls += 1
	if r.calls <= r.failures {
		// Native startup releases partial resources on failure.
		mac.stack_touch_stop(state)
		return false
	}
	return true
}

@(test)
wake_retries_trackpad_start_until_device_returns_without_busy_loop :: proc(t: ^testing.T) {
	state: mac.State; r := Touch_Wake_Recorder{failures = 2}
	state.event_user = &r
	state.manager.mouse.three_finger_horizontal = true
	now := time.now()
	mac.stack_touch_wake(&state, now)
	mac.stack_touch_tick(&state, time.time_add(now, 500 * time.Millisecond), touch_wake_start)
	testing.expect_value(t, r.calls, 0)
	mac.stack_touch_tick(&state, time.time_add(now, time.Second), touch_wake_start)
	mac.stack_touch_tick(&state, time.time_add(now, 1500 * time.Millisecond), touch_wake_start)
	testing.expect_value(t, r.calls, 1)
	mac.stack_touch_tick(&state, time.time_add(now, 2 * time.Second), touch_wake_start)
	testing.expect_value(t, r.calls, 2)
	mac.stack_touch_tick(&state, time.time_add(now, 3 * time.Second), touch_wake_start)
	testing.expect_value(t, r.calls, 3)
	testing.expect_value(t, state.stack_touch.wake_retries, 0)
	mac.stack_touch_tick(&state, time.time_add(now, 4 * time.Second), touch_wake_start)
	testing.expect_value(t, r.calls, 3)
}

@(test)
wake_trackpad_retries_are_bounded_and_disabled_gestures_cancel_them :: proc(t: ^testing.T) {
	state: mac.State; r := Touch_Wake_Recorder{failures = 100}
	state.event_user = &r
	state.manager.mouse.stack_swipe = true
	now := time.now()
	mac.stack_touch_wake(&state, now)
	for i in 1 ..= 12 {
		mac.stack_touch_tick(&state, time.time_add(now, time.Duration(i) * time.Second), touch_wake_start)
	}
	testing.expect_value(t, r.calls, 10)
	mac.stack_touch_wake(&state, now)
	state.manager.mouse.stack_swipe = false
	mac.stack_touch_tick(&state, time.time_add(now, time.Second), touch_wake_start)
	testing.expect_value(t, r.calls, 10)
	testing.expect_value(t, state.stack_touch.wake_retries, 0)
}

@(test)
wake_cancels_desktop_swipe_when_sleep_loses_its_end_event :: proc(t: ^testing.T) {
	state: mac.State; r: Recorder
	fixture(&state.manager, &r)
	defer mac.manager_destroy(&state.manager); defer delete(r.actions)
	mac.mouse_gesture_record(&state, 23, 1, 1, time.now())
	mac.workspace_record(&state, "NSWorkspaceDidWakeNotification")
	mac.workspace_tick(&state, detect_dock = false)
	mac.mouse_gesture_tick(&state, time.time_add(time.now(), time.Second))
	testing.expect(t, !state.manager.gesture_active && !state.mouse.gesture)
	testing.expect_value(t, mac.flush(&state.manager, state.manager.spaces[0]), "")
	testing.expect(t, len(r.actions) > 0)
}

@(test)
wake_discards_interrupted_pointer_actions_and_releases_window_grab :: proc(t: ^testing.T) {
	state: mac.State; r: Recorder
	niri_fixture(&state.manager, &r)
	defer mac.manager_destroy(&state.manager); defer delete(r.actions)
	w := state.manager.windows[1]; s := state.manager.spaces[0]
	w.grabbed = true; s.view.scroll.dragging = true
	state.manager.native_resize_window = w.id
	state.mouse.drag.window = w.id
	state.mouse.phase = .Dragging; state.mouse.pending = true
	state.mouse.buttons = 1
	state.mouse.scroll.space = s.id; state.mouse.scroll.owned = true
	state.mouse.scroll_tracking = true; state.mouse.scroll_delta = 80
	state.mouse.space_origin = s.id; state.mouse.space_direction = 1
	state.mouse.tab_pending = w.id; state.mouse.edge_double_pending = w.id
	mac.workspace_record(&state, "NSWorkspaceDidWakeNotification")
	mac.workspace_tick(&state, detect_dock = false)
	testing.expect(t, !w.grabbed && !s.view.scroll.dragging)
	testing.expect_value(t, state.manager.native_resize_window, u32(0))
	testing.expect_value(t, state.mouse.drag.window, u32(0))
	testing.expect_value(t, state.mouse.buttons, u8(0))
	testing.expect(t, !state.mouse.pending && !state.mouse.scroll.owned && !state.mouse.scroll_tracking)
	testing.expect_value(t, state.mouse.scroll_delta, f64(0))
	testing.expect_value(t, state.mouse.space_direction, 0)
	testing.expect_value(t, state.mouse.tab_pending, u32(0))
	testing.expect_value(t, state.mouse.edge_double_pending, u32(0))
}
