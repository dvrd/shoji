package tests

import e "../src"
import layout "../src/layout"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
ephemeral_empty :: proc(m: ^e.Manager) -> int {
	n := 0
	for s in m.spaces {
		if s.ephemeral && s.label == "" && !s.kept && !e.workspace_occupied(m, s) {
			n += 1
		}
	}
	return n
}

@(private = "file")
scroll_neighbor :: proc(m: ^e.Manager, id: u64, display: u32) -> ^e.Space {
	s := e.add_space(m, id, display, u32(len(m.spaces) + 1), {0, 0, 1280, 800})
	e.set_layout(m, s, .Scroll)
	s.view.gap = 16
	s.view.frame = {0, 0, 1280, 800}
	return s
}

@(private = "file")
open_on :: proc(m: ^e.Manager, id: u32, space: u64, display: u32) {
	e.add_window(
		m,
		e.Window {
			id = id,
			pid = i32(id) + 40,
			role = "AXWindow",
			subrole = "AXStandardWindow",
			space = space,
			display = display,
		},
	)
}

@(private = "file")
overview_window_point :: proc(m: ^e.Manager, id: u32) -> e.Point {
	frame := m.windows[id].frame
	return {frame.x + frame.w * 0.5, frame.y + frame.h * 0.5}
}

@(private = "file")
overview_band_point :: proc(m: ^e.Manager, space: u64) -> e.Point {
	for i in 0 ..< m.overview.band_count {
		band := m.overview.bands[i]
		if band.space == space {
			return {band.frame.x + band.frame.w * 0.5, band.frame.y + band.frame.h * 0.5}
		}
	}
	return {}
}

// Presses on a thumbnail, holds through the edge delay, ticks again after the
// pointer has left that thumbnail with the button still down, then releases.
// Events go through mouse_callback; mouse_tick is what calls overview_pointer.
@(private = "file")
overview_drag :: proc(t: ^testing.T, state: ^e.State, from, to: e.Point, window: u32) {
	down := CGEventCreateMouseEvent(nil, 1, from, 0)
	defer e.CFRelease(down)
	CGEventSetIntegerValueField(down, 91, 1)
	e.mouse_callback(nil, 1, down, state)
	base := time.now()
	e.mouse_tick(state, false, base)
	e.mouse_tick(state, false, time.time_add(base, 100 * time.Millisecond))
	move := CGEventCreateMouseEvent(nil, 6, to, 0)
	defer e.CFRelease(move)
	e.mouse_callback(nil, 6, move, state)
	e.mouse_tick(state, false, time.time_add(base, 150 * time.Millisecond))
	testing.expect(t, state.mouse.overview_down)
	testing.expect_value(t, state.manager.overview.dragging, window)
	up := CGEventCreateMouseEvent(nil, 2, to, 0)
	defer e.CFRelease(up)
	e.mouse_callback(nil, 2, up, state)
	e.mouse_tick(state, false, time.time_add(base, 200 * time.Millisecond))
}

@(private = "file")
action_spaces :: proc(r: ^Recorder, kind: e.Action_Kind, out: []u64) -> int {
	n := 0
	for a in r.actions {
		if a.kind != kind {
			continue
		}
		if n < len(out) {
			out[n] = a.space
		}
		n += 1
	}
	return n
}

@(test)
dynamic_workspaces_keep_one_empty_trailer :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect_value(t, e.execute(&m, []string{"config", "dynamic_workspaces"}).text, "off")
	resize(&r.actions, 0)
	testing.expect(t, !e.execute(&m, []string{"config", "dynamic_workspaces", "on"}).failed)
	testing.expect_value(t, e.execute(&m, []string{"config", "dynamic_workspaces"}).text, "on")
	testing.expect_value(t, len(m.spaces), 2)
	testing.expect_value(t, ephemeral_empty(&m), 1)
	created: [4]u64
	n := action_spaces(&r, .Space_Create, created[:])
	testing.expect_value(t, n, 1)
	testing.expect_value(t, created[0], u64(100))
	testing.expect(t, m.spaces[1].ephemeral)
	testing.expect(t, e.workspace_pending_get(&m, 10) == m.spaces[1].id)

	e.remove_window(&m, 1)
	testing.expect_value(t, len(m.spaces), 1)
	testing.expect(t, m.spaces[0].ephemeral)
	testing.expect_value(t, m.active_space, m.spaces[0].id)
	testing.expect(t, e.space_by_id(&m, 100) == nil)
	destroyed: [4]u64
	n = action_spaces(&r, .Space_Destroy, destroyed[:])
	testing.expect_value(t, n, 1)
	testing.expect_value(t, destroyed[0], u64(100))
}

