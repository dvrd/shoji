package tests

import e "../src"
import "core:testing"

@(test)
late_size_acceptance_does_not_animate_back_to_the_rejected_size :: proc(t: ^testing.T) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2)
	e.execute(&m, {"config", "scroll_animation", "on"})
	e.execute(&m, {"window", "1", "--column-width", "abs:500"})
	w := m.windows[1]
	e.size_feedback_request(w, {0, 0, 500, 768}, {0, 0, 900, 768}, 0)
	e.size_feedback_observe(w, w.size_feedback.generation, {0, 0, 700, 768}, 0.2)
	e.size_feedback_observe(w, w.size_feedback.generation, {0, 0, 700, 768}, 0.28)
	e.flush(&m, m.spaces[0])
	m.animation_duration = 0.5
	neighbor_x := m.windows[2].frame.x
	w.frame.w = 500
	testing.expect(t, e.size_feedback_late_result(w, w.frame))
	e.flush(&m, m.spaces[0])
	testing.expect_value(t, w.frame.w, f64(500))
	testing.expect_value(t, m.windows[2].frame.x, neighbor_x)
	testing.expect(t, !m.spaces[0].view.scroll.geometry_active)
}

feedback_window :: proc() -> e.Window {
	return {
		id = 1,
		pid = 42,
		size_intent = {
			w = 500,
			h = 400,
			viewport = {0, 0, 1280, 800},
			space = 100,
			display = 10,
			pid = 42,
		},
	}
}

@(test)
accepted_size_requires_quiet_request_and_two_stable_observations :: proc(
	t: ^testing.T,
) {
	w := feedback_window()
	e.size_feedback_request(&w, {0, 0, 500, 400}, {0, 0, 900, 800}, 0)
	generation := w.size_feedback.generation
	testing.expect(
		t,
		!e.size_feedback_observe(&w, generation, {0, 0, 900, 800}, 0.05),
	)
	testing.expect(
		t,
		!e.size_feedback_observe(&w, generation, {0, 0, 700, 450}, 0.16),
	)
	testing.expect(t, !w.size_feedback.width_valid)
	testing.expect(
		t,
		e.size_feedback_observe(&w, generation, {0, 0, 700, 450}, 0.24),
	)
	testing.expect(
		t,
		w.size_feedback.width_valid && w.size_feedback.height_valid,
	)
	testing.expect_value(t, w.size_feedback.accepted.w, f64(700))
	testing.expect_value(t, w.min_width, f64(0))
	testing.expect_value(t, w.size_intent.w, f64(500))
}

@(test)
new_size_intent_rejects_old_generation_and_explicit_same_size_retry_clears_adjustment :: proc(
	t: ^testing.T,
) {
	w := feedback_window()
	e.size_feedback_request(&w, {0, 0, 500, 400}, {0, 0, 900, 800}, 0)
	old := w.size_feedback.generation
	w.size_intent.w = 600
	e.size_feedback_request(&w, {0, 0, 600, 400}, {0, 0, 900, 800}, 0.1)
	testing.expect(t, !e.size_feedback_observe(&w, old, {0, 0, 700, 450}, 0.4))
	testing.expect(t, !w.size_feedback.width_valid)
	e.size_feedback_observe(
		&w,
		w.size_feedback.generation,
		{0, 0, 700, 450},
		0.4,
	)
	e.size_feedback_observe(
		&w,
		w.size_feedback.generation,
		{0, 0, 700, 450},
		0.48,
	)
	testing.expect(t, w.size_feedback.width_valid)
	w.size_intent.width_revision += 1
	e.size_feedback_invalidate(&w)
	testing.expect(t, !w.size_feedback.width_valid)
	w.size_feedback.width_valid = true
	w.size_intent.h = 600
	e.size_feedback_invalidate(&w)
	testing.expect(t, !w.size_feedback.width_valid)
}

