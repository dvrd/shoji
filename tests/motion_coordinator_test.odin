package tests

import e "../src/engine"
import mac "../src/macos"
import "core:testing"

@(test)
motion_coordinator_coalesces_and_invalidates_stale_work :: proc(t: ^testing.T) {
	q: mac.Motion_Coordinator; defer mac.motion_coordinator_destroy(&q)
	first := mac.motion_register(&q, 10, 1)
	mac.motion_queue_position(&q, first, e.Rect{1, 0, 100, 100})
	mac.motion_queue_position(&q, first, e.Rect{2, 0, 100, 100})
	job, ok := mac.motion_take(&q)
	testing.expect(t, ok)
	testing.expect_value(t, job.frame.x, f64(2))
	mac.motion_queue_position(&q, first, e.Rect{3, 0, 100, 100})
	testing.expect(t, !mac.motion_complete(&q, job, true))
	next, found := mac.motion_take(&q)
	testing.expect(t, found)
	testing.expect_value(t, next.frame.x, f64(3))
	testing.expect(t, mac.motion_complete(&q, next, true))
	mac.motion_unregister(&q, first)
	replacement := mac.motion_register(&q, 10, 1)
	testing.expect(t, replacement.generation != first.generation)
	testing.expect(t, !mac.motion_queue_position(&q, first, e.Rect{}))
}

@(test)
motion_coordinator_focus_and_space_changes_supersede_work :: proc(t: ^testing.T) {
	q: mac.Motion_Coordinator; defer mac.motion_coordinator_destroy(&q)
	a := mac.motion_register(&q, 10, 1); b := mac.motion_register(&q, 20, 1)
	mac.motion_queue_focus(&q, a)
	old, ok := mac.motion_take(&q); testing.expect(t, ok)
	mac.motion_queue_focus(&q, b)
	testing.expect(t, !mac.motion_complete(&q, old, true))
	current, found := mac.motion_take(&q); testing.expect(t, found)
	testing.expect_value(t, current.target.window, u32(20))
	mac.motion_unregister(&q, b)
	testing.expect(t, !mac.motion_complete(&q, current, true))
	mac.motion_queue_position(&q, a, e.Rect{1,0,10,10})
	mac.motion_invalidate_space(&q, 1)
	_, pending := mac.motion_take(&q)
	testing.expect(t, !pending)
}

@(test)
motion_coordinator_services_oldest_pending_window_and_ignores_obsolete_failure :: proc(t: ^testing.T) {
	q: mac.Motion_Coordinator; defer mac.motion_coordinator_destroy(&q)
	a := mac.motion_register(&q, 10, 1); b := mac.motion_register(&q, 20, 1)
	mac.motion_queue_position(&q, a, e.Rect{1,0,10,10})
	mac.motion_queue_position(&q, b, e.Rect{2,0,10,10})
	mac.motion_queue_position(&q, a, e.Rect{3,0,10,10})
	job, ok := mac.motion_take(&q); testing.expect(t, ok)
	testing.expect_value(t, job.target.window, u32(20))
	mac.motion_unregister(&q, b)
	testing.expect(t, !mac.motion_request_current(&q, job))
	testing.expect(t, !mac.motion_complete(&q, job, false))
	job, ok = mac.motion_take(&q); testing.expect(t, ok)
	testing.expect_value(t, job.target.window, u32(10))
	testing.expect(t, mac.motion_complete(&q, job, true))
}

@(test)
motion_coordinator_replacing_a_window_discards_its_pending_focus :: proc(t: ^testing.T) {
	q: mac.Motion_Coordinator; defer mac.motion_coordinator_destroy(&q)
	old := mac.motion_register(&q, 10, 1)
	mac.motion_queue_focus(&q, old)
	new := mac.motion_register(&q, 10, 2)
	_, found := mac.motion_take(&q)
	testing.expect(t, !found)
	testing.expect(t, mac.motion_queue_focus(&q, new))
	job, ok := mac.motion_take(&q); testing.expect(t, ok)
	testing.expect_value(t, job.target, new)
}

@(test)
motion_coordinator_shutdown_discards_pending_and_rejects_inflight_results :: proc(t: ^testing.T) {
	q: mac.Motion_Coordinator; defer mac.motion_coordinator_destroy(&q)
	a := mac.motion_register(&q, 10, 1); b := mac.motion_register(&q, 20, 1)
	mac.motion_queue_position(&q, a, e.Rect{1,0,10,10})
	job, ok := mac.motion_take(&q); testing.expect(t, ok)
	mac.motion_queue_focus(&q, b)
	mac.motion_queue_position(&q, b, e.Rect{2,0,10,10})
	mac.motion_coordinator_stop(&q)
	testing.expect(t, !mac.motion_coordinator_idle(&q))
	testing.expect(t, !mac.motion_queue_position(&q, a, e.Rect{}))
	testing.expect(t, !mac.motion_queue_focus(&q, b))
	testing.expect(t, !mac.motion_complete(&q, job, true))
	testing.expect(t, mac.motion_coordinator_idle(&q))
	_, pending := mac.motion_take(&q); testing.expect(t, !pending)
}
