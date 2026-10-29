package tests

import mac "../src"
import "core:strings"
import "core:testing"

@(test)
desktop_validation_only_observes_the_owned_fixture_application :: proc(t: ^testing.T) {
	state: mac.State
	testing.expect(t, mac.observe_application(&state, 42, 0))
	testing.expect(t, mac.observe_application(&state, 42, 1))
	testing.expect(t, !mac.observe_application(&state, 42, 2))
	state.validation_pid = 42
	testing.expect(t, mac.observe_application(&state, 42, 0))
	testing.expect(t, !mac.observe_application(&state, 43, 0))
	testing.expect(t, !mac.observe_application(&state, 43, 1))
	testing.expect(t, mac.observe_application(&state, 42, 1))
}

@(test)
desktop_validation_rejects_global_commands_and_unowned_windows :: proc(t: ^testing.T) {
	state: mac.State;r: Recorder;fixture(&state.manager, &r)
	defer mac.manager_destroy(&state.manager);defer delete(r.actions)
	state.validation_pid = 42
	for kind in ([]mac.Action_Kind {
			.Space_Focus,
			.Space_Create,
			.Space_Destroy,
			.Space_Move,
			.Display_Focus,
			.Space,
		}) {
		testing.expect_value(
			t,
			mac.perform_native(&state, {kind = kind, window = 1}),
			"global desktop operations are disabled during owned-window validation",
		)
	}
	for kind in ([]mac.Action_Kind{.Frame, .Close, .Focus, .Opacity, .Layer}) {
		testing.expect_value(
			t,
			mac.perform_native(&state, {kind = kind, window = 2}),
			"window is outside the validation fixture",
		)
	}
	testing.expect(t, !state.dirty)
}

failed_display_list :: proc(_: ^mac.State, _: []u32, _: ^u32) -> i32 {return -1}
one_display_list :: proc(_: ^mac.State, ids: []u32, count: ^u32) -> i32 {
	ids[0] = 10;count^ = 1;return 0
}
failed_space_list :: proc(_: ^mac.State) -> mac.Ref {return nil}

@(test)
transient_display_failures_preserve_the_last_complete_desktop :: proc(t: ^testing.T) {
	for list in ([]proc(_: ^mac.State, _: []u32, _: ^u32) -> i32 {
			failed_display_list,
			one_display_list,
		}) {
		state: mac.State;r: Recorder;fixture(&state.manager, &r)
		defer mac.manager_destroy(&state.manager);defer delete(r.actions)
		state.manager.displays[0].label = strings.clone("work")
		space := state.manager.spaces[0]
		root := space.view.root
		state.display_probe = {list, failed_space_list}
		mac.refresh_displays(&state)
		testing.expect_value(t, len(state.manager.displays), 1)
		testing.expect_value(t, state.manager.displays[0].label, "work")
		testing.expect_value(t, state.manager.spaces[0], space)
		testing.expect_value(t, space.view.root, root)
		testing.expect(t, mac.find(root, 1) != nil && mac.find(root, 2) != nil)
	}
}
