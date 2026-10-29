package tests

import mac "../src"
import "core:math"
import "core:testing"

@(test)
resize_blend_uses_animation_clock_despite_size_velocity :: proc(
	t: ^testing.T,
) {
	state: mac.State; r: Recorder; c: Cover_Recorder
	cover_fixture(&state, &r, &c)
	defer mac.manager_destroy(&state.manager); defer delete(r.actions)
	defer mac.resize_cover_stop(&state)
	s := mac.space_by_id(&state.manager, 100)
	s.view.layout = .Scroll; s.view.scroll.geometry_active = true
	w := state.manager.windows[1]
	w.scroll_frame = {
		valid            = true,
		from             = {0, 0, 500, 800},
		target           = {0, 0, 600, 800},
		initial_velocity = {0, 0, 3000, 0},
	}
	mac.scroll_frame_sample(&w.scroll_frame, .04)
	w.frame = w.scroll_frame.current; c.actual = w.frame
	mac.resize_cover_frame(&state, 1, w.frame, w.scroll_frame.from, 1)
	mac.resize_cover_tick(&state, 1.04)
	expected :=
		1 -
		(1 + mac.SCROLL_SPRING_OMEGA * .04) *
			math.exp(-mac.SCROLL_SPRING_OMEGA * .04)
	testing.expect(
		t,
		math.abs(c.alpha - expected) < .001,
		"velocity must not finish the content blend ahead of its animation clock",
	)
}

@(test)
resize_surface_is_presented_once_after_geometry_per_tick :: proc(
	t: ^testing.T,
) {
	state: mac.State; r: Recorder; c: Cover_Recorder
	cover_fixture(&state, &r, &c)
	defer mac.manager_destroy(&state.manager); defer delete(r.actions)
	defer mac.resize_cover_stop(&state)
	mac.resize_cover_frame(
		&state,
		1,
		{0, 0, 700, 800},
		mac.Rect{0, 0, 500, 800},
		1,
	)
	mac.resize_cover_tick(&state, 1)
	before := c.updated
	mac.resize_cover_frame(
		&state,
		1,
		{0, 0, 800, 800},
		mac.Rect{0, 0, 700, 800},
		1.02,
	)
	state.manager.windows[1].frame = {0, 0, 800, 800}
	c.actual = state.manager.windows[1].frame
	mac.resize_cover_tick(&state, 1.02)
	testing.expect_value(t, c.updated - before, 1)
}

Cover_Recorder :: struct {
	created, updated, destroyed: int,
	actual, last: mac.Rect,
	alpha: f64,
	fail_create, fail_update, invalid: bool,
	revealing: bool,
}
cover_create :: proc(
	state: ^mac.State,
	_: u32,
	frame: mac.Rect,
) -> (
	mac.Owned_Surface,
	string,
) {
	r := (^Cover_Recorder)(state.event_user); r.created += 1
	if r.fail_create {
		return {}, "injected capture failure"
	}
	return {id = 900, frame = frame}, ""
}
cover_update :: proc(
	state: ^mac.State,
	_: mac.Owned_Surface,
	_: u32,
	frame: mac.Rect,
	alpha: f64,
	revealing: bool,
) -> string {
	r := (^Cover_Recorder)(state.event_user); r.updated += 1
	r.last, r.alpha = frame, alpha
	r.revealing = revealing
	return r.fail_update ? "injected cover failure" : ""
}

