package tests

import e "../src/engine"
import mac "../src/macos"
import "core:testing"

feedback_create :: proc(
	state: ^mac.State,
	plan: e.Feedback_Plan,
) -> (
	mac.Owned_Surface,
	string,
) {
	r := (^Animation_Recorder)(state.event_user);r.created += 1
	return {id = 100 + plan.window, frame = plan.frame}, ""
}

feedback_destroy :: proc(state: ^mac.State, surface: mac.Owned_Surface) {
	r := (^Animation_Recorder)(state.event_user);r.destroyed += 1
}

@(test)
insertion_and_drag_previews_match_split_geometry :: proc(t: ^testing.T) {
	m: e.Manager;r: Recorder;fixture(&m, &r)
	defer e.manager_destroy(&m);defer delete(r.actions)
	s := e.space_by_id(&m, 100)
	testing.expect_value(t, e.flush(&m, s), "")
	testing.expect(t, !e.window_command(&m, []string{"1", "--insert", "east"}).failed)
	plan, valid := e.insertion_feedback(&m, s)
	testing.expect(t, valid)
	n := e.find(s.view.root, 1)
	_, right := e.partition(e.frame_for(n), .Vertical, s.view.ratio, 0)
	testing.expect_value(t, plan.frame, right)
	testing.expect(t, !e.config(&m, []string{"insert_feedback_color", "0x80334455"}).failed)
	plan, valid = e.insertion_feedback(&m, s)
	testing.expect_value(t, plan.color, u32(0x80334455))
	drag := e.mouse_begin(&m, 1, .Move, {0, 0})
	w := m.windows[2]
	plan, valid = e.drag_feedback(
		&m,
		drag,
		2,
		{w.frame.x + w.frame.w / 2, w.frame.y + w.frame.h / 2},
	)
	testing.expect(t, valid)
	testing.expect_value(t, plan.frame, w.frame)
	m.suspended = true
	_, valid = e.drag_feedback(&m, drag, 2, {w.frame.x, w.frame.y})
	testing.expect(t, !valid)
	_, valid = e.insertion_feedback(&m, s)
	testing.expect(t, !valid)
	testing.expect(t, e.config(&m, []string{"insert_feedback_color", "0xGG000000"}).failed)
}

@(test)
feedback_reuses_unchanged_overlays_and_releases_changed_and_removed_plans :: proc(t: ^testing.T) {
	state: mac.State;r: Animation_Recorder
	state.event_user = &r
	state.feedback_backend = {feedback_create, feedback_destroy}
	defer mac.feedback_stop(&state)
	plans := make(map[u32]e.Feedback_Plan)
	defer delete(plans)
	plans[1] = e.Feedback_Plan{1, {0, 0, 200, 200}, 0xff112233}
	mac.feedback_sync(&state, plans)
	mac.feedback_sync(&state, plans)
	testing.expect_value(t, r.created, 1)
	testing.expect_value(t, r.destroyed, 0)
	plans[1] = e.Feedback_Plan{1, {0, 0, 100, 200}, 0xff112233}
	mac.feedback_sync(&state, plans)
	testing.expect_value(t, r.created, 2)
	testing.expect_value(t, r.destroyed, 1)
	clear(&plans)
	mac.feedback_sync(&state, plans)
	testing.expect_value(t, r.destroyed, 2)
	testing.expect_value(t, len(state.feedback), 0)
}