@(test)
dynamic_workspaces_keep_named_spaces_and_drop_interior_empties :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect(t, !e.execute(&m, []string{"space", "--label", "work"}).failed)
	testing.expect(t, !e.execute(&m, []string{"config", "dynamic_workspaces", "on"}).failed)
	e.remove_window(&m, 1)
	named := e.space_by_id(&m, 100)
	testing.expect(t, named != nil && named.label == "work")
	testing.expect_value(t, ephemeral_empty(&m), 1)
	testing.expect_value(t, len(m.spaces), 2)

	testing.expect(t, !e.execute(&m, []string{"config", "dynamic_workspaces", "off"}).failed)
	testing.expect_value(t, ephemeral_empty(&m), 0)
	testing.expect(t, e.space_by_id(&m, 100) != nil)
}

@(test)
dynamic_workspaces_destroy_an_interior_empty_and_keep_fullscreen :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	mid := scroll_neighbor(&m, 200, 10)
	mid_id := mid.id
	end := scroll_neighbor(&m, 300, 10)
	open_on(&m, 3, end.id, 10)
	full := e.add_space(&m, 400, 10, 4, {0, 0, 1280, 800})
	full.fullscreen = true
	testing.expect(t, !e.execute(&m, []string{"config", "dynamic_workspaces", "on"}).failed)
	testing.expect(t, e.space_by_id(&m, mid_id) == nil)
	testing.expect(t, e.space_by_id(&m, 100) != nil)
	testing.expect(t, e.space_by_id(&m, 300) != nil)
	testing.expect(t, e.space_by_id(&m, 400) != nil && e.space_by_id(&m, 400).fullscreen)
	testing.expect_value(t, ephemeral_empty(&m), 1)
}

@(test)
dynamic_workspace_create_failure_leaves_the_list_unchanged :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	before := len(m.spaces)
	r.fail = true
	testing.expect(t, !e.execute(&m, []string{"config", "dynamic_workspaces", "on"}).failed)
	testing.expect_value(t, len(m.spaces), before)
	testing.expect_value(t, ephemeral_empty(&m), 0)
	testing.expect(
		t,
		e.execute(&m, []string{"config", "--space", "100", "dynamic_workspaces", "on"}).failed,
	)
}

@(test)
vertical_navigation_stays_on_one_display :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	scroll_neighbor(&m, 200, 10)
	append(
		&m.displays,
		e.Display {
			id = 20,
			index = 2,
			frame = {1000, 0, 800, 600},
			usable = {1000, 0, 800, 600},
			active_space = 300,
		},
	)
	scroll_neighbor(&m, 300, 20)
	testing.expect(t, !e.execute(&m, []string{"space", "--vertical", "down"}).failed)
	testing.expect_value(t, m.active_space, u64(200))
	testing.expect(t, !e.execute(&m, []string{"space", "--vertical", "down"}).failed)
	testing.expect_value(t, m.active_space, u64(200))
	testing.expect(t, !e.execute(&m, []string{"space", "--vertical", "up"}).failed)
	testing.expect_value(t, m.active_space, u64(100))
	testing.expect(t, !e.execute(&m, []string{"space", "--vertical", "back"}).failed)
	testing.expect_value(t, m.active_space, u64(200))
	testing.expect(t, !e.execute(&m, []string{"space", "--vertical", "1"}).failed)
	testing.expect_value(t, m.active_space, u64(100))
	testing.expect(t, e.execute(&m, []string{"space", "--vertical", "9"}).failed)
	testing.expect_value(t, m.active_space, u64(100))
}

