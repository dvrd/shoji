package tests

import e "../src/engine"
import "core:testing"

@(test)
space_override_keys_outlive_the_ipc_request_buffer :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	setting := make([]byte, len("window_gap"))
	defer delete(setting)
	copy(setting, "window_gap")
	testing.expect(t, !e.config(&m, []string{"--space", "1", string(setting), "17"}).failed)
	setting[0] = 'X'
	testing.expect(t, e.space_by_id(&m, 100).overrides["window_gap"])
	testing.expect(t, !e.config(&m, []string{"window_gap", "30"}).failed)
	testing.expect_value(t, e.space_by_id(&m, 100).view.gap, f64(17))
}

@(test)
windowed_fullscreen_restores_frame_and_respects_backend_failures :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	s := e.space_by_id(&m, 100)
	testing.expect_value(t, e.flush(&m, s), "")
	w := m.windows[1];previous := w.frame
	testing.expect(
		t,
		!e.window_command(&m, []string{"1", "--toggle", "windowed-fullscreen"}).failed,
	)
	testing.expect_value(t, w.frame, m.displays[0].usable)
	testing.expect_value(t, e.flush(&m, s), "")
	testing.expect_value(t, w.frame, m.displays[0].usable)
	r.fail = true
	testing.expect(
		t,
		e.window_command(&m, []string{"1", "--toggle", "windowed-fullscreen"}).failed,
	)
	testing.expect(t, w.windowed_frame != nil)
	r.fail = false
	testing.expect(
		t,
		!e.window_command(&m, []string{"1", "--toggle", "windowed-fullscreen"}).failed,
	)
	testing.expect_value(t, w.frame, previous)
	testing.expect(t, w.windowed_frame == nil)
	testing.expect(t, !e.window_command(&m, []string{"1", "--toggle", "expose"}).failed)
	testing.expect_value(t, r.actions[len(r.actions) - 1].kind, e.Action_Kind.Expose)
}

@(test)
automatic_layers_preserve_manual_overrides_and_reset_with_auto :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	testing.expect(t, !e.window_command(&m, []string{"1", "--sub-layer", "above"}).failed)
	testing.expect_value(t, e.apply_window_layers(&m), "")
	testing.expect_value(t, m.windows[1].layer, "above")
	testing.expect_value(t, m.windows[2].layer, "below")
	testing.expect(t, !e.window_command(&m, []string{"1", "--sub-layer", "auto"}).failed)
	testing.expect(t, !m.windows[1].layer_override)
	testing.expect_value(t, m.windows[1].layer, "below")
	m.windows[1].floating = true
	testing.expect_value(t, e.apply_window_layers(&m), "")
	testing.expect_value(t, m.windows[1].layer, "normal")
}

@(test)
external_bar_preserves_screen_bounds_and_space_padding :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	m.main_display = 10
	s := e.space_by_id(&m, 100)
	s.view.padding.top = 5
	testing.expect(t, !e.config(&m, []string{"external_bar", "main:30:20"}).failed)
	testing.expect_value(t, s.view.frame, e.Rect{0, 30, 1000, 750})
	testing.expect_value(t, s.view.padding.top, f64(5))
	testing.expect_value(t, m.displays[0].usable, e.Rect{0, 0, 1000, 800})
	append(&m.displays, e.Display{id = 11, usable = {1000, 0, 800, 600}})
	other := e.add_space(&m, 200, 11, 2, {1000, 0, 800, 600})
	testing.expect_value(t, other.view.frame, e.Rect{1000, 0, 800, 600})
	testing.expect(t, !e.config(&m, []string{"external_bar", "all:30:20"}).failed)
	testing.expect_value(t, other.view.frame, e.Rect{1000, 30, 800, 550})
	testing.expect(t, !e.config(&m, []string{"external_bar", "off:0:0"}).failed)
	testing.expect_value(t, s.view.frame, m.displays[0].usable)
	for invalid in ([]string{"main", "main:NaN:20", "all:-1:0", "invalid:1:2"}) {
		testing.expect(t, e.config(&m, []string{"external_bar", invalid}).failed)
	}
}

@(test)
display_order_and_window_origin_use_configured_displays :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	m.displays[0].native_index = 1
	append(
		&m.displays,
		e.Display{id = 20, native_index = 2, active_space = 200, frame = {-1000, -800, 1000, 800}},
	)
	e.add_space(&m, 200, 20, 2, {-1000, -800, 1000, 800})
	testing.expect(t, !e.config(&m, []string{"display_arrangement_order", "horizontal"}).failed)
	testing.expect_value(t, e.select_display(&m, "1").id, u32(20))
	testing.expect(t, !e.config(&m, []string{"display_arrangement_order", "default"}).failed)
	testing.expect_value(t, e.select_display(&m, "1").id, u32(10))
	m.mouse_display = 20
	testing.expect(t, !e.config(&m, []string{"window_origin_display", "cursor"}).failed)
	w := e.add_window(
		&m,
		e.Window {
			id = 3,
			space = 100,
			display = 10,
			role = "AXWindow",
			subrole = "AXStandardWindow",
		},
	)
	testing.expect_value(t, w.space, u64(200))
	testing.expect(t, e.find(e.space_by_id(&m, 200).view.root, 3) != nil)
	r.fail = true
	w = e.add_window(
		&m,
		e.Window {
			id = 4,
			space = 100,
			display = 10,
			role = "AXWindow",
			subrole = "AXStandardWindow",
		},
	)
	testing.expect_value(t, w.space, u64(100))
}

@(test)
shadow_mode_tracks_managed_and_floating_windows :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	m.windows[2].floating = true
	testing.expect(t, !e.config(&m, []string{"window_shadow", "float"}).failed)
	testing.expect(t, !m.windows[1].shadow && m.windows[2].shadow)
	testing.expect(t, !e.config(&m, []string{"window_shadow", "off"}).failed)
	testing.expect(t, !m.windows[1].shadow && !m.windows[2].shadow)
	r.fail = true
	testing.expect(t, e.config(&m, []string{"window_shadow", "on"}).failed)
	testing.expect_value(t, e.config(&m, []string{"window_shadow"}).text, "off")
}

@(test)
zoom_persistence_survives_tree_rebuilds_and_cleans_references :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	s := e.space_by_id(&m, 100)
	n := e.find(s.view.root, 1);n.zoom = s.view.root
	e.add_window(
		&m,
		e.Window{id = 3, space = 100, role = "AXWindow", subrole = "AXStandardWindow"},
	)
	testing.expect_value(t, e.find(s.view.root, 1).zoom, s.view.root)
	e.remove_window(&m, 2)
	testing.expect_value(t, e.find(s.view.root, 1).zoom, s.view.root)
	e.set_layout(&m, s, .Stack)
	testing.expect_value(t, e.find(s.view.root, 1).zoom, s.view.root)
	e.set_layout(&m, s, .BSP)
	testing.expect_value(t, e.find(s.view.root, 1).zoom, s.view.root)
	testing.expect(t, !e.config(&m, []string{"window_zoom_persist", "off"}).failed)
	e.remove_window(&m, 3)
	testing.expect(t, e.find(s.view.root, 1).zoom == nil)
}
