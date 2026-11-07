package shoji

import wire "dock"
import "core:fmt"
import "core:time"

foreign import animation_sls "system:SkyLight.framework"
foreign import animation_cg "system:CoreGraphics.framework"

// Window animation
// ------------------------------------------------------------------------

Animation_Proxy :: struct {
	window: u32,
	using surface: Owned_Surface,
}
Live_Resize :: struct {
	current: Rect,
}
Animation_Presentation :: union {
	Live_Resize,
	Animation_Proxy,
}
Animation_Job :: struct {
	generation: u64,
	pid: i32,
	presentation: Animation_Presentation,
	from: Rect,
	target: Rect,
	began: time.Time,
	duration: f64,
	easing: Easing,
	progress: f64,
}
animation_is_live :: proc(job: Animation_Job) -> bool {
	_, live := job.presentation.(Live_Resize)
	return live
}
animation_matches :: proc(
	state: ^State,
	window: u32,
	job: Animation_Job,
) -> bool {
	w := state.manager.windows[window]
	return w != nil && w.generation == job.generation && w.pid == job.pid
}
Animation_Backend :: struct {
	create: proc(state: ^State, window: u32) -> (Animation_Proxy, string),
	update: proc(
		state: ^State,
		proxy: Animation_Proxy,
		frame: Rect,
	) -> string,
	restore: proc(state: ^State, proxy: Animation_Proxy) -> string,
	destroy: proc(state: ^State, proxy: Animation_Proxy),
	apply: proc(state: ^State, window: u32, frame: Rect) -> string,
}

@(default_calling_convention = "c")
foreign animation_sls {
	SLSHWCaptureWindowList :: proc(cid: i32, windows: ^u32, count, options: i32) -> Ref ---
}
@(default_calling_convention = "c")
foreign animation_cg {
	CGPreflightScreenCaptureAccess :: proc() -> bool ---
	CGContextDrawImage :: proc(ctx: Ref, rect: Rect, image: Ref) ---
}

animation_swap :: proc(proxy: Animation_Proxy, hide: bool) -> string {
	packet := wire.begin(hide ? wire.Opcode.Proxy_In : wire.Opcode.Proxy_Out)
	wire.pack(&packet, i32(1)); wire.pack(&packet, proxy.window)
	wire.pack(&packet, proxy.id)
	_, err := addition_exchange(&packet)
	return err
}

native_proxy_destroy :: proc(state: ^State, proxy: Animation_Proxy) {
	surface_destroy(state, proxy.surface)
}

native_proxy_create :: proc(
	state: ^State,
	window: u32,
) -> (
	proxy: Animation_Proxy,
	err: string,
) {
	window := window
	if window in state.animation_journal.entries {
		return {}, "window has pending animation recovery"
	}
	if !CGPreflightScreenCaptureAccess() {
		return {},
			"Screen Recording permission is required for window animations"
	}
	if _, error := addition_check(); error != "" {
		return {}, error
	}
	proxy.window = window
	if SLSGetWindowBounds(state.connection, window, &proxy.frame) != 0 ||
	   proxy.frame.w <= 0 ||
	   proxy.frame.h <= 0 {
		return {}, "could not capture window bounds"
	}
	images := SLSHWCaptureWindowList(
		state.connection,
		&window,
		1,
		(1 << 11) | (1 << 8),
	)
	if images == nil {
		return {}, "could not capture window image"
	}
	defer CFRelease(images)
	if CFArrayGetCount(images) == 0 {
		return {}, "window capture returned no images"
	}
	surface, surface_error := surface_create(
		state,
		proxy.frame,
		window,
		1 << 46,
		13 | (1 << 18),
		2,
	)
	if surface_error != "" {
		return {}, surface_error
	}
	proxy.surface = surface
	success := false
	defer {
		if !success {
			native_proxy_destroy(state, proxy)
		}
	}
	alpha: f32 = 1
	SLSGetWindowAlpha(state.connection, window, &alpha)
	SLSSetWindowAlpha(state.connection, proxy.id, alpha)
	frame := Rect{0, 0, proxy.frame.w, proxy.frame.h}
	CGContextClearRect(proxy.ctx, frame)
	CGContextDrawImage(proxy.ctx, frame, CFArrayGetValueAtIndex(images, 0))
	CGContextFlush(proxy.ctx)
	if error := native_proxy_update(state, proxy, proxy.frame); error != "" {
		return {}, error
	}
	owner, real_ok := animation_recovery_query_owner(state.connection, window)
	proxy_owner, proxy_ok := animation_recovery_query_owner(
		state.connection,
		proxy.id,
	)
	if !real_ok || !proxy_ok {
		return {}, "could not identify animation window owners"
	}
	if error := animation_journal_record(
		&state.animation_journal,
		wire.Entry{window, proxy.id, owner, proxy_owner},
	); error != "" {
		return {}, error
	}
	if error := animation_swap(proxy, true); error != "" {
		// An exchange may time out after Dock has hidden the real window.
		// Attempt restoration before releasing the proxy.
		if restored := animation_swap(proxy, false); restored != "" {
			if state.animations == nil {
				state.animations = make(map[u32]Animation_Job)
			}
			state.animations[window] = Animation_Job {
				generation   = state.manager.windows[window].generation,
				pid          = state.manager.windows[window].pid,
				presentation = proxy,
			}
			success = true
		} else {
			animation_journal_remove(&state.animation_journal, window)
		}
		return {}, error
	}
	success = true
	return proxy, ""
}