@(test)
send_window_and_column_keep_focus_and_collapse_the_source :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	scroll_neighbor(&m, 200, 10)
	open_on(&m, 3, 200, 10)
	testing.expect(t, !e.execute(&m, []string{"config", "dynamic_workspaces", "on"}).failed)
	testing.expect(t, !e.execute(&m, []string{"space", "--send-window", "down"}).failed)
	testing.expect_value(t, m.windows[1].space, u64(200))
	testing.expect_value(t, m.focused, u32(1))
	testing.expect(t, e.space_by_id(&m, 100) == nil)
	testing.expect_value(t, ephemeral_empty(&m), 1)
}

@(test)
send_column_keeps_membership_and_focus :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2)
	testing.expect(t, !e.execute(&m, []string{"window", "1", "--stack", "2"}).failed)
	testing.expect(t, !e.execute(&m, []string{"window", "1", "--column-display", "tabbed"}).failed)
	testing.expect(t, !e.execute(&m, []string{"window", "1", "--focus"}).failed)
	scroll_neighbor(&m, 200, 10)
	testing.expect(t, !e.execute(&m, []string{"space", "--send-column", "down"}).failed)
	testing.expect_value(t, m.focused, u32(1))
	testing.expect_value(t, m.windows[1].space, u64(200))
	testing.expect_value(t, m.windows[2].space, u64(200))
	node := layout.find(e.space_by_id(&m, 200).view.root, 1)
	testing.expect(t, node != nil && node.count == 2 && node.column_tabbed)
	testing.expect_value(t, node.windows[0], u32(1))
	testing.expect_value(t, node.windows[1], u32(2))
}

@(test)
nudge_swaps_neighbors_and_refuses_fullscreen :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	scroll_neighbor(&m, 200, 10)
	testing.expect(t, !e.execute(&m, []string{"space", "--nudge", "down"}).failed)
	testing.expect_value(t, m.spaces[0].id, u64(200))
	testing.expect_value(t, m.spaces[1].id, u64(100))
	testing.expect_value(t, m.active_space, u64(100))
	testing.expect(t, !e.execute(&m, []string{"space", "--nudge", "down"}).failed)
	testing.expect_value(t, m.spaces[0].id, u64(200))
	testing.expect_value(t, m.spaces[1].id, u64(100))
	m.spaces[1].fullscreen = true
	testing.expect(t, e.execute(&m, []string{"space", "--nudge", "up"}).failed)
	testing.expect_value(t, m.spaces[0].id, u64(200))
}

@(test)
overview_keyboard_navigation_focuses_on_done :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2)
	testing.expect(t, !e.execute(&m, []string{"window", "1", "--focus"}).failed)
	scroll_neighbor(&m, 200, 10)
	open_on(&m, 3, 200, 10)
	testing.expect(t, !e.execute(&m, []string{"space", "--overview", "enter"}).failed)
	testing.expect(t, m.overview.active)
	testing.expect(t, m.windows[1].frame.h < 200)
	testing.expect_value(t, m.focused, u32(1))
	testing.expect_value(t, m.overview.space, u64(100))
	testing.expect_value(t, m.overview.window, u32(1))
	testing.expect(t, !e.execute(&m, []string{"space", "--overview", "up"}).failed)
	testing.expect_value(t, m.overview.space, u64(100))
	testing.expect_value(t, m.overview.window, u32(1))
	testing.expect(t, !e.execute(&m, []string{"space", "--overview", "left"}).failed)
	testing.expect_value(t, m.overview.window, u32(1))
	testing.expect(t, !e.execute(&m, []string{"space", "--overview", "right"}).failed)
	testing.expect_value(t, m.overview.window, u32(2))
	testing.expect(t, !e.execute(&m, []string{"space", "--overview", "right"}).failed)
	testing.expect_value(t, m.overview.window, u32(2))
	testing.expect(t, !e.execute(&m, []string{"space", "--overview", "left"}).failed)
	testing.expect_value(t, m.overview.window, u32(1))
	testing.expect_value(t, m.focused, u32(1))
	testing.expect(t, !e.execute(&m, []string{"space", "--overview", "down"}).failed)
	testing.expect_value(t, m.focused, u32(1))
	testing.expect_value(t, m.overview.space, u64(200))
	testing.expect_value(t, m.overview.window, u32(3))
	testing.expect(t, !e.execute(&m, []string{"space", "--overview", "up"}).failed)
	testing.expect_value(t, m.overview.space, u64(100))
	testing.expect_value(t, m.overview.window, u32(1))
	testing.expect_value(t, m.focused, u32(1))
	testing.expect(t, !e.execute(&m, []string{"space", "--overview", "down"}).failed)
	testing.expect(t, !e.execute(&m, []string{"space", "--overview", "done"}).failed)
	testing.expect(t, !m.overview.active)
	testing.expect_value(t, m.focused, u32(3))
	testing.expect_value(t, m.active_space, u64(200))
}

