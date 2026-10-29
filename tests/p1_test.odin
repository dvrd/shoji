package tests

import loader "../src/dock"
import mac "../src"
import "base:intrinsics"
import "core:mem"
import "core:strings"
import posix "core:sys/posix"
import "core:testing"
import "core:time"

bootstrap_failed_open :: proc "c" (path: cstring, mode: i32) -> rawptr {
	return nil
}
bootstrap_failed_reason :: proc "c" () -> cstring {
	return "test load rejected"
}

@(test)
loader_failure_waits_for_acknowledgment_before_final_data_access :: proc(
	t: ^testing.T,
) {
	data := loader.Bootstrap {
		open  = bootstrap_failed_open,
		error = bootstrap_failed_reason,
	}
	thread: posix.pthread_t
	if !testing.expect(
		t,
		posix.pthread_create(&thread, nil, loader.remote_worker, &data) == nil,
	) {
		return
	}
	defer {
		intrinsics.atomic_store_explicit(&data.seen, 1, .Release)
		posix.pthread_join(thread)
	}
	deadline := time.time_add(time.now(), time.Second)
	for intrinsics.atomic_load_explicit(&data.done, .Acquire) == 0 &&
	    time.diff(time.now(), deadline) > 0 {
		time.sleep(time.Millisecond)
	}
	testing.expect_value(
		t,
		intrinsics.atomic_load_explicit(&data.done, .Acquire),
		u32(1),
	)
	testing.expect_value(
		t,
		intrinsics.atomic_load_explicit(&data.worker_finished, .Acquire),
		u32(0),
	)
	testing.expect_value(t, string(data.reason), "test load rejected")
	intrinsics.atomic_store_explicit(&data.seen, 1, .Release)
	deadline = time.time_add(time.now(), time.Second)
	for intrinsics.atomic_load_explicit(&data.worker_finished, .Acquire) ==
		    0 &&
	    time.diff(time.now(), deadline) > 0 {
		time.sleep(time.Millisecond)
	}
	testing.expect_value(
		t,
		intrinsics.atomic_load_explicit(&data.worker_finished, .Acquire),
		u32(1),
	)
}

@(test)
injector_reclaims_failed_load_data_after_worker_finishes :: proc(
	t: ^testing.T,
) {
	// Exercise the real remote-thread and dlerror handshake against this process only.
	for _ in 0 ..< 8 {
		err := loader.inject_task(
			loader.mach_task_self(),
			"/nonexistent/shoji-missing-p1-test.dylib",
		)
		testing.expect(t, strings.contains(err, "shoji-missing-p1-test"), err)
	}
}

Display_Recorder :: struct {
	order: []u32,
	focused, activated: u32,
	warped: bool,
	point: mac.Point,
	fail_focus, fail_activate, fail_warp: bool,
}
display_windows :: proc(state: ^mac.State) -> []u32 {
	return (^Display_Recorder)(state.event_user).order
}
display_focus :: proc(state: ^mac.State, id: u32) -> string {
	r := (^Display_Recorder)(state.event_user)
	if r.fail_focus {
		return "focus failed"
	}
	r.focused = id
	return ""
}
display_activate :: proc(state: ^mac.State, d: ^mac.Display) -> string {
	r := (^Display_Recorder)(state.event_user)
	if r.fail_activate {
		return "activation failed"
	}
	r.activated = d.id
	return ""
}
display_warp :: proc(state: ^mac.State, point: mac.Point) -> string {
	r := (^Display_Recorder)(state.event_user)
	if r.fail_warp {
		return "warp failed"
	}
	r.warped = true; r.point = point
	return ""
}

display_fixture :: proc(
	state: ^mac.State,
	actions: ^Recorder,
	display: ^Display_Recorder,
) {
	fixture(&state.manager, actions)
	append(
		&state.manager.displays,
		mac.Display {
			id = 20,
			index = 2,
			active_space = 200,
			frame = {1000, -100, 1200, 900},
		},
	)
	s := mac.add_space(&state.manager, 200, 20, 2, {1000, -100, 1200, 900})
	s.visible = true
	state.event_user = display
	state.display_focus_backend = {
		display_windows,
		display_focus,
		display_activate,
		display_warp,
	}
}

