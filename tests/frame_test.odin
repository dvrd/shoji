package tests

import mac "../src"
import native "../src/native"
import "core:strings"
import "core:testing"

Frame_Recorder :: struct {
	enhanced:      bool,
	applied_error: i32,
	names:         [dynamic]string,
	fail_at:       int,
	restored:      bool,
}
frame_enhanced :: proc(user: rawptr, _: mac.Ref) -> bool {
	return (^Frame_Recorder)(user).enhanced
}
frame_set :: proc(user: rawptr, element: mac.Ref, name: string, value: mac.Ref) -> i32 {
	r := (^Frame_Recorder)(user)
	append(&r.names, name)
	if r.fail_at == len(r.names) {
		return -1
	}
	if name == "AXEnhancedUserInterface" {
		r.enhanced = value == native.kCFBooleanTrue
		if r.enhanced {
			r.restored = true
		}
		return r.applied_error
	}
	return 0
}

@(test)
enhanced_ui_is_restored_after_frame_success_and_failure :: proc(t: ^testing.T) {
	for fail_at in ([]int{0, 1, 3, 4, 5}) {
		r := Frame_Recorder {
			enhanced = true,
			fail_at  = fail_at,
		}
		err := mac.apply_accessibility_frame(
			nil,
			nil,
			{10, 20, 300, 200},
			{&r, frame_enhanced, frame_set},
		)
		testing.expect_value(t, err == "", fail_at != 3 && fail_at != 4)
		testing.expect_value(t, len(r.names), 5)
		testing.expect_value(t, r.names[0], "AXEnhancedUserInterface")
		testing.expect_value(t, r.names[1], "AXSize")
		testing.expect_value(t, r.names[2], "AXPosition")
		testing.expect_value(t, r.names[3], "AXSize")
		testing.expect_value(t, r.names[4], "AXEnhancedUserInterface")
		testing.expect_value(t, r.restored, fail_at != 5)
		if fail_at == 3 || fail_at == 4 {
			testing.expect(t, strings.contains(err, "set window frame"))
		}
		delete(r.names)
	}
}

@(test)
frame_writes_preserve_disabled_enhanced_ui :: proc(t: ^testing.T) {
	r: Frame_Recorder
	testing.expect_value(
		t,
		mac.apply_accessibility_frame(nil, nil, {0, 0, 300, 200}, {&r, frame_enhanced, frame_set}),
		"",
	)
	testing.expect_value(t, len(r.names), 3)
	testing.expect(t, !r.restored)
	delete(r.names)
}

@(test)
known_frame_resizes_and_moves_without_redundant_attribute_writes :: proc(t: ^testing.T) {
	frames := []mac.Rect{{10, 20, 400, 200}, {30, 20, 300, 200}, {10, 20, 300, 200}}
	names := []string{"AXSize", "AXPosition", ""}
	for target, i in frames {
		r: Frame_Recorder
		err := mac.apply_accessibility_frame(
			nil,
			nil,
			target,
			{&r, frame_enhanced, frame_set},
			mac.Rect{10, 20, 300, 200},
		)
		testing.expect_value(t, err, "")
		if names[i] == "" {
			testing.expect_value(t, len(r.names), 0)
		} else {
			testing.expect_value(t, len(r.names), 1)
			testing.expect_value(t, r.names[0], names[i])
		}
		delete(r.names)
	}
}

Frame_Update_Recorder :: struct {
	enabled:      [dynamic]bool,
	fail_disable: bool,
}
frame_update_set :: proc(user: rawptr, _: i32, enabled: bool) -> i32 {
	r := (^Frame_Update_Recorder)(user)
	append(&r.enabled, enabled)
	return !enabled && r.fail_disable ? -1 : 0
}

@(test)
nested_frame_batches_present_only_after_the_last_window_update :: proc(t: ^testing.T) {
	state: mac.State; r: Frame_Update_Recorder
	defer delete(r.enabled)
	state.frame_updates.user = &r
	state.frame_updates.set_enabled = frame_update_set
	testing.expect_value(t, mac.frame_updates_begin(&state), "")
	testing.expect_value(t, mac.frame_updates_begin(&state), "")
	testing.expect_value(t, mac.frame_updates_end(&state), "")
	testing.expect_value(t, len(r.enabled), 1)
	testing.expect_value(t, mac.frame_updates_end(&state), "")
	testing.expect_value(t, len(r.enabled), 2)
	testing.expect_value(t, r.enabled[0], false)
	testing.expect_value(t, r.enabled[1], true)
	testing.expect_value(t, state.frame_updates.depth, 0)
	r.fail_disable = true
	testing.expect(t, mac.frame_updates_begin(&state) != "")
	testing.expect_value(t, state.frame_updates.depth, 0)
}

