package shoji

import "core:fmt"
import "core:math"
import "core:time"

foreign import resize_cg "system:CoreGraphics.framework"

// Resize content transitions
// ------------------------------------------------------------------------

RESIZE_COVER_LIMIT :: 8
RESIZE_COVER_DELAY :: .65
RESIZE_COVER_OUT :: .6
RESIZE_COVER_FADE :: .1 // Manual-drag release only; layout resizes share geometry progress.
RESIZE_COVER_MAX :: 3.0
Resize_Cover :: struct {
	window_generation: u64,
	surface: Owned_Surface,
	pid: i32,
	frame: Rect,
	began, stable_since, fade_began, out_began, out_from: f64,
	alpha: f64,
	revealing: bool,
	synchronized: bool,
	geometry_from, geometry_target: Rect,
	geometry_clock: f64,
	generation: u64,
	blend_from: f64,
}
Resize_Geometry :: struct {
	from, target: Rect,
	progress, clock: f64,
	active: bool,
}
resize_cover_geometry :: proc(state: ^State, window: u32) -> Resize_Geometry {
	w := state.manager.windows[window]
	if w == nil || state.manager.native_resize_window == window {
		return {}
	}
	if job, exists := state.animations[window];
	   exists &&
	   animation_is_live(job) &&
	   animation_matches(state, window, job) {
		return {
			from = job.from,
			target = job.target,
			progress = job.progress,
			clock = time.duration_seconds(time.diff(time.Time{}, job.began)),
			active = true,
		}
	}
	if s := space_by_id(&state.manager, w.space);
	   s != nil &&
	   s.view.layout == .Scroll &&
	   s.view.scroll.geometry_active &&
	   w.scroll_frame.valid {
		return {
			from = w.scroll_frame.from,
			target = w.scroll_frame.target,
			progress = w.scroll_frame.progress,
			clock = s.view.scroll.geometry_began,
			active = true,
		}
	}
	return {}
}
resize_cover_blend_geometry :: proc(
	cover: ^Resize_Cover,
	from, target: Rect,
	progress: f64,
	clock: f64 = 0,
) {
	if !cover.synchronized ||
	   cover.geometry_clock != clock ||
	   cover.geometry_from.w != from.w ||
	   cover.geometry_from.h != from.h ||
	   cover.geometry_target.w != target.w ||
	   cover.geometry_target.h != target.h {
		// Preserve the visible opacity on interruption. Recapturing full client
		// contents here blocks the event loop; continue the remaining blend
		// with the new shared geometry clock instead.
		cover.blend_from = cover.synchronized ? cover.alpha : 0
		if cover.synchronized {
			cover.generation += 1
		}
		cover.geometry_from, cover.geometry_target, cover.geometry_clock =
			from, target, clock
	}
	cover.synchronized, cover.revealing = true, true
	cover.alpha =
		cover.blend_from + (1 - cover.blend_from) * clamp(progress, 0, 1)
}
// Bounds retained image data and estimates the owned surface's RGBA backing.
// WindowServer may keep additional internal buffers outside this accounting.
CAPTURE_MEMORY_LIMIT :: u64(128 * 1024 * 1024)
Capture_Memory :: struct {
	used, limit: u64,
}
capture_fits :: proc(memory: ^Capture_Memory, bytes: u64) -> bool {
	limit := memory.limit == 0 ? CAPTURE_MEMORY_LIMIT : memory.limit
	return memory.used <= limit && bytes <= limit - memory.used
}
capture_reserve :: proc(memory: ^Capture_Memory, bytes: u64) -> bool {
	if !capture_fits(memory, bytes) {
		return false
	}
	memory.used += bytes
	return true
}
capture_release :: proc(memory: ^Capture_Memory, bytes: u64) {
	assert(bytes <= memory.used)
	memory.used -= bytes
}
capture_surface_bytes :: proc(frame: Rect, scale: f64) -> (u64, bool) {
	if !valid_frame(frame) ||
	   scale <= 0 ||
	   math.is_nan(scale) ||
	   math.is_inf(scale) {
		return 0, false
	}
	bytes := math.ceil(frame.w * scale) * math.ceil(frame.h * scale) * 4
	if math.is_nan(bytes) ||
	   math.is_inf(bytes) ||
	   bytes >= 18446744073709551616.0 {
		return 0, false
	}
	return u64(bytes), true
}
capture_image_bytes :: proc(image: Ref) -> (u64, bool) {
	if image == nil {
		return 0, false
	}
	row, height :=
		u64(CGImageGetBytesPerRow(image)), u64(CGImageGetHeight(image))
	if row == 0 || height == 0 || height > max(u64) / row {
		return 0, false
	}
	return row * height, true
}
capture_snapshot :: proc(
	state: ^State,
	window: u32,
	frame: Rect,
	scale: f64,
) -> (
	Ref,
	u64,
	string,
) {
	estimate, valid := capture_surface_bytes(frame, scale)
	if !valid || !capture_fits(&state.capture_memory, estimate) {
		return nil, 0, "resize capture memory budget exhausted"
	}
	image := resize_snapshot(state, window)
	if image == nil {
		return nil, 0, "could not capture resize contents"
	}
	bytes, known := capture_image_bytes(image)
	if !known || !capture_reserve(&state.capture_memory, bytes) {
		CGImageRelease(image)
		return nil, 0, "resize capture memory budget exhausted"
	}
	return image, bytes, ""
}