@(test)
resize_content_blends_during_geometry_and_finishes_with_it :: proc(
	t: ^testing.T,
) {
	state: mac.State; r: Recorder; c: Cover_Recorder
	cover_fixture(&state, &r, &c)
	defer mac.manager_destroy(&state.manager); defer delete(r.actions)
	defer delete(state.animations); defer mac.resize_cover_stop(&state)
	from := mac.Rect{0, 0, 500, 800}
	target := mac.Rect{0, 0, 900, 800}
	current := mac.Rect{0, 0, 700, 800}
	state.animations = make(map[u32]mac.Animation_Job)
	state.animations[1] = {
		generation   = state.manager.windows[1].generation,
		pid          = state.manager.windows[1].pid,
		from         = from,
		target       = target,
		presentation = mac.Live_Resize{current},
		progress     = .5,
	}
	mac.resize_cover_frame(&state, 1, current, from, 1)
	state.manager.windows[1].frame = target
	c.actual = current
	mac.resize_cover_tick(&state, 1.1)
	testing.expect(
		t,
		c.revealing,
		"contents must blend while geometry is moving",
	)
	testing.expect(
		t,
		math.abs(c.alpha - .5) < .001,
		"content blend must follow geometry progress",
	)
	delete_key(&state.animations, u32(1))
	c.actual = target
	mac.resize_cover_tick(&state, 1.2)
	testing.expect_value(t, len(state.resize_covers), 0)
}
cover_destroy :: proc(state: ^mac.State, _: mac.Owned_Surface) {
	(^Cover_Recorder)(state.event_user).destroyed += 1
}

@(test)
scroll_content_blend_tracks_size_and_has_no_completion_tail :: proc(
	t: ^testing.T,
) {
	state: mac.State; r: Recorder; c: Cover_Recorder
	cover_fixture(&state, &r, &c)
	defer mac.manager_destroy(&state.manager); defer delete(r.actions)
	defer mac.resize_cover_stop(&state)
	s := mac.space_by_id(&state.manager, 100)
	s.view.layout = .Scroll; s.view.scroll.geometry_active = true
	w := state.manager.windows[1]
	w.scroll_frame = {
		valid    = true,
		from     = {0, 0, 900, 800},
		target   = {0, 0, 500, 800},
		current  = {0, 0, 800, 800},
		progress = .25,
	}
	w.frame = w.scroll_frame.current; c.actual = w.frame
	mac.resize_cover_frame(&state, 1, w.frame, w.scroll_frame.from, 1)
	mac.resize_cover_tick(&state, 1.02)
	testing.expect(t, c.revealing)
	testing.expect(t, math.abs(c.alpha - .25) < .001)
	w.scroll_frame.current.w = 600; w.scroll_frame.progress = .75
	w.frame = w.scroll_frame.current; c.actual = w.frame
	mac.resize_cover_tick(&state, 1.1)
	testing.expect(t, math.abs(c.alpha - .75) < .001)
	s.view.scroll.geometry_active = false
	w.frame = w.scroll_frame.target; c.actual = w.frame
	mac.resize_cover_tick(&state, 1.2)
	testing.expect_value(t, len(state.resize_covers), 0)
}

@(test)
content_blend_retarget_preserves_opacity_with_new_clock :: proc(
	t: ^testing.T,
) {
	cover := mac.Resize_Cover {
		alpha = 1,
	}
	mac.resize_cover_blend_geometry(
		&cover,
		{0, 0, 500, 800},
		{0, 0, 900, 800},
		.5,
	)
	testing.expect_value(t, cover.alpha, f64(.5))
	testing.expect_value(t, cover.generation, u64(0))
	mac.resize_cover_blend_geometry(
		&cover,
		{0, 0, 700, 800},
		{0, 0, 400, 800},
		0,
	)
	testing.expect_value(t, cover.alpha, f64(.5))
	testing.expect_value(t, cover.generation, u64(1))
	mac.resize_cover_blend_geometry(
		&cover,
		{0, 0, 700, 800},
		{0, 0, 400, 800},
		.5,
	)
	testing.expect_value(t, cover.alpha, f64(.75))
	testing.expect_value(t, cover.generation, u64(1))
	mac.resize_cover_blend_geometry(
		&cover,
		{0, 0, 700, 800},
		{0, 0, 400, 800},
		1.1,
	)
	testing.expect_value(t, cover.alpha, f64(1))
	mac.resize_cover_blend_geometry(
		&cover,
		{0, 0, 700, 800},
		{0, 0, 400, 800},
		.1,
		1,
	)
	testing.expect_value(t, cover.generation, u64(2))
	testing.expect_value(t, cover.alpha, f64(1))
}

