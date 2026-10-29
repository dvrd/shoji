package tests

import e "../src"
import "core:fmt"
import "core:math"
import "core:testing"

@(test)
scroll_resize_coordinates_width_neighbors_and_camera :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2); niri_open(&m, 3)
	e.execute(&m, {"config", "scroll_animation", "on"})
	m.animation_duration = 0.5
	before := m.windows[2].frame.w
	e.execute(&m, {"window", "2", "--column-width", "abs:800"})
	testing.expect_value(t, m.windows[2].frame.w, before)
	e.scroll_motion_tick(&m, 0.1)
	testing.expect(
		t,
		m.windows[2].frame.w > before && m.windows[2].frame.w < 800,
	)
	testing.expect(t, math.abs(m.windows[3].frame.x - 648) < 0.001)
	e.scroll_motion_tick(&m, 0.4)
	testing.expect_value(t, m.windows[2].frame.w, f64(800))
	testing.expect_value(t, m.windows[3].frame.x, f64(648))
}

@(test)
scroll_row_resize_keeps_gap_and_retargets_from_current_geometry :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2)
	e.execute(&m, {"window", "1", "--stack", "2"})
	e.execute(&m, {"config", "scroll_animation", "on"})
	m.animation_duration = 0.5
	e.execute(&m, {"window", "1", "--row-height", "abs:200"})
	e.scroll_motion_tick(&m, 0.08)
	before := m.windows[1].frame
	testing.expect(t, before.h > 200 && before.h < 376)
	testing.expect(
		t,
		math.abs(m.windows[2].frame.y - before.y - before.h - 16) < 0.001,
	)
	e.execute(&m, {"window", "1", "--row-height", "abs:300"})
	testing.expect_value(t, m.windows[1].frame, before)
	e.scroll_motion_tick(&m, 0.5)
	testing.expect_value(t, m.windows[1].frame.h, f64(300))
	testing.expect_value(
		t,
		m.windows[2].frame.y - m.windows[1].frame.y - m.windows[1].frame.h,
		f64(16),
	)
}

@(test)
small_resize_interruption_keeps_neighbor_motion_continuous :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2)
	e.execute(&m, {"window", "1", "--stack", "2"})
	e.execute(&m, {"config", "scroll_animation", "on"})
	m.animation_duration = .5
	e.execute(&m, {"window", "1", "--row-height", "abs:200"})
	e.scroll_motion_tick(&m, .2)
	before := m.windows[1].frame
	neighbor := m.windows[2].frame
	target := math.round(before.h) - 5
	e.execute(
		&m,
		{"window", "1", "--row-height", fmt.tprintf("abs:%.6f", target)},
	)
	testing.expect(t, math.abs(m.windows[1].frame.h - target) < .001)
	testing.expect_value(t, m.windows[2].frame.y, neighbor.y)
	e.scroll_motion_tick(&m, .6)
	testing.expect(t, math.abs(m.windows[1].frame.h - target) < .001)
	testing.expect(
		t,
		math.abs(m.windows[2].frame.y - m.windows[1].frame.y - target - 16) <
		.001,
	)
}

@(test)
small_resize_preserves_fast_motion_and_respects_gap_budget :: proc(
	t: ^testing.T,
) {
	testing.expect(t, e.scroll_small_resize(200, 205, 0, 10))
	testing.expect(t, !e.scroll_small_resize(200, 205, -20, 10))
	testing.expect(t, !e.scroll_small_resize(200, 205, 1000, 10))
	testing.expect(t, !e.scroll_small_resize(200, 205, 0, 4))
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2)
	e.execute(&m, {"window", "1", "--stack", "2"})
	e.execute(&m, {"config", "scroll_animation", "on"})
	m.animation_duration = .5
	e.execute(&m, {"window", "1", "--row-height", "abs:200"})
	e.scroll_motion_tick(&m, .08)
	before := m.windows[1].frame
	e.execute(
		&m,
		{
			"window",
			"1",
			"--row-height",
			fmt.tprintf("abs:%.0f", math.round(before.h) - 5),
		},
	)
	testing.expect_value(t, m.windows[1].frame, before)
	for at in ([4]f64{.09, .12, .2, .5}) {
		e.scroll_motion_tick(&m, at)
		testing.expect(
			t,
			math.abs(
				m.windows[2].frame.y -
				m.windows[1].frame.y -
				m.windows[1].frame.h -
				16,
			) <
			.001,
		)
	}
}