@(test)
overview_cancel_restores_membership_and_drops_inserts :: proc(t: ^testing.T) {
	state: e.State; r: Recorder; niri_fixture(&state.manager, &r)
	defer e.manager_destroy(&state.manager); defer delete(r.actions)
	m := &state.manager
	scroll_neighbor(m, 200, 10)
	testing.expect(t, !e.execute(m, []string{"space", "--overview", "enter"}).failed)
	before := len(m.spaces)
	testing.expect(t, !e.execute(m, []string{"space", "--overview", "insert"}).failed)
	testing.expect_value(t, len(m.spaces), before + 1)
	overview_drag(t, &state, overview_window_point(m, 1), overview_band_point(m, 200), 1)
	testing.expect_value(t, m.windows[1].space, u64(200))
	testing.expect(t, !e.execute(m, []string{"space", "--overview", "cancel"}).failed)
	testing.expect(t, !m.overview.active)
	testing.expect_value(t, len(m.spaces), before)
	testing.expect_value(t, m.windows[1].space, u64(100))
	testing.expect_value(t, m.focused, u32(1))
	testing.expect_value(t, m.active_space, u64(100))
	testing.expect(t, layout.find(m.spaces[0].view.root, 1) != nil)
}

@(test)
overview_done_keeps_a_drop_and_pan_moves_the_strip :: proc(t: ^testing.T) {
	state: e.State; r: Recorder; niri_fixture(&state.manager, &r)
	defer e.manager_destroy(&state.manager); defer delete(r.actions)
	m := &state.manager
	scroll_neighbor(m, 200, 10)
	scroll_neighbor(m, 300, 10)
	m.displays[0].usable.h = 300
	testing.expect(t, !e.execute(m, []string{"space", "--overview", "enter"}).failed)
	overview_drag(t, &state, overview_window_point(m, 1), overview_band_point(m, 200), 1)
	testing.expect_value(t, m.windows[1].space, u64(200))
	before := m.overview.pan
	testing.expect(t, !e.execute(m, []string{"space", "--overview", "pan-down"}).failed)
	testing.expect(t, m.overview.pan > before)
	testing.expect(t, !e.execute(m, []string{"space", "--overview", "done"}).failed)
	testing.expect_value(t, m.windows[1].space, u64(200))
	testing.expect(t, !m.overview.active)
	testing.expect_value(t, m.focused, u32(1))
}