@(test)
duplicate_size_request_retains_settling_time_and_invalid_bounds_are_ignored :: proc(
	t: ^testing.T,
) {
	w := feedback_window()
	e.size_feedback_request(&w, {0, 0, 500, 400}, {0, 0, 900, 800}, 0)
	e.size_feedback_request(&w, {10, 0, 500, 400}, {10, 0, 900, 800}, 0.1)
	testing.expect_value(t, w.size_feedback.requested_at, f64(0))
	testing.expect(t, e.size_feedback_duplicate(&w, {100, 200, 500, 400}))
	testing.expect(
		t,
		!e.size_feedback_observe(&w, w.size_feedback.generation, {}, 0.2),
	)
	testing.expect(t, !w.size_feedback.width_valid)
	e.size_feedback_observe(
		&w,
		w.size_feedback.generation,
		{0, 0, 500, 400},
		0.3,
	)
	testing.expect(
		t,
		!e.size_feedback_observe(
			&w,
			w.size_feedback.generation,
			{0, 0, 500, 400},
			0.38,
		),
	)
	testing.expect(t, !w.size_feedback.pending && !w.size_feedback.width_valid)
}

@(test)
size_adjustment_is_invalidated_by_output_or_owner_change_and_superseded_by_late_acceptance :: proc(
	t: ^testing.T,
) {
	w := feedback_window()
	e.size_feedback_request(&w, {0, 0, 500, 400}, {0, 0, 900, 800}, 0)
	e.size_feedback_observe(
		&w,
		w.size_feedback.generation,
		{0, 0, 700, 450},
		0.2,
	)
	e.size_feedback_observe(
		&w,
		w.size_feedback.generation,
		{0, 0, 700, 450},
		0.28,
	)
	testing.expect(t, e.size_feedback_late_result(&w, {0, 0, 500, 400}))
	testing.expect(t, !w.size_feedback.width_valid)
	w.size_feedback.width_valid = true
	w.size_intent.viewport.w = 1600
	e.size_feedback_invalidate(&w)
	testing.expect(t, !w.size_feedback.width_valid)
	w.size_feedback.width_valid = true
	w.size_intent.pid = 43
	e.size_feedback_invalidate(&w)
	testing.expect(t, !w.size_feedback.width_valid)
}

@(test)
accepted_width_changes_layout_footprint_without_rewriting_width_preference :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2)
	e.execute(&m, {"window", "1", "--column-width", "abs:500"})
	w := m.windows[1]
	e.size_feedback_request(w, {0, 0, 500, 768}, {0, 0, 900, 768}, 0)
	e.size_feedback_observe(
		w,
		w.size_feedback.generation,
		{0, 0, 700, 768},
		0.2,
	)
	e.size_feedback_observe(
		w,
		w.size_feedback.generation,
		{0, 0, 700, 768},
		0.28,
	)
	e.flush(&m, m.spaces[0])
	testing.expect_value(t, w.frame.w, f64(700))
	testing.expect_value(
		t,
		e.find(m.spaces[0].view.root, 1).column_size.value,
		f64(500),
	)
	testing.expect_value(
		t,
		m.windows[2].frame.x - (w.frame.x + w.frame.w),
		f64(16),
	)
	e.execute(&m, {"window", "1", "--column-width", "abs:500"})
	testing.expect(t, !w.size_feedback.width_valid)
	testing.expect_value(t, w.frame.w, f64(500))
}

@(test)
accepted_row_height_reallocates_other_rows_and_preserves_explicit_height :: proc(
	t: ^testing.T,
) {
	m: e.Manager; r: Recorder; niri_fixture(&m, &r)
	defer e.manager_destroy(&m); defer delete(r.actions)
	niri_open(&m, 2)
	e.execute(&m, {"window", "1", "--stack", "2"})
	e.execute(&m, {"window", "1", "--row-height", "abs:200"})
	w := m.windows[1]
	e.size_feedback_request(w, {0, 0, 616, 200}, {0, 0, 616, 376}, 0)
	e.size_feedback_observe(
		w,
		w.size_feedback.generation,
		{0, 0, 616, 300},
		0.2,
	)
	e.size_feedback_observe(
		w,
		w.size_feedback.generation,
		{0, 0, 616, 300},
		0.28,
	)
	e.flush(&m, m.spaces[0])
	testing.expect_value(t, w.frame.h, f64(300))
	testing.expect_value(t, m.windows[2].frame.h, f64(452))
	testing.expect_value(t, w.row_fixed, f64(200))
	testing.expect_value(
		t,
		m.windows[2].frame.y - w.frame.y - w.frame.h,
		f64(16),
	)
}