cover_bounds :: proc(state: ^mac.State, _: u32) -> (mac.Rect, bool) {
	r := (^Cover_Recorder)(state.event_user); return r.actual, !r.invalid
}
cover_fixture :: proc(
	state: ^mac.State,
	r: ^Recorder,
	cover: ^Cover_Recorder,
) {
	fixture(&state.manager, r)
	state.manager.resize_fade = true; state.event_user = cover
	state.resize_cover_backend = {
		cover_create,
		cover_update,
		cover_destroy,
		cover_bounds,
	}
}

@(test)
resize_cover_skips_and_removes_snapshots_during_interactive_resize :: proc(t: ^testing.T) {
	state: mac.State; r: Recorder; c: Cover_Recorder
	cover_fixture(&state, &r, &c)
	defer mac.manager_destroy(&state.manager); defer delete(r.actions)
	defer mac.resize_cover_stop(&state)
	before := mac.Rect{0, 0, 500, 800}
	after := mac.Rect{0, 0, 700, 800}
	mac.resize_cover_frame(&state, 1, after, before, 1)
	testing.expect_value(t, c.created, 1)
	state.manager.windows[1].grabbed = true
	mac.resize_cover_frame(&state, 1, after, before, 1.1)
	testing.expect_value(t, c.destroyed, 1)
	testing.expect(t, !state.manager.windows[1].resize_transitioning)
	mac.resize_cover_frame(&state, 1, after, before, 1.2)
	testing.expect_value(t, c.created, 1)
	state.manager.windows[1].grabbed = false
	state.manager.native_resize_window = 1
	mac.resize_cover_frame(&state, 1, after, before, 1.3)
	testing.expect_value(t, c.created, 1)
	state.manager.native_resize_window = 0
	state.mouse.drag = {window = 1, action = .Resize}
	mac.resize_cover_frame(&state, 1, after, before, 1.35)
	testing.expect_value(t, c.created, 1)
	state.mouse.drag = {}
	mac.resize_cover_frame(&state, 1, after, before, 1.4)
	testing.expect_value(t, c.created, 2)
}

@(test)
resize_cover_retargets_one_capture_and_fades_to_live_contents :: proc(
	t: ^testing.T,
) {
	state: mac.State; r: Recorder; c: Cover_Recorder
	cover_fixture(&state, &r, &c)
	defer mac.manager_destroy(&state.manager); defer delete(r.actions)
	defer mac.resize_cover_stop(&state)
	mac.resize_cover_frame(
		&state,
		1,
		{0, 0, 700, 800},
		mac.Rect{0, 0, 500, 800},
		1,
	)
	mac.resize_cover_frame(
		&state,
		1,
		{0, 0, 900, 800},
		mac.Rect{0, 0, 700, 800},
		1.1,
	)
	testing.expect_value(t, c.created, 1)
	testing.expect(t, state.manager.windows[1].resize_transitioning)
	state.manager.windows[1].frame = {0, 0, 900, 800}
	c.actual = {0, 0, 900, 800}
	mac.resize_cover_tick(&state, 1.2)
	mac.resize_cover_tick(&state, 1.3)
	mac.resize_cover_tick(&state, 1.35)
	testing.expect(t, math.abs(c.alpha - .5) < .001)
	mac.resize_cover_tick(&state, 1.8)
	testing.expect_value(t, len(state.resize_covers), 0)
	testing.expect_value(t, c.destroyed, 1)
	testing.expect(t, !state.manager.windows[1].resize_transitioning)
}

@(test)
resize_cover_deadline_and_retarget_are_bounded :: proc(t: ^testing.T) {
	cover := mac.Resize_Cover {
		began = 1,
		alpha = 1,
	}
	testing.expect(t, !mac.resize_cover_step(&cover, 1.1, false, false))
	testing.expect(t, !mac.resize_cover_step(&cover, 1.2, false, true))
	mac.resize_cover_step(&cover, 1.3, false, true)
	mac.resize_cover_step(&cover, 1.35, false, true)
	testing.expect(t, cover.alpha < 1)
	mac.resize_cover_step(&cover, 1.55, true, false)
	testing.expect(t, cover.alpha <= 1)
	testing.expect_value(t, cover.fade_began, f64(0))
	testing.expect(t, mac.resize_cover_step(&cover, 4.01, true, false))
}

