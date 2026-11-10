package tests

import e "../src"
import "core:testing"

// Daemon defaults from state_init layered on manager_init.
// Keep docs/CONFIGURATION.md on this list.
Config_Default :: struct {
	name: string,
	text: string,
}

CONFIG_DEFAULTS := []Config_Default {
	{"layout", "float"},
	{"window_gap", "0"},
	{"top_padding", "0"},
	{"bottom_padding", "0"},
	{"left_padding", "0"},
	{"right_padding", "0"},
	{"split_ratio", "0.5"},
	{"split_type", "auto"},
	{"auto_balance", "off"},
	{"window_placement", "second_child"},
	{"window_insertion_point", "focused"},
	{"window_origin_display", "default"},
	{"display_arrangement_order", "default"},
	{"external_bar", "off:0:0"},
	{"window_shadow", "on"},
	{"window_opacity", "off"},
	{"active_window_opacity", "1"},
	{"normal_window_opacity", "1"},
	{"window_opacity_duration", "0"},
	{"focus_ring", "on"},
	{"focus_ring_width", "3"},
	{"focus_ring_radius", "10"},
	{"focus_ring_color", "0xff7fc8ff"},
	{"insert_feedback_color", "0xffd75f5f"},
	{"tab_indicator_position", "left"},
	{"tab_indicator_width", "4"},
	{"tab_indicator_gap", "0"},
	{"tab_indicator_active_color", "default"},
	{"tab_indicator_inactive_color", "default"},
	{"tab_conceal", "off"},
	{"scroll_default_column_display", "normal"},
	{"scroll_default_column_width", "ratio:0.5"},
	{"scroll_width_presets", "ratio:0.3333333333333333,ratio:0.5,ratio:0.6666666666666666"},
	{"scroll_height_presets", "ratio:0.3333333333333333,ratio:0.5,ratio:0.6666666666666666"},
	{"scroll_center_focused_column", "never"},
	{"scroll_center_single_column", "off"},
	{"scroll_warp_pointer", "off"},
	{"scroll_animation", "on"},
	{"scroll_frame_pacing", "on"},
	{"window_resize_animation", "fade"},
	{"window_animation_duration", "0"},
	{"window_animation_easing", "ease_out_circ"},
	{"window_zoom_persist", "on"},
	{"mouse_modifier", "fn"},
	{"mouse_action1", "move"},
	{"mouse_action2", "resize"},
	{"mouse_drop_action", "swap"},
	{"focus_follows_mouse", "off"},
	{"mouse_follows_focus", "off"},
	{"scroll_gestures", "off"},
	{"three_finger_horizontal", "off"},
	{"stack_swipe", "off"},
	{"scroll_drag_edge_scroll", "on"},
	{"scroll_drag_edge_width", "30"},
	{"scroll_drag_edge_delay", "0.1"},
	{"scroll_drag_edge_speed", "1500"},
	{"dynamic_workspaces", "off"},
	{"workspace_hotplug", "off"},
}

@(test)
config_catalog_matches_daemon_defaults :: proc(t: ^testing.T) {
	bare: e.Manager
	e.manager_init(&bare)
	defer e.manager_destroy(&bare)
	testing.expect_value(t, e.execute(&bare, {"config", "window_resize_animation"}).text, "off")
	testing.expect_value(t, e.execute(&bare, {"config", "scroll_animation"}).text, "off")
	testing.expect_value(t, e.execute(&bare, {"config", "scroll_frame_pacing"}).text, "off")

	m: e.Manager
	e.manager_init(&m)
	defer e.manager_destroy(&m)
	m.resize_fade = true
	m.scroll_animate = true
	m.scroll_frame_pacing = true
	for item in CONFIG_DEFAULTS {
		response := e.execute(&m, {"config", item.name})
		testing.expectf(
			t,
			!response.failed && response.text == item.text,
			"%s: got %q failed=%v, want %q",
			item.name,
			response.text,
			response.failed,
			item.text,
		)
	}
	gate := e.execute(&m, {"config", "windowserver_gate"})
	testing.expect(t, gate.failed && gate.text == "windowserver_gate needs the daemon")
	unknown := e.execute(&m, {"config", "nope"})
	testing.expect(t, unknown.failed && unknown.text == "unsupported setting 'nope'")
	warp := e.execute(&m, {"config", "scroll_warp_pointer", "maybe"})
	testing.expect_value(t, warp.text, "scroll_warp_pointer expects on or off")
	center := e.execute(&m, {"config", "scroll_center_single_column", "maybe"})
	testing.expect_value(t, center.text, "scroll_center_single_column expects on or off")
}