Resize_Snapshots :: struct {
	initial_bytes, final_bytes, surface_bytes: u64,
	initial, final: Ref,
	background: [3]f64,
	background_ready: bool,
	revealing: bool,
	old_alpha: f64,
	live_blend: bool,
}
Resize_Cover_Backend :: struct {
	create: proc(
		state: ^State,
		window: u32,
		frame: Rect,
	) -> (
		Owned_Surface,
		string,
	),
	update: proc(
		state: ^State,
		surface: Owned_Surface,
		window: u32,
		frame: Rect,
		alpha: f64,
		revealing: bool,
	) -> string,
	destroy: proc(state: ^State, surface: Owned_Surface),
	bounds: proc(state: ^State, window: u32) -> (Rect, bool),
}
foreign resize_cg {
	CGImageGetBytesPerRow :: proc "c" (image: Ref) -> uint ---
	CGImageGetHeight :: proc "c" (image: Ref) -> uint ---
	CGImageRelease :: proc "c" (image: Ref) ---
	CGImageRetain :: proc "c" (image: Ref) -> Ref ---
	CGColorSpaceCreateDeviceRGB :: proc "c" () -> Ref ---
	CGColorSpaceRelease :: proc "c" (space: Ref) ---
	CGBitmapContextCreate :: proc "c" (data: rawptr, width, height, bits, row: uint, space: Ref, flags: u32) -> Ref ---
	CGBitmapContextCreateImage :: proc "c" (ctx: Ref) -> Ref ---
	CGContextSetAlpha :: proc "c" (ctx: Ref, alpha: f64) ---
}
resize_snapshot :: proc(state: ^State, window: u32) -> Ref {
	window := window
	images := SLSHWCaptureWindowList(
		state.connection,
		&window,
		1,
		(1 << 11) | (1 << 8),
	)
	if images == nil {
		return nil
	}; defer CFRelease(images)
	if CFArrayGetCount(images) == 0 {
		return nil
	}
	return CGImageRetain(CFArrayGetValueAtIndex(images, 0))
}
// Infer the app's interior background from captured pixels, excluding chrome
// and transparent edges. No application names or system window color are used.
resize_background :: proc(image: Ref) -> [3]f64 {
	color := CGColorSpaceCreateDeviceRGB(); if color == nil {
		return {0, 0, 0}
	}; defer CGColorSpaceRelease(color)
	pixels: [64 * 64 * 4]u8
	ctx := CGBitmapContextCreate(&pixels[0], 64, 64, 8, 64 * 4, color, 1)
	if ctx == nil {
		return {0, 0, 0}
	}; defer CGContextRelease(ctx)
	CGContextDrawImage(ctx, {0, 0, 64, 64}, image)
	counts: [4096]u16; sums: [4096][3]u32; best := 0
	for y in 10 ..< 54 {
		for x in 4 ..< 60 {
			i := (y * 64 + x) * 4
			if pixels[i + 3] < 200 {
				continue
			}
			bucket :=
				int(pixels[i] >> 4) * 256 +
				int(pixels[i + 1] >> 4) * 16 +
				int(pixels[i + 2] >> 4)
			counts[bucket] += 1
			for c in 0 ..< 3 { sums[bucket][c] += u32(pixels[i + c]) }
			if counts[bucket] > counts[best] {
				best = bucket
			}
		}
	}
	if counts[best] == 0 {
		return {0, 0, 0}
	}
	return {
		f64(sums[best][0]) / f64(counts[best]) / 255,
		f64(sums[best][1]) / f64(counts[best]) / 255,
		f64(sums[best][2]) / f64(counts[best]) / 255,
	}
}
// The real window remains live and receives input. An opaque, mouse-transparent
// surface fades captured contents to background, then reveals final contents.
native_resize_cover_create :: proc(
	state: ^State,
	window: u32,
	frame: Rect,
) -> (
	Owned_Surface,
	string,
) {
	w := state.manager.windows[window]
	if w == nil {
		return {}, "resize window disappeared"
	}
	owner, known := animation_recovery_query_owner(state.connection, window)
	pid: i32
	if !known || SLSConnectionGetPID(owner, &pid) != 0 || pid != w.pid {
		return {}, "resize window ownership changed"
	}
	if w.pid != getpid() && !CGPreflightScreenCaptureAccess() {
		return {}, "Screen Recording permission is required for content fades"
	}
	surface_bytes, valid := capture_surface_bytes(frame, 1)
	if !valid || !capture_reserve(&state.capture_memory, surface_bytes) {
		return {}, "resize capture memory budget exhausted"
	}
	image, image_bytes, capture_error := capture_snapshot(
		state,
		window,
		frame,
		2,
	)
	if capture_error != "" {
		capture_release(&state.capture_memory, surface_bytes)
		return {}, capture_error
	}
	success := false
	defer {
		if !success {
			CGImageRelease(image)
			capture_release(&state.capture_memory, surface_bytes + image_bytes)
		}
	}
	surface, err := surface_create(
		state,
		frame,
		window,
		(1 << 1) | (1 << 9),
		13,
		1,
	)
	if err != "" {
		return {}, err
	}
	if state.resize_snapshots == nil {
		state.resize_snapshots = make(map[u32]Resize_Snapshots)
	}
	state.resize_snapshots[surface.id] = {
		initial       = image,
		initial_bytes = image_bytes,
		surface_bytes = surface_bytes,
	}
	success = true
	return surface, ""
}
native_resize_cover_destroy :: proc(state: ^State, surface: Owned_Surface) {
	if images, ok := state.resize_snapshots[surface.id]; ok {
		if images.initial != nil {
			CGImageRelease(images.initial)
		}
		if images.final != nil {
			CGImageRelease(images.final)
		}
		capture_release(
			&state.capture_memory,
			images.initial_bytes + images.final_bytes + images.surface_bytes,
		)
		delete_key(&state.resize_snapshots, surface.id)
	}
	surface_destroy(state, surface)
}
native_resize_cover_update :: proc(
	state: ^State,
	surface: Owned_Surface,
	window: u32,
	frame: Rect,
	alpha: f64,
	revealing: bool,
) -> string {
	images, exists := state.resize_snapshots[surface.id]
	if !exists {
		return "resize snapshot disappeared"
	}
	if cover, exists := state.resize_covers[window];
	   exists && cover.synchronized {
		// The old snapshot is stretched with geometry and blended over the live
		// app, like Niri's old/current texture mix. No final screenshot is frozen,
		// no background is inserted, and no capture is needed on each frame.
		if !images.live_blend {
			r := Rect{0, 0, surface.frame.w, surface.frame.h}
			CGContextClearRect(surface.ctx, r)
			CGContextSetAlpha(surface.ctx, 1)
			CGContextDrawImage(surface.ctx, r, images.initial)
			CGContextFlush(surface.ctx)
			images.live_blend = true
		}
		state.resize_snapshots[surface.id] = images
		return resize_cover_present(state, surface, window, frame, 1 - alpha)
	}
	if !images.background_ready && !revealing && alpha < 1 {
		// Pixel readback is only needed for the prolonged manual-drag fallback.
		// Doing it at capture time stalls every ordinary layout resize.
		images.background = resize_background(images.initial)
		images.background_ready = true
		bg := images.background
		packed :=
			u32(bg[0] * 255) << 16 | u32(bg[1] * 255) << 8 | u32(bg[2] * 255)
		motion_trace_record(
			&state.manager.motion_trace,
			{
				kind = "resize-fade-background",
				window = window,
				value = f64(packed),
			},
		)
	}
	if !revealing && images.revealing {
		// Rebase an interrupted crossfade from its visible composite, preserving
		// pixels even though the new outgoing opacity restarts at one.
		composite, bytes, err := capture_snapshot(
			state,
			surface.id,
			surface.frame,
			1,
		)
		if err != "" {
			return err
		}
		CGImageRelease(images.initial)
		if images.final != nil {
			CGImageRelease(images.final)
		}
		capture_release(
			&state.capture_memory,
			images.initial_bytes + images.final_bytes,
		)
		images.initial, images.final = composite, nil
		images.initial_bytes, images.final_bytes = bytes, 0
	}
	if revealing && images.final == nil {
		started := time.tick_now()
		image, bytes, err := capture_snapshot(state, window, frame, 2)
		if err != "" {
			return err
		}
		images.final, images.final_bytes = image, bytes
		motion_trace_record(
			&state.manager.motion_trace,
			{
				kind = "resize-final-capture",
				window = window,
				duration_ms = f64(time.tick_since(started)) / 1e6,
			},
		)
	}
	images.revealing = revealing
	if !revealing {
		images.old_alpha = alpha
	}
	state.resize_snapshots[surface.id] = images
	r := Rect{0, 0, surface.frame.w, surface.frame.h}
	CGContextClearRect(surface.ctx, r)
	CGContextSetAlpha(surface.ctx, 1)
	CGContextSetRGBFillColor(
		surface.ctx,
		images.background[0],
		images.background[1],
		images.background[2],
		1,
	)
	CGContextFillRect(surface.ctx, r)
	CGContextSetAlpha(surface.ctx, revealing ? images.old_alpha : alpha)
	CGContextDrawImage(surface.ctx, r, images.initial)
	if revealing {
		CGContextSetAlpha(surface.ctx, alpha)
		CGContextDrawImage(surface.ctx, r, images.final)
	}
	CGContextSetAlpha(surface.ctx, 1); CGContextFlush(surface.ctx)
	return resize_cover_present(state, surface, window, frame, 1)
}
resize_cover_present :: proc(
	state: ^State,
	surface: Owned_Surface,
	window: u32,
	frame: Rect,
	opacity: f64,
) -> string {
	if err := surface_update(state, surface, frame); err != "" {
		return err
	}
	base: f32 = 1; SLSGetWindowAlpha(state.connection, window, &base)
	if SLSSetWindowAlpha(state.connection, surface.id, base * f32(opacity)) !=
	   0 {
		return "could not present content fade"
	}
	if SLSOrderWindow(state.connection, surface.id, 1, window) != 0 {
		return "could not order resize cover"
	}
	return ""
}

