package tests

import mac "../src"
import "core:testing"

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