@(test)
overview_long_press_drags_a_window_onto_another_band :: proc(t: ^testing.T) {
	state: e.State; r: Recorder; niri_fixture(&state.manager, &r)
	defer e.manager_destroy(&state.manager); defer delete(r.actions)
	m := &state.manager
	scroll_neighbor(m, 200, 10)
	testing.expect(t, !e.execute(m, []string{"space", "--overview", "enter"}).failed)
	down := CGEventCreateMouseEvent(nil, 1, overview_window_point(m, 1), 0)
	defer e.CFRelease(down)
	CGEventSetIntegerValueField(down, 91, 1)
	testing.expect(t, e.mouse_callback(nil, 1, down, &state) == nil)
	testing.expect_value(t, state.mouse.drag.window, u32(0))
	base := time.now()
	e.mouse_tick(&state, false, base)
	testing.expect_value(t, m.overview.dragging, u32(0))
	e.mouse_tick(&state, false, base)
	testing.expect_value(t, m.overview.dragging, u32(0))
	e.mouse_tick(&state, false, time.time_add(base, 100 * time.Millisecond))
	testing.expect_value(t, m.overview.dragging, u32(1))
	release := overview_band_point(m, 200)
	move := CGEventCreateMouseEvent(nil, 6, release, 0)
	defer e.CFRelease(move)
	testing.expect(t, e.mouse_callback(nil, 6, move, &state) == nil)
	e.mouse_tick(&state, false, time.time_add(base, 150 * time.Millisecond))
	testing.expect(t, state.mouse.overview_down)
	testing.expect_value(t, m.overview.dragging, u32(1))
	up := CGEventCreateMouseEvent(nil, 2, release, 0)
	defer e.CFRelease(up)
	testing.expect(t, e.mouse_callback(nil, 2, up, &state) == nil)
	testing.expect_value(t, state.mouse.drag.window, u32(0))
	e.mouse_tick(&state, false, time.time_add(base, 200 * time.Millisecond))
	testing.expect_value(t, m.windows[1].space, u64(200))
}

@(test)
hold_to_activate_uses_the_edge_delay :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2)
	e.focus_window(&m, 1)
	mouse: e.Mouse_State
	mouse.drag.window = 1
	mouse.drag.action = .Move
	e.drag_hold_activate(&m, &mouse, 2, 0)
	testing.expect_value(t, m.focused, u32(1))
	e.drag_hold_activate(&m, &mouse, 2, 0.1)
	testing.expect_value(t, m.focused, u32(2))
	mouse.drag.window = 2
	e.drag_hold_activate(&m, &mouse, 2, 1)
	testing.expect_value(t, m.focused, u32(2))
}

@(test)
overview_edge_scrolls_after_the_edge_delay :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	scroll_neighbor(&m, 200, 10)
	scroll_neighbor(&m, 300, 10)
	m.displays[0].usable.h = 300
	testing.expect(t, !e.execute(&m, []string{"space", "--overview", "enter"}).failed)
	usable := m.displays[0].usable
	point := e.Mouse_Point{usable.x + 10, usable.y + usable.h - 5}
	testing.expect(t, e.overview_edge(&m, point, 0) == "")
	testing.expect_value(t, m.overview.pan, f64(0))
	testing.expect(t, e.overview_edge(&m, point, 0.1) == "")
	testing.expect_value(t, m.overview.pan, f64(0))
	testing.expect(t, e.overview_edge(&m, point, 0.15) == "")
	testing.expect(t, m.overview.pan > 0)
}

@(test)
unplug_migrates_spaces_and_replug_restores_them :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	testing.expect(t, e.workspace_unplug(&m, 10) != "")
	testing.expect_value(t, len(m.displays), 1)
	m.displays[0].uuid = strings.clone("display-a")
	m.main_display = 10
	append(
		&m.displays,
		e.Display {
			id = 20,
			index = 2,
			uuid = strings.clone("display-b"),
			frame = {1000, 0, 800, 600},
			usable = {1000, 0, 800, 600},
			active_space = 200,
		},
	)
	scroll_neighbor(&m, 200, 20)
	open_on(&m, 3, 200, 20)
	e.focus_window(&m, 3)
	testing.expect(t, !e.execute(&m, []string{"config", "workspace_hotplug", "on"}).failed)
	testing.expect_value(t, e.execute(&m, []string{"config", "workspace_hotplug"}).text, "on")
	testing.expect(t, e.workspace_unplug(&m, 20) == "")
	moved := e.space_by_id(&m, 200)
	testing.expect(t, moved != nil)
	testing.expect_value(t, moved.display, u32(10))
	testing.expect_value(t, moved.view.frame, e.Rect{0, 0, 1000, 800})
	testing.expect_value(t, m.windows[3].display, u32(10))
	testing.expect_value(t, m.focused, u32(3))
	testing.expect_value(t, m.active_space, u64(100))
	testing.expect(
		t,
		e.workspace_replug(
			&m,
			e.Display {
				id = 20,
				index = 2,
				uuid = strings.clone("display-b"),
				frame = {1000, 0, 800, 600},
				usable = {1000, 0, 800, 600},
			},
		) ==
		"",
	)
	moved = e.space_by_id(&m, 200)
	testing.expect_value(t, moved.display, u32(20))
	testing.expect_value(t, moved.view.frame.x, f64(1000))
	testing.expect_value(t, m.focused, u32(3))
	testing.expect_value(t, m.active_space, u64(100))
}