@(test)
resize_presentation_is_reenabled_after_a_frame_write_fails :: proc(t: ^testing.T) {
	state: mac.State; r: Recorder; updates: Frame_Update_Recorder
	fixture(&state.manager, &r)
	defer mac.manager_destroy(&state.manager); defer delete(r.actions)
	defer delete(updates.enabled)
	mac.flush(&state.manager, mac.space_by_id(&state.manager, 100))
	state.frame_updates.user = &updates
	state.frame_updates.set_enabled = frame_update_set
	state.mouse.drag = mac.mouse_begin(&state.manager, 1, .Resize, {499, 400})
	state.mouse.point = {599, 400}; state.mouse.pending = true
	state.mouse.phase = .Dragging
	r.fail = true
	mac.mouse_tick(&state)
	testing.expect(t, state.mouse.failed)
	testing.expect_value(t, state.frame_updates.depth, 0)
	testing.expect_value(t, len(updates.enabled), 2)
	testing.expect_value(t, updates.enabled[1], true)
}

@(test)
position_only_motion_ignores_subpoint_size_rounding :: proc(t: ^testing.T) {
	r: Frame_Recorder
	defer delete(r.names)
	err := mac.apply_accessibility_frame(
		nil,
		nil,
		{30, 20, 616.25, 767.75},
		{&r, frame_enhanced, frame_set},
		mac.Rect{10, 20, 616, 768},
		size_tolerance = .5,
	)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(r.names), 1)
	if len(r.names) > 0 {
		testing.expect_value(t, r.names[0], "AXPosition")
	}
}

@(test)
halfpoint_resize_remains_a_real_native_resize :: proc(t: ^testing.T) {
	r: Frame_Recorder
	defer delete(r.names)
	err := mac.apply_accessibility_frame(
		nil,
		nil,
		{10, 20, 616.5, 768},
		{&r, frame_enhanced, frame_set},
		mac.Rect{10, 20, 616, 768},
		size_tolerance = .5,
	)
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(r.names), 1)
	if len(r.names) > 0 {
		testing.expect_value(t, r.names[0], "AXSize")
	}
}


@(test)
frame_writes_continue_when_enhanced_ui_reports_an_error_after_applying :: proc(t: ^testing.T) {
	for failure in ([]int{0, 3}) {
		r := Frame_Recorder {
			enhanced      = true,
			applied_error = -25208,
			fail_at       = failure,
		}
		err := mac.apply_accessibility_frame(
			nil,
			nil,
			{10, 20, 300, 200},
			{&r, frame_enhanced, frame_set},
		)
		testing.expect_value(t, err == "", failure == 0)
		testing.expect_value(t, len(r.names), 5)
		testing.expect(t, r.restored && r.enhanced)
		if failure != 0 {
			testing.expect(t, strings.contains(err, "set window frame"))
		}
		delete(r.names)
	}
}

@(test)
server_placed_frame_still_writes_position :: proc(t: ^testing.T) {
	// WindowServer already shows the target after a gated move; the app does
	// not know. Untouched, the write is skipped; flagged, AXPosition is sent.
	shown := mac.Rect{0, 30, 1120, 1123}
	for placed in ([]bool{false, true}) {
		r: Frame_Recorder
		defer delete(r.names)
		err := mac.apply_accessibility_frame(
			nil, nil, shown, {&r, frame_enhanced, frame_set},
			mac.frame_write_previous(shown, placed),
		)
		testing.expect_value(t, err, "")
		testing.expect_value(t, len(r.names), placed ? 1 : 0)
		if placed && len(r.names) == 1 {testing.expect_value(t, r.names[0], "AXPosition")}
	}
	// A resize after placement writes the full frame (position included).
	r: Frame_Recorder
	defer delete(r.names)
	_ = mac.apply_accessibility_frame(
		nil, nil, {0, 30, 2240, 1123}, {&r, frame_enhanced, frame_set},
		mac.frame_write_previous(shown, true),
	)
	testing.expect(t, slice_has(r.names[:], "AXPosition"))
	testing.expect_value(t, mac.frame_write_previous(nil, true), nil)
}

slice_has :: proc(names: []string, name: string) -> bool {
	for n in names {if n == name {return true}}
	return false
}