native_proxy_update :: proc(
	state: ^State,
	proxy: Animation_Proxy,
	frame: Rect,
) -> string {
	return surface_update(state, proxy.surface, frame)
}
native_proxy_restore :: proc(state: ^State, proxy: Animation_Proxy) -> string {
	entry, exists := state.animation_journal.entries[proxy.window]
	if !exists {
		return "animation recovery entry is missing"
	}
	backend := wire.Backend {
		animation_recovery_owner,
		animation_recovery_restore,
		state,
	}
	if result := wire.restore(entry, backend, false); result == .Retry {
		return "could not restore animated window"
	}
	return animation_journal_remove(&state.animation_journal, proxy.window)
}
animation_backend :: proc(state: ^State) -> Animation_Backend {
	if state.animation_backend.create != nil {
		return state.animation_backend
	}
	return {
		native_proxy_create,
		native_proxy_update,
		native_proxy_restore,
		native_proxy_destroy,
		apply_frame_now,
	}
}

animation_finish :: proc(state: ^State, window: u32) -> string {
	job, exists := state.animations[window]
	if !exists {
		return ""
	}
	backend := animation_backend(state)
	if !animation_matches(state, window, job) {
		if proxy, captured := job.presentation.(Animation_Proxy); captured {
			backend.destroy(state, proxy)
		}
		// The native journal/watchdog can restore the old owner's alpha if it
		// still exists. Never apply the old target to a replacement window.
		delete_key(&state.animations, window)
		return ""
	}
	if animation_is_live(job) {
		if state.manager.windows[window] != nil &&
		   job.presentation.(Live_Resize).current != job.target {
			if err := backend.apply(state, window, job.target); err != "" {
				return err
			}
		}
		delete_key(&state.animations, window)
		state.dirty = true
		return ""
	}
	if err := backend.restore(state, job.presentation.(Animation_Proxy));
	   err != "" {
		return err
	}
	backend.destroy(state, job.presentation.(Animation_Proxy))
	delete_key(&state.animations, window)
	return ""
}

// An immediate frame supersedes animation rather than completing its stale
// target. Captured proxies must restore their real window before it moves.
animation_interrupt :: proc(state: ^State, window: u32) -> string {
	job, exists := state.animations[window]
	if !exists {
		return ""
	}
	if !animation_matches(state, window, job) {
		return animation_finish(state, window)
	}
	if !animation_is_live(job) {
		backend := animation_backend(state)
		if err := backend.restore(state, job.presentation.(Animation_Proxy));
		   err != "" {
			return err
		}
		backend.destroy(state, job.presentation.(Animation_Proxy))
	}
	delete_key(&state.animations, window)
	return ""
}

animation_start :: proc(state: ^State, action: Action) -> string {
	return animation_start_at(state, action, time.now())
}

animation_frame_action :: proc(state: ^State, action: Action) -> Action {
	result := action
	if w := state.manager.windows[action.window]; w != nil {
		if w.opening.phase == .Opening ||
		   w.frame.w != action.frame.w ||
		   w.frame.h != action.frame.h {
			result.live_resize = true
		}
	}
	if job, exists := state.animations[action.window];
	   exists &&
	   animation_is_live(job) &&
	   animation_matches(state, action.window, job) {
		result.live_resize = true
	}
	return result
}