@(test)
span_modes_keep_distinct_frames_and_restore_width :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	d := &m.displays[0]
	d.frame = {0, 0, 1280, 900}
	d.usable = {0, 40, 1280, 820}
	s := m.spaces[0]
	s.view.frame = d.usable
	testing.expect(t, !e.execute(&m, []string{"window", "--column-width", "abs:400"}).failed)
	node := layout.find(s.view.root, 1)
	testing.expect_value(t, node.column_width, f64(400))
	testing.expect(t, !e.execute(&m, []string{"window", "--toggle", "column-full-width"}).failed)
	testing.expect_value(t, m.windows[1].frame, e.Rect{16, 56, 1248, 788})
	testing.expect(t, node.column_full && !node.column_maximize && !node.column_cover)
	testing.expect(t, !e.execute(&m, []string{"window", "--toggle", "maximize"}).failed)
	testing.expect_value(t, m.windows[1].frame, d.usable)
	testing.expect(t, node.column_maximize && !node.column_full && !node.column_cover)
	testing.expect(t, !e.execute(&m, []string{"window", "--toggle", "maximize"}).failed)
	testing.expect_value(t, node.column_width, f64(400))
	testing.expect_value(t, m.windows[1].frame.w, f64(400))
	testing.expect(t, !e.execute(&m, []string{"window", "--toggle", "layout-fullscreen"}).failed)
	testing.expect_value(t, m.windows[1].frame, d.frame)
	testing.expect(t, node.column_cover && !node.column_maximize && !node.column_full)
	testing.expect(t, !e.execute(&m, []string{"window", "--toggle", "layout-fullscreen"}).failed)
	testing.expect_value(t, node.column_width, f64(400))
	testing.expect_value(t, m.focused, u32(1))
}

@(test)
layout_fullscreen_keeps_tab_members_and_skips_utility_windows :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2)
	testing.expect(t, !e.execute(&m, []string{"window", "1", "--stack", "2"}).failed)
	testing.expect(t, !e.execute(&m, []string{"window", "1", "--column-display", "tabbed"}).failed)
	testing.expect(t, !e.execute(&m, []string{"window", "2", "--focus"}).failed)
	node := layout.find(m.spaces[0].view.root, 1)
	testing.expect(t, layout.tab_indicator_gutter(&m.spaces[0].view, node) > 0)
	testing.expect(
		t,
		!e.execute(&m, []string{"window", "2", "--toggle", "layout-fullscreen"}).failed,
	)
	testing.expect_value(t, node.count, 2)
	testing.expect_value(t, node.windows[0], u32(1))
	testing.expect_value(t, node.windows[1], u32(2))
	testing.expect_value(t, m.focused, u32(2))
	testing.expect_value(t, layout.tab_indicator_gutter(&m.spaces[0].view, node), f64(0))
	e.add_window(
		&m,
		e.Window {
			id = 9,
			role = "AXWindow",
			subrole = "AXStandardWindow",
			application_accessory = true,
			space = 100,
			display = 10,
			frame = {4, 4, 40, 20},
		},
	)
	before := m.windows[9].frame
	testing.expect(
		t,
		e.execute(&m, []string{"window", "9", "--toggle", "layout-fullscreen"}).failed,
	)
	testing.expect_value(t, m.windows[9].frame, before)
	testing.expect(t, layout.find(m.spaces[0].view.root, 9) == nil)
	testing.expect_value(t, node.count, 2)
}