@(test)
resize_cover_removes_on_disable_input_invalid_owner_or_surface_failure :: proc(
	t: ^testing.T,
) {
	for mode in 0 ..< 5 {
		state: mac.State; r: Recorder; c: Cover_Recorder
		cover_fixture(&state, &r, &c)
		defer mac.manager_destroy(&state.manager); defer delete(r.actions)
		defer mac.resize_cover_stop(&state)
		mac.resize_cover_frame(
			&state,
			1,
			{0, 0, 700, 800},
			mac.Rect{0, 0, 500, 800},
			1,
		)
		state.manager.windows[1].frame = {0, 0, 700, 800}
		c.actual = {0, 0, 700, 800}
		switch mode {
		case 0:
			state.manager.resize_fade = false
		case 1:
			state.resize_cover_cancel = true
		case 2:
			state.manager.windows[1].pid += 1
		case 3:
			c.fail_update = true
		case 4:
			c.invalid = true
		}
		mac.resize_cover_tick(&state, 1.1)
		testing.expect_value(t, len(state.resize_covers), 0)
		testing.expect_value(t, c.destroyed, 1)
	}
}

@(test)
resize_cover_capture_failure_and_tiny_resizes_leave_app_usable :: proc(
	t: ^testing.T,
) {
	state: mac.State; r: Recorder; c: Cover_Recorder
	cover_fixture(&state, &r, &c)
	defer mac.manager_destroy(&state.manager); defer delete(r.actions)
	defer mac.resize_cover_stop(&state)
	mac.resize_cover_frame(
		&state,
		1,
		{0, 0, 505, 800},
		mac.Rect{0, 0, 500, 800},
		1,
	)
	testing.expect_value(t, c.created, 0)
	c.fail_create = true
	mac.resize_cover_frame(
		&state,
		1,
		{0, 0, 700, 800},
		mac.Rect{0, 0, 500, 800},
		1,
	)
	mac.resize_cover_frame(
		&state,
		1,
		{0, 0, 800, 800},
		mac.Rect{0, 0, 500, 800},
		1.1,
	)
	testing.expect_value(t, c.created, 1)
	testing.expect_value(t, len(state.resize_covers), 0)
	testing.expect(t, mac.managed(state.manager.windows[1]))
}

@(test)
resize_cover_stop_releases_every_surface_and_window_status :: proc(
	t: ^testing.T,
) {
	state: mac.State; r: Recorder; c: Cover_Recorder
	cover_fixture(&state, &r, &c)
	defer mac.manager_destroy(&state.manager); defer delete(r.actions)
	defer mac.resize_cover_stop(&state)
	for id in ([2]u32 {
			1,
			2,
		}) { mac.resize_cover_frame(&state, id, {0, 0, 700, 800}, mac.Rect{0, 0, 500, 800}, 1) }
	testing.expect_value(t, len(state.resize_covers), 2)
	mac.resize_cover_stop(&state)
	testing.expect_value(t, c.destroyed, 2)
	for id in ([2]u32 {
			1,
			2,
		}) { testing.expect(t, !state.manager.windows[id].resize_transitioning) }
}

@(test)
content_fade_overlaps_for_short_resizes_and_holds_background_for_long_drags :: proc(
	t: ^testing.T,
) {
	cover := mac.Resize_Cover {
		began     = 1,
		out_began = 1,
		out_from  = 1,
		alpha     = 1,
	}
	mac.resize_cover_step(&cover, 1.3, true, false)
	testing.expect_value(t, cover.alpha, f64(1))
	mac.resize_cover_step(&cover, 1.95, true, false)
	testing.expect(t, math.abs(cover.alpha - .5) < .001)
	mac.resize_cover_step(&cover, 2.26, true, false)
	testing.expect_value(t, cover.alpha, f64(0))
	mac.resize_cover_step(&cover, 2.3, false, true)
	mac.resize_cover_step(&cover, 2.4, false, true)
	testing.expect(t, cover.revealing)
	mac.resize_cover_step(&cover, 2.45, false, true)
	testing.expect(t, math.abs(cover.alpha - .5) < .001)
	mac.resize_cover_step(&cover, 2.46, true, false)
	testing.expect(t, !cover.revealing)
	testing.expect_value(t, cover.alpha, f64(1))
	testing.expect(t, mac.resize_cover_step(&cover, 4.01, true, false))
	m: mac.Manager
	testing.expect(
		t,
		!mac.execute(&m, {"config", "window_resize_animation", "fade"}).failed,
	)
	testing.expect_value(
		t,
		mac.execute(&m, {"config", "window_resize_animation"}).text,
		"fade",
	)
	testing.expect(
		t,
		!mac.execute(&m, {"config", "window_resize_animation", "off"}).failed,
	)
	testing.expect(t, !m.resize_fade)
	testing.expect(
		t,
		mac.execute(&m, {"config", "window_resize_animation", "blur"}).failed,
	)
}