animation_start_at :: proc(
	state: ^State,
	action: Action,
	now: time.Time,
) -> string {
	if state.manager.windows[action.window] == nil {
		return "window no longer exists"
	}
	if job, exists := state.animations[action.window];
	   exists && !animation_matches(state, action.window, job) {
		if err := animation_finish(state, action.window); err != "" {
			return err
		}
	}
	backend := animation_backend(state)
	if action.live_resize {
		w := state.manager.windows[action.window]
		if w == nil {
			return "window no longer exists"
		}
		from := w.frame
		if job, exists := state.animations[action.window];
		   exists &&
		   animation_is_live(job) &&
		   animation_matches(state, action.window, job) {
			from = job.presentation.(Live_Resize).current
		} else if err := animation_finish(state, action.window); err != "" {
			return err
		}
		if state.animations == nil {
			state.animations = make(map[u32]Animation_Job)
		}
		// Resize the app itself so text and controls redraw at their native
		// scale. No captured surface is stretched or hidden for this transition.
		state.animations[action.window] = Animation_Job {
			generation   = w.generation,
			pid          = w.pid,
			presentation = Live_Resize{from},
			from         = from,
			target       = action.frame,
			began        = now,
			duration     = action.duration,
			easing       = state.manager.animation_easing,
		}
		return ""
	}
	if job, exists := state.animations[action.window];
	   exists && animation_is_live(job) {
		if err := animation_finish(state, action.window); err != "" {
			return err
		}
	}
	if job, exists := state.animations[action.window];
	   exists && job.duration > 0 {
		// Keep the original captured surface and recovery record. Restoring and
		// recapturing here would flash the real window at its previous target.
		t := time.duration_seconds(time.diff(job.began, now)) / job.duration
		from := interpolate_frame(job.from, job.target, t, job.easing)
		if err := backend.apply(state, action.window, action.frame);
		   err != "" {
			return err
		}
		job.from, job.target, job.began, job.duration =
			from, action.frame, now, action.duration
		job.easing = state.manager.animation_easing
		state.animations[action.window] = job
		return ""
	}
	if err := animation_finish(state, action.window); err != "" {
		return err
	}
	proxy, err := backend.create(state, action.window)
	if err != "" {
		return err
	}
	if state.animations == nil {
		state.animations = make(map[u32]Animation_Job)
	}
	state.animations[action.window] = Animation_Job {
		generation   = state.manager.windows[action.window].generation,
		pid          = state.manager.windows[action.window].pid,
		presentation = proxy,
		from         = proxy.frame,
		target       = action.frame,
		began        = now,
		duration     = action.duration,
		easing       = state.manager.animation_easing,
	}
	if err := backend.apply(state, action.window, action.frame); err != "" {
		animation_finish(state, action.window)
		return err
	}
	return ""
}

animation_tick :: proc(state: ^State, now: time.Time) {
	backend := animation_backend(state)
	live_batch := false
	for _, job in state.animations {
		if animation_is_live(job) {
			live_batch = true; break
		}
	}
	if live_batch {
		if err := frame_updates_begin(state); err != "" {
			fmt.eprintln("shoji:", err); return
		}
		defer {
			if err := frame_updates_end(state); err != "" {
				fmt.eprintln("shoji:", err)
			}
		}
	}
	finished := make([dynamic]u32, context.temp_allocator)
	for window, job in state.animations {
		if !animation_matches(state, window, job) {
			append(&finished, window); continue
		}
		if job.duration <= 0 {
			append(&finished, window); continue
		}
		t := time.duration_seconds(time.diff(job.began, now)) / job.duration
		if animation_is_live(job) {
			if state.manager.suspended ||
			   state.manager.gesture_active ||
			   state.manager.windows[window] == nil {
				append(&finished, window); continue
			}
			frame := interpolate_frame(job.from, job.target, t, job.easing)
			updated := job
			updated.presentation, updated.progress =
				Live_Resize{frame}, ease(job.easing, t)
			state.animations[window] = updated
			if err := backend.apply(state, window, frame); err != "" {
				fmt.eprintln("shoji: live resize:", err)
				delete_key(&state.animations, window); state.dirty = true
				continue
			}
			if t >= 1 {
				append(&finished, window)
			}
			continue
		}
		if state.manager.suspended ||
		   state.manager.gesture_active ||
		   state.manager.windows[window] == nil ||
		   t >= 1 {
			append(&finished, window); continue
		}
		if err := backend.update(
			state,
			job.presentation.(Animation_Proxy),
			interpolate_frame(job.from, job.target, t, job.easing),
		); err != "" {
			append(&finished, window)
		} else {
			updated := job; updated.progress = ease(job.easing, t)
			state.animations[window] = updated
		}
	}
	for window in finished { animation_finish(state, window) }
}

animation_stop :: proc(state: ^State) {
	backend := animation_backend(state)
	for window, job in state.animations {
		if err := animation_finish(state, window); err != "" {
			fmt.eprintln(
				"shoji: animated window recovery deferred",
				window,
				":",
				err,
			)
			// The committed journal survives shutdown. Releasing the proxy also
			// lets the live payload watchdog restore the real window immediately.
			if proxy, captured := job.presentation.(Animation_Proxy);
			   captured {
				backend.destroy(state, proxy)
			}
			delete_key(&state.animations, window)
		}
	}
	delete(state.animations); state.animations = nil
}