native_resize_cover_bounds :: proc(
	state: ^State,
	window: u32,
) -> (
	Rect,
	bool,
) {
	frame: Rect
	w := state.manager.windows[window]
	owner, known := animation_recovery_query_owner(state.connection, window)
	pid: i32
	if w == nil ||
	   !known ||
	   SLSConnectionGetPID(owner, &pid) != 0 ||
	   pid != w.pid {
		return frame, false
	}
	code := SLSGetWindowBounds(state.connection, window, &frame)
	return frame,
		code == 0 &&
		frame.w > 0 &&
		frame.h > 0 &&
		!math.is_nan(frame.w) &&
		!math.is_nan(frame.h)
}
resize_cover_backend :: proc(state: ^State) -> Resize_Cover_Backend {
	if state.resize_cover_backend.create != nil {
		return state.resize_cover_backend
	}
	return {
		native_resize_cover_create,
		native_resize_cover_update,
		native_resize_cover_destroy,
		native_resize_cover_bounds,
	}
}
resize_cover_remove :: proc(state: ^State, window: u32) {
	if cover, exists := state.resize_covers[window]; exists {
		if w := state.manager.windows[window];
		   w != nil &&
		   w.pid == cover.pid &&
		   w.generation == cover.window_generation {
			w.resize_transitioning = false
		}
		resize_cover_backend(state).destroy(state, cover.surface)
		delete_key(&state.resize_covers, window)
		motion_trace_record(
			&state.manager.motion_trace,
			{kind = "resize-cover-end", window = window},
		)
	}
}
resize_cover_stop :: proc(state: ^State) {
	for window in state.resize_covers { resize_cover_remove(state, window) }
	delete(state.resize_covers); state.resize_covers = nil
	delete(state.resize_snapshots); state.resize_snapshots = nil
}
resize_cover_frame :: proc(
	state: ^State,
	window: u32,
	frame: Rect,
	previous: Maybe(Rect),
	now: f64,
) {
	if !state.manager.resize_fade {
		resize_cover_remove(state, window); return
	}
	if state.resize_cover_cancel {
		return
	}
	w := state.manager.windows[window]
	// A capture taken while the client owns an interactive resize can be a
	// blank or stale surface, and capture can stall the drag's presentation.
	// Keep the live client visible until the gesture has ended.
	if w != nil && (w.grabbed || state.manager.native_resize_window == window ||
		   (state.mouse.drag.window == window && state.mouse.drag.action == .Resize)) {
		resize_cover_remove(state, window); return
	}
	if w == nil ||
	   state.opening_windows[window] ||
	   !managed(w) ||
	   state.manager.suspended ||
	   state.manager.gesture_active {
		return
	}
	s := space_by_id(&state.manager, w.space)
	if s == nil || !s.visible || w.minimized || w.hidden || w.fullscreen {
		return
	}
	cover, exists := state.resize_covers[window]
	if exists &&
	   (cover.pid != w.pid || cover.window_generation != w.generation) {
		resize_cover_remove(state, window)
		exists = false
	}
	if exists {
		if geometry := resize_cover_geometry(state, window); geometry.active {
			resize_cover_blend_geometry(
				&cover,
				geometry.from,
				geometry.target,
				geometry.progress,
				geometry.clock,
			)
		} else if !cover.synchronized &&
		   (cover.frame.w != frame.w || cover.frame.h != frame.h) {
			resize_cover_retarget(&cover, now)
		}
		cover.frame = frame
		state.resize_covers[window] = cover
		return
	}
	old, known := previous.?
	if !known ||
	   len(state.resize_covers) >= RESIZE_COVER_LIMIT ||
	   now < state.resize_cover_retry {
		return
	}
	large := math.abs(frame.w - old.w) > 10 || math.abs(frame.h - old.h) > 10
	if s.view.layout == .Scroll && s.view.scroll.geometry_active {
		large =
			math.abs(w.scroll_frame.target.w - w.scroll_frame.from.w) > 10 ||
			math.abs(w.scroll_frame.target.h - w.scroll_frame.from.h) > 10
	}
	if job, exists := state.animations[window];
	   exists &&
	   animation_is_live(job) &&
	   animation_matches(state, window, job) {
		large =
			math.abs(job.target.w - job.from.w) > 10 ||
			math.abs(job.target.h - job.from.h) > 10
	}
	if !large ||
	   (math.abs(frame.w - old.w) < .5 && math.abs(frame.h - old.h) < .5) {
		return
	}
	started := time.tick_now()
	surface, err := resize_cover_backend(state).create(state, window, old)
	if err != "" {
		state.resize_cover_retry = now + 2
		fmt.eprintln("shoji: resize fade:", err)
		return
	}
	if state.resize_covers == nil {
		state.resize_covers = make(map[u32]Resize_Cover)
	}
	cover = {
		window_generation = w.generation,
		surface           = surface,
		pid               = w.pid,
		frame             = frame,
		began             = now,
		out_began         = now,
		out_from          = 1,
		alpha             = 1,
	}
	if geometry := resize_cover_geometry(state, window); geometry.active {
		resize_cover_blend_geometry(
			&cover,
			geometry.from,
			geometry.target,
			geometry.progress,
			geometry.clock,
		)
	}
	state.resize_covers[window] = cover
	w.resize_transitioning = true
	motion_trace_record(
		&state.manager.motion_trace,
		{
			kind = "resize-cover-start",
			window = window,
			duration_ms = f64(time.tick_since(started)) / 1e6,
		},
	)
}
resize_cover_retarget :: proc(cover: ^Resize_Cover, now: f64) {
	if cover.revealing {
		cover.out_began, cover.out_from, cover.alpha = now, 1, 1
	}
	cover.stable_since, cover.fade_began, cover.revealing = 0, 0, false
}
// Stable bounds are a bounded readiness heuristic, not a client repaint fence.
resize_cover_step :: proc(
	cover: ^Resize_Cover,
	now: f64,
	moving, settled: bool,
	max_duration: f64 = RESIZE_COVER_MAX,
) -> bool {
	if now - cover.began >= max_duration {
		return true
	}
	if moving || !settled {
		resize_cover_retarget(cover, now)
	}
	if !cover.revealing {
		t := clamp(
			(now - cover.out_began - RESIZE_COVER_DELAY) / RESIZE_COVER_OUT,
			0,
			1,
		)
		cover.alpha = cover.out_from * (1 - t * t * (3 - 2 * t))
	}
	if moving || !settled {
		return false
	}
	if cover.stable_since == 0 {
		cover.stable_since = now
	}
	if now - cover.stable_since < .08 {
		return false
	}
	if cover.fade_began == 0 {
		cover.fade_began = now; cover.revealing = true
	}
	t := clamp((now - cover.fade_began) / RESIZE_COVER_FADE, 0, 1)
	cover.alpha = t * t * (3 - 2 * t)
	return t >= 1
}
resize_cover_tick :: proc(state: ^State, now: f64) {
	if !state.manager.resize_fade || state.resize_cover_cancel {
		resize_cover_stop(state); state.resize_cover_cancel = false; return
	}
	backend := resize_cover_backend(state)
	for window, value in state.resize_covers {
		cover := value
		if now - cover.began >=
		   (state.manager.native_resize_window == window \
					   ? 15 \
					   : RESIZE_COVER_MAX) {
			resize_cover_remove(state, window); continue
		}
		w := state.manager.windows[window]
		s := w != nil ? space_by_id(&state.manager, w.space) : nil
		if w == nil ||
		   w.pid != cover.pid ||
		   w.generation != cover.window_generation ||
		   s == nil ||
		   !s.visible ||
		   !managed(w) ||
		   state.manager.suspended ||
		   state.manager.gesture_active ||
		   w.minimized ||
		   w.hidden ||
		   w.fullscreen {
			resize_cover_remove(state, window); continue
		}
		moving :=
			s.view.layout == .Scroll && s.view.scroll.geometry_active ||
			state.manager.native_resize_window == window
		model_frame := w.frame
		if job, exists := state.animations[window];
		   exists &&
		   animation_is_live(job) &&
		   animation_matches(state, window, job) {
			moving = true; model_frame = job.presentation.(Live_Resize).current
		}
		if geometry := resize_cover_geometry(state, window); geometry.active {
			resize_cover_blend_geometry(
				&cover,
				geometry.from,
				geometry.target,
				geometry.progress,
				geometry.clock,
			)
		} else if cover.synchronized {
			// Geometry and live content finish together, without a second fade.
			resize_cover_remove(state, window); continue
		}
		if !cover.synchronized &&
		   (cover.frame.w != model_frame.w || cover.frame.h != model_frame.h) {
			resize_cover_retarget(&cover, now)
		}
		cover.frame = model_frame
		actual, valid := backend.bounds(state, window)
		if !valid {
			resize_cover_remove(state, window); continue
		}
		settled :=
			math.abs(actual.w - cover.frame.w) <= 2 &&
			math.abs(actual.h - cover.frame.h) <= 2
		if !cover.synchronized &&
		   resize_cover_step(
			   &cover,
			   now,
			   moving,
			   settled,
			   state.manager.native_resize_window == window \
				   ? 15 \
				   : RESIZE_COVER_MAX,
		   ) {
			resize_cover_remove(state, window); continue
		}
		state.resize_covers[window] = cover
		started := time.tick_now()
		if err := backend.update(
			state,
			cover.surface,
			window,
			cover.frame,
			cover.alpha,
			cover.revealing,
		); err != "" {
			resize_cover_remove(state, window); continue
		}
		motion_trace_record(
			&state.manager.motion_trace,
			{
				kind = "resize-cover-update",
				window = window,
				value = cover.alpha,
				requested = cover.frame,
				observed = actual,
				duration_ms = f64(time.tick_since(started)) / 1e6,
			},
		)
	}
}