@(test)
display_focus_activates_visible_display_and_uses_windowserver_order :: proc(
	t: ^testing.T,
) {
	state: mac.State; actions: Recorder; display: Display_Recorder
	display_fixture(&state, &actions, &display)
	defer mac.manager_destroy(&state.manager); defer delete(actions.actions)
	for id in 3 ..= 6 {
		mac.add_window(
			&state.manager,
			mac.Window {
				id = u32(id),
				space = 200,
				display = 20,
				role = "AXWindow",
				subrole = "AXStandardWindow",
			},
		)
	}
	state.manager.windows[4].hidden = true
	state.manager.windows[5].minimized = true
	state.manager.windows[6].ordered_in = false
	display.order = []u32{1, 6, 5, 4, 3}
	response := mac.execute(
		&state.manager,
		[]string{"display", "--focus", "east"},
	)
	testing.expect(t, !response.failed)
	action := actions.actions[len(actions.actions) - 1]
	if !testing.expect_value(t, action.kind, mac.Action_Kind.Display_Focus) {
		return
	}
	testing.expect_value(t, action.display, u32(20))
	testing.expect_value(t, mac.perform_native(&state, action), "")
	testing.expect_value(t, display.focused, u32(3))
	testing.expect_value(t, display.activated, u32(20))
	testing.expect(t, !display.warped && state.dirty)
	// Observation, rather than issuing the command, advances active/recent state.
	testing.expect_value(t, state.manager.active_space, u64(100))
}

@(test)
empty_display_focus_warps_to_center_and_propagates_failures :: proc(
	t: ^testing.T,
) {
	state: mac.State; actions: Recorder; display: Display_Recorder
	display_fixture(&state, &actions, &display)
	defer mac.manager_destroy(&state.manager); defer delete(actions.actions)
	testing.expect_value(
		t,
		mac.perform_native(&state, {kind = .Display_Focus, display = 20}),
		"",
	)
	testing.expect(t, display.warped)
	testing.expect_value(t, display.point, mac.Point{1600, 350})
	testing.expect_value(t, display.activated, u32(20))
	display = Display_Recorder {
		fail_warp = true,
	}
	testing.expect_value(t, mac.focus_display(&state, 20), "warp failed")
	testing.expect_value(t, display.activated, u32(0))
	display = Display_Recorder {
		fail_activate = true,
	}
	testing.expect_value(t, mac.focus_display(&state, 20), "activation failed")
	state.read_only = true
	display = {}
	testing.expect(
		t,
		mac.perform_native(&state, {kind = .Display_Focus, display = 20}) != "",
	)
	testing.expect(t, !display.warped && display.activated == 0)
}

@(test)
populated_display_focus_failure_does_not_activate_or_warp :: proc(
	t: ^testing.T,
) {
	state: mac.State; actions: Recorder; display: Display_Recorder
	display_fixture(&state, &actions, &display)
	defer mac.manager_destroy(&state.manager); defer delete(actions.actions)
	mac.add_window(
		&state.manager,
		mac.Window {
			id = 3,
			space = 200,
			display = 20,
			role = "AXWindow",
			subrole = "AXStandardWindow",
		},
	)
	display.order = []u32{3}; display.fail_focus = true
	testing.expect_value(t, mac.focus_display(&state, 20), "focus failed")
	testing.expect(t, display.activated == 0 && !display.warped)
}

Observed_Event :: struct {
	name: string,
	window, recent_window, display, recent_display: u32,
}
Observation_Recorder :: struct {
	events: [dynamic]Observed_Event,
}
record_observation :: proc(user: rawptr, event: mac.Event) {
	r := (^Observation_Recorder)(user)
	append(
		&r.events,
		Observed_Event {
			event.name,
			event.window,
			event.recent_window,
			event.display,
			event.recent_display,
		},
	)
}

@(test)
command_focus_signals_compare_against_last_observation_once :: proc(
	t: ^testing.T,
) {
	state: mac.State; actions: Recorder; events: Observation_Recorder
	fixture(&state.manager, &actions)
	defer mac.manager_destroy(&state.manager); defer delete(actions.actions)
	defer mac.observations_destroy(&state); defer delete(events.events)
	state.event_sink, state.event_user = record_observation, &events
	mac.observe_changes(&state); clear(&events.events)
	testing.expect(
		t,
		!mac.execute(&state.manager, []string{"window", "--focus", "2"}).failed,
	)
	mac.observe_changes(&state)
	if !testing.expect_value(t, len(events.events), 4) {
		return
	}
	testing.expect_value(t, events.events[0].name, "window_focused")
	testing.expect_value(t, events.events[0].window, u32(2))
	testing.expect_value(t, events.events[0].recent_window, u32(1))
	testing.expect_value(
		t,
		events.events[1].name,
		"application_front_switched",
	)
	mac.observe_changes(&state)
	testing.expect_value(t, len(events.events), 4)
	actions.fail = true
	testing.expect(
		t,
		mac.execute(&state.manager, []string{"window", "--focus", "1"}).failed,
	)
	mac.observe_changes(&state)
	testing.expect_value(t, len(events.events), 4)
	// A mouse/AX-observed focus transition follows the same event path.
	mac.focus_window(&state.manager, 1); mac.observe_changes(&state)
	testing.expect_value(t, len(events.events), 8)
	testing.expect_value(t, events.events[4].window, u32(1))
	testing.expect_value(t, events.events[4].recent_window, u32(2))
}