@(test)
capture_budget_rejects_large_and_overflowing_images_and_releases_reservations :: proc(
	t: ^testing.T,
) {
	memory := mac.Capture_Memory {
		limit = 1024,
	}
	testing.expect(t, mac.capture_reserve(&memory, 700))
	testing.expect(t, !mac.capture_reserve(&memory, 325))
	testing.expect(t, !mac.capture_reserve(&memory, max(u64)))
	testing.expect_value(t, memory.used, u64(700))
	mac.capture_release(&memory, 700)
	testing.expect(t, mac.capture_reserve(&memory, 1024))
	mac.capture_release(&memory, 1024)
	testing.expect_value(t, memory.used, u64(0))
	_, ok := mac.capture_surface_bytes({0, 0, math.inf_f64(1), 10}, 2)
	testing.expect(t, !ok)
	_, ok = mac.capture_surface_bytes({0, 0, 1e15, 1e15}, 2)
	testing.expect(t, !ok)
	bytes, valid := mac.capture_surface_bytes({0, 0, 640, 480}, 2)
	testing.expect(t, valid)
	testing.expect_value(t, bytes, u64(640 * 480 * 16))
	state: mac.State
	state.capture_memory.used = 4096
	state.resize_snapshots = make(map[u32]mac.Resize_Snapshots)
	defer delete(state.resize_snapshots)
	state.resize_snapshots[0] = {
		surface_bytes = 4096,
	}
	mac.native_resize_cover_destroy(&state, {})
	testing.expect_value(t, state.capture_memory.used, u64(0))
	testing.expect_value(t, len(state.resize_snapshots), 0)
}

@(test)
real_capture_images_are_accounted_and_released_with_their_surface :: proc(
	t: ^testing.T,
) {
	color := mac.CGColorSpaceCreateDeviceRGB()
	if !testing.expect(t, color != nil) {
		return
	}
	defer mac.CGColorSpaceRelease(color)
	ctx := mac.CGBitmapContextCreate(nil, 64, 64, 8, 256, color, 1)
	if !testing.expect(t, ctx != nil) {
		return
	}
	defer mac.CGContextRelease(ctx)
	image := mac.CGBitmapContextCreateImage(ctx)
	if !testing.expect(t, image != nil) {
		return
	}
	bytes, valid := mac.capture_image_bytes(image)
	if !testing.expect(t, valid) {
		mac.CGImageRelease(image); return
	}
	testing.expect_value(t, bytes, u64(64 * 256))
	state: mac.State
	total := bytes * 2 + 64 * 64 * 4
	testing.expect(t, mac.capture_reserve(&state.capture_memory, total))
	state.resize_snapshots = make(map[u32]mac.Resize_Snapshots)
	defer delete(state.resize_snapshots)
	state.resize_snapshots[0] = {
		initial       = image,
		final         = mac.CGImageRetain(image),
		initial_bytes = bytes,
		final_bytes   = bytes,
		surface_bytes = 64 * 64 * 4,
	}
	mac.native_resize_cover_destroy(&state, {})
	testing.expect_value(t, state.capture_memory.used, u64(0))
	state.capture_memory.limit = 1
	rejected, held, err := mac.capture_snapshot(
		&state,
		999,
		{0, 0, 640, 480},
		2,
	)
	testing.expect(t, rejected == nil && held == 0 && err != "")
	testing.expect_value(t, state.capture_memory.used, u64(0))
}
