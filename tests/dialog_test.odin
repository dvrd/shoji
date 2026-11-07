package tests

import e "../src"
import "core:testing"
import layout "../src/layout"

@(test)
fixed_size_standard_windows_float_without_changing_the_tiled_view :: proc(t: ^testing.T) {
	m: e.Manager;recorder: Recorder
	fixture(&m, &recorder)
	defer e.manager_destroy(&m)
	defer delete(recorder.actions)
	before := e.space_by_id(&m, 100).view.root
	w := e.add_window(
		&m,
		{
			id = 80,
			app = "System utility",
			role = "AXWindow",
			subrole = "AXStandardWindow",
			space = 100,
			display = 1,
			frame = {200, 200, 300, 400},
			can_move = true,
			can_resize = false,
		},
	)
	testing.expect(t, w.floating)
	testing.expect(t, !e.managed(w))
	testing.expect(t, layout.find(e.space_by_id(&m, 100).view.root, w.id) == nil)
	testing.expect(t, before == e.space_by_id(&m, 100).view.root)
	testing.expect_value(t, w.frame, e.Rect{200, 200, 300, 400})
	testing.expect_value(t, e.flush(&m, e.space_by_id(&m, 100)), "")
	for action in recorder.actions {
		testing.expect(t, action.kind != .Frame || action.window != w.id)
	}
	w.layer = "below"
	testing.expect_value(t, e.apply_window_layers(&m), "")
	testing.expect_value(t, w.layer, "normal")
}

@(test)
explicit_management_can_tile_a_fixed_size_window :: proc(t: ^testing.T) {
	m: e.Manager;recorder: Recorder
	fixture(&m, &recorder)
	defer e.manager_destroy(&m)
	defer delete(recorder.actions)
	response := e.execute(&m, {"rule", "--add", "app=^Forced$", "manage=on"})
	testing.expect(t, !response.failed)
	w := e.add_window(
		&m,
		{
			id = 80,
			app = "Forced",
			role = "AXWindow",
			subrole = "AXStandardWindow",
			space = 100,
			display = 1,
			can_resize = false,
		},
	)
	testing.expect(t, !w.floating && e.managed(w))
	testing.expect(t, layout.find(e.space_by_id(&m, 100).view.root, w.id) != nil)
}

@(test)
unknown_resize_capability_does_not_exclude_standard_windows :: proc(t: ^testing.T) {
	m: e.Manager;recorder: Recorder
	fixture(&m, &recorder)
	defer e.manager_destroy(&m)
	defer delete(recorder.actions)
	w := e.add_window(
		&m,
		{
			id = 80,
			app = "Temporarily unresponsive app",
			role = "AXWindow",
			subrole = "AXStandardWindow",
			space = 100,
			display = 1,
		},
	)
	testing.expect(t, !w.floating && e.managed(w))
	testing.expect(t, layout.find(e.space_by_id(&m, 100).view.root, w.id) != nil)
}

@(test)
accessory_panels_float_above_tiled_documents_and_respect_layer_overrides :: proc(t: ^testing.T) {
	m: e.Manager;recorder: Recorder
	fixture(&m, &recorder)
	defer e.manager_destroy(&m)
	defer delete(recorder.actions)
	w := e.add_window(
		&m,
		{
			id = 80,
			app = "System Information",
			role = "AXWindow",
			subrole = "AXStandardWindow",
			space = 100,
			display = 1,
			can_resize = true,
			application_accessory = true,
		},
	)
	testing.expect(t, w.floating && !e.managed(w))
	testing.expect(t, layout.find(e.space_by_id(&m, 100).view.root, w.id) == nil)
	testing.expect_value(t, e.apply_window_layers(&m), "")
	testing.expect_value(t, w.layer, "above")
	found := false
	for action in recorder.actions {
		if action.kind == .Layer && action.window == w.id {
			found = true
			testing.expect_value(t, action.value, f64(1))
		}
	}
	testing.expect(t, found)
	w.layer_override = true
	w.layer = "normal"
	testing.expect_value(t, e.apply_window_layers(&m), "")
	testing.expect_value(t, w.layer, "normal")
}