@(test)
display_changed_waits_for_observation_and_has_current_and_recent_ids :: proc(
	t: ^testing.T,
) {
	state: mac.State; actions: Recorder; events: Observation_Recorder
	fixture(&state.manager, &actions)
	defer mac.manager_destroy(&state.manager); defer delete(actions.actions)
	defer mac.observations_destroy(&state); defer delete(events.events)
	append(
		&state.manager.displays,
		mac.Display{id = 20, index = 2, active_space = 200},
	)
	mac.add_space(&state.manager, 200, 20, 2, {1000, 0, 1000, 800})
	state.event_sink, state.event_user = record_observation, &events
	mac.observe_changes(&state); clear(&events.events)
	mac.workspace_record(
		&state,
		"NSWorkspaceActiveDisplayDidChangeNotification",
	)
	mac.workspace_tick(&state, detect_dock = false)
	testing.expect_value(t, len(events.events), 0)
	state.manager.active_space = 200; mac.observe_changes(&state)
	testing.expect_value(t, len(events.events), 2)
	testing.expect_value(t, events.events[1].name, "display_changed")
	testing.expect_value(t, events.events[1].display, u32(20))
	testing.expect_value(t, events.events[1].recent_display, u32(10))
	testing.expect_value(t, state.manager.last_display, u32(10))
	mac.workspace_record(
		&state,
		"NSWorkspaceActiveDisplayDidChangeNotification",
	)
	mac.workspace_tick(&state, detect_dock = false)
	mac.observe_changes(&state)
	testing.expect_value(t, len(events.events), 2)
}

@(test)
command_frame_signals_survive_optimistic_updates :: proc(t: ^testing.T) {
	state: mac.State; actions: Recorder; events: Observation_Recorder
	fixture(&state.manager, &actions)
	defer mac.manager_destroy(&state.manager); defer delete(actions.actions)
	defer mac.observations_destroy(&state); defer delete(events.events)
	state.event_sink, state.event_user = record_observation, &events
	testing.expect(
		t,
		!mac.execute(&state.manager, []string{"window", "1", "--toggle", "float"}).failed,
	)
	mac.observe_changes(&state); clear(&events.events)
	testing.expect(
		t,
		!mac.execute(&state.manager, []string{"window", "1", "--move", "abs:50:60"}).failed,
	)
	testing.expect(
		t,
		!mac.execute(&state.manager, []string{"window", "1", "--resize", "abs:640:480"}).failed,
	)
	mac.observe_changes(&state)
	if !testing.expect_value(t, len(events.events), 2) {
		return
	}
	testing.expect_value(t, events.events[0].name, "window_moved")
	testing.expect_value(t, events.events[1].name, "window_resized")
	for event in events.events { testing.expect_value(t, event.window, u32(1)) }
	mac.observe_changes(&state)
	testing.expect_value(t, len(events.events), 2)
}

@(test)
observed_snapshot_owns_titles_beyond_tick_arena_and_window_destruction :: proc(
	t: ^testing.T,
) {
	state: mac.State; actions: Recorder; events: Observation_Recorder
	fixture(&state.manager, &actions)
	defer mac.manager_destroy(&state.manager); defer delete(actions.actions)
	defer mac.observations_destroy(&state); defer delete(events.events)
	state.event_sink, state.event_user = record_observation, &events
	scratch: mem.Dynamic_Arena; mem.dynamic_arena_init(&scratch)
	{
		context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
		mac.observe_changes(&state)
	}
	mem.dynamic_arena_destroy(&scratch)
	clear(&events.events)
	mac.remove_window(&state.manager, 2)
	testing.expect_value(
		t,
		state.observed.windows[2].title,
		"quote \"and\"\nnewline",
	)
	mac.observe_changes(&state)
	testing.expect_value(t, len(events.events), 1)
	testing.expect_value(t, events.events[0].name, "window_destroyed")
	testing.expect_value(t, events.events[0].window, u32(2))
}
