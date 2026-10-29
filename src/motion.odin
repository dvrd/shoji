#+build darwin

package shoji

import wire "dock"
import "base:intrinsics"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import objc "core:sys/darwin/Foundation"
import "core:sys/posix"
import "core:time"

foreign import display_quartz "system:QuartzCore.framework"
foreign import frame_updates_sls "system:SkyLight.framework"
foreign import animation_sls "system:SkyLight.framework"
foreign import animation_cg "system:CoreGraphics.framework"
foreign import recovery_sls "system:SkyLight.framework"
foreign import surface_sls "system:SkyLight.framework"
foreign import surface_cg "system:CoreGraphics.framework"
foreign import resize_cg "system:CoreGraphics.framework"
foreign import feedback_sls "system:SkyLight.framework"
foreign import feedback_cg "system:CoreGraphics.framework"

// Display clock and frame pacing
// ------------------------------------------------------------------------

// All callbacks and consumers run on the main run loop. One replaceable pulse
// avoids queuing obsolete animation work when a client blocks the daemon.
Frame_Pacer :: struct {
	pending: bool,
	target, last_callback, last_take, consumed_target: f64,
	period: f64,
	superseded: u64,
}
frame_pacer_pulse :: proc(p: ^Frame_Pacer, target, now, period: f64) {
	if math.is_nan(target) ||
	   math.is_inf(target) ||
	   target < now - 0.1 ||
	   target > now + 0.1 {
		return
	}
	if target <= p.consumed_target {
		return
	}
	if p.pending {
		p.superseded += 1
	}
	p.pending, p.target, p.last_callback = true, target, now
	if period > 0 && period <= .1 {
		p.period = period
	}
}
frame_pacer_take :: proc(
	p: ^Frame_Pacer,
	now: f64,
	linked: bool,
) -> (
	ready: bool,
	target: f64,
	fallback: bool,
) {
	if linked && p.pending {
		p.pending = false
		p.last_take, p.consumed_target = now, p.target
		return true, max(now, p.target), false
	}
	// A missing/paused display must not strand windows. Throttle fallback too.
	if (!linked || now - p.last_callback >= 0.1) &&
	   now - p.last_take >= 1.0 / 60 {
		p.last_take = now
		return true, now, true
	}
	return false, now, false
}
Display_Clock :: struct {
	listener, link: ^objc.Object,
	display: u32,
	running: bool,
	retry_at: f64,
	pacer: Frame_Pacer,
}
foreign display_quartz { CACurrentMediaTime :: proc "c" () -> f64 --- }
display_listener_class: objc.Class
display_listeners: map[rawptr]^Display_Clock

display_clock_callback :: proc "c" (
	object: ^objc.Object,
	_: objc.SEL,
	sender: ^objc.Object,
) {
	context = runtime.default_context()
	clock := display_listeners[rawptr(object)]
	if clock == nil || !clock.running {
		return
	}
	frame_pacer_pulse(
		&clock.pacer,
		intrinsics.objc_send(f64, sender, "targetTimestamp"),
		CACurrentMediaTime(),
		intrinsics.objc_send(f64, sender, "duration"),
	)
}
display_clock_stop :: proc(clock: ^Display_Clock) {
	if clock.link != nil {
		intrinsics.objc_send(nil, clock.link, "invalidate")
		intrinsics.objc_send(nil, clock.link, "release")
	}
	if clock.listener != nil {
		delete_key(&display_listeners, rawptr(clock.listener))
		intrinsics.objc_send(nil, clock.listener, "release")
	}
	clock^ = {}
	if len(display_listeners) == 0 {
		delete(display_listeners); display_listeners = nil
	}
}
// An unsuccessful creation records a retry deadline, not permanent success.
display_clock_should_create :: proc(
	clock: ^Display_Clock,
	display: u32,
	now: f64,
) -> bool {
	if clock.link != nil {
		return false
	}
	if clock.display != display {
		clock.display = display; clock.retry_at = 0
	}
	if now < clock.retry_at {
		return false
	}
	clock.retry_at = now + .5
	return true
}
display_clock_prepare :: proc(
	clock: ^Display_Clock,
	display: u32,
	moving: bool,
	now: f64 = 0,
) {
	now := now
	if now == 0 {
		now = CACurrentMediaTime()
	}
	if clock.display != display {
		display_clock_stop(clock)
	}
	if !moving {
		if clock.link != nil && clock.running {
			intrinsics.objc_send(nil, clock.link, "setPaused:", bool(true))
		}
		clock.running = false; clock.pacer.pending = false
		return
	}
	if display_clock_should_create(clock, display, now) {
		created := false
		defer {
			if !created {
				retry, pacer := clock.retry_at, clock.pacer
				display_clock_stop(clock)
				clock.display, clock.retry_at = display, retry
				clock.pacer = pacer
			}
		}
		if display_listener_class == nil {
			display_listener_class = objc.objc_allocateClassPair(
				objc.objc_lookUpClass("NSObject"),
				"ShojiDisplayClock",
				0,
			)
			if display_listener_class == nil {
				return
			}
			if !objc.class_addMethod(
				display_listener_class,
				objc.sel_registerName("frame:"),
				cast(objc.IMP)display_clock_callback,
				"v@:@",
			) {
				objc.objc_disposeClassPair(display_listener_class)
				display_listener_class = nil
				return
			}
			objc.objc_registerClassPair(display_listener_class)
		}
		screens := intrinsics.objc_send(
			^objc.Object,
			(^objc.Object)(objc.objc_lookUpClass("NSScreen")),
			"screens",
		)
		count := intrinsics.objc_send(int, screens, "count")
		screen: ^objc.Object
		for i in 0 ..< count {
			candidate := intrinsics.objc_send(
				^objc.Object,
				screens,
				"objectAtIndex:",
				i,
			)
			description := intrinsics.objc_send(
				^objc.Object,
				candidate,
				"deviceDescription",
			)
			key := cf_string("NSScreenNumber")
			number := intrinsics.objc_send(
				^objc.Object,
				description,
				"objectForKey:",
				(^objc.Object)(key),
			); CFRelease(key)
			if intrinsics.objc_send(u32, number, "unsignedIntValue") ==
			   display {
				screen = candidate; break
			}
		}
		if screen == nil ||
		   !intrinsics.objc_send(
				   bool,
				   screen,
				   "respondsToSelector:",
				   objc.sel_registerName("displayLinkWithTarget:selector:"),
			   ) {
			return
		}
		clock.listener = intrinsics.objc_send(
			^objc.Object,
			(^objc.Object)(display_listener_class),
			"new",
		)
		if clock.listener == nil {
			return
		}
		if display_listeners == nil {
			display_listeners = make(map[rawptr]^Display_Clock)
		}
		display_listeners[rawptr(clock.listener)] = clock
		clock.link = intrinsics.objc_send(
			^objc.Object,
			screen,
			"displayLinkWithTarget:selector:",
			clock.listener,
			objc.sel_registerName("frame:"),
		)
		if clock.link == nil {
			return
		}
		intrinsics.objc_send(nil, clock.link, "retain")
		intrinsics.objc_send(
			nil,
			clock.link,
			"addToRunLoop:forMode:",
			objc.RunLoop_mainRunLoop(),
			objc.RunLoopCommonModes,
		)
		created = true
	}
	if clock.link != nil && !clock.running {
		clock.running = true
		clock.pacer.last_callback = CACurrentMediaTime()
		intrinsics.objc_send(nil, clock.link, "setPaused:", bool(false))
	}
}
// Convert only the short relative prediction; CA uptime and wall time are
// different epochs. Action processing keeps its actual-time clock separately.
display_clock_take :: proc(
	clock: ^Display_Clock,
	now: time.Time,
) -> (
	bool,
	time.Time,
	bool,
) {
	ready, target, fallback := frame_pacer_take(
		&clock.pacer,
		CACurrentMediaTime(),
		clock.link != nil && clock.running,
	)
	lead := clamp(target - CACurrentMediaTime(), 0, .05)
	return ready,
		time.time_add(now, time.Duration(lead * f64(time.Second))),
		fallback
}

// Nested presentation batches
// ------------------------------------------------------------------------

Frame_Updates :: struct {
	depth: int,
	user: rawptr,
	set_enabled: proc(user: rawptr, connection: i32, enabled: bool) -> i32,
}

foreign frame_updates_sls {
	SLSDisableUpdate :: proc "c" (connection: i32) -> i32 ---
	SLSReenableUpdate :: proc "c" (connection: i32) -> i32 ---
}

frame_updates_set :: proc(state: ^State, enabled: bool) -> i32 {
	if state.frame_updates.set_enabled != nil {
		return state.frame_updates.set_enabled(
			state.frame_updates.user,
			state.connection,
			enabled,
		)
	}
	if state.connection == 0 {
		return 0
	}
	return(
		enabled \
			? SLSReenableUpdate(state.connection) \
			: SLSDisableUpdate(state.connection) \
	)
}

frame_updates_begin :: proc(state: ^State) -> string {
	if state.frame_updates.depth == 0 {
		if code := frame_updates_set(state, false); code != 0 {
			return fmt.tprintf(
				"could not begin frame presentation batch (%d)",
				code,
			)
		}
	}
	state.frame_updates.depth += 1
	return ""
}

frame_updates_end :: proc(state: ^State) -> string {
	if state.frame_updates.depth <= 0 {
		return "unbalanced frame presentation batch"
	}
	state.frame_updates.depth -= 1
	if state.frame_updates.depth == 0 {
		if code := frame_updates_set(state, true); code != 0 {
			return fmt.tprintf("could not present frame batch (%d)", code)
		}
	}
	return ""
}

// Coordinated motion ticks
// ------------------------------------------------------------------------

motion_active :: proc(state: ^State) -> bool {
	if len(state.animations) > 0 ||
	   len(state.resize_covers) > 0 ||
	   state.mouse.scroll_tracking ||
	   stack_touch_has_pending() ||
	   state.mouse.drag.window != 0 {
		return true
	}
	for s in state.manager.spaces {
		if s.visible &&
		   s.view.layout == .Scroll &&
		   (s.view.scroll.dragging || s.view.scroll.motion.active || s.view.scroll.geometry_active) {
			return true
		}
	}
	return false
}

// One display pulse, one fixed sample time and one presentation batch for
// native geometry and its content covers. Nested AX/scroll batches stay inside
// this boundary; no overlay is presented ahead of its corresponding frame.
motion_frame_tick :: proc(
	state: ^State,
	ready: bool,
	sample_now: time.Time,
	uptime: f64,
) {
	if !ready {
		mouse_tick(state, false, sample_now)
		if !state.manager.resize_fade || state.resize_cover_cancel {
			resize_cover_tick(state, uptime)
		}
		focus_ring_tick(state)
		return
	}
	active := motion_active(state)
	if active {
		if err := frame_updates_begin(state); err != "" {
			fmt.eprintln("shoji: motion:", err); return
		}
	}
	defer {
		if active {
			if err := frame_updates_end(state); err != "" {
				fmt.eprintln("shoji: motion:", err)
			}
		}
	}
	state.manager.scroll_time = time.duration_seconds(
		time.diff(time.Time{}, sample_now),
	)
	animation_tick(state, sample_now)
	mouse_tick(state, true, sample_now)
	scroll_native_tick(state, sample_now)
	resize_cover_tick(state, uptime)
	focus_ring_tick(state)
}

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

// Animation recovery journal
// ------------------------------------------------------------------------

Animation_Journal :: struct {
	path: string,
	entries: map[u32]wire.Entry,
	next_retry: time.Time,
}
Journal_Data :: struct {
	version: int,
	entries: []wire.Entry,
}
JOURNAL_LIMIT :: 256
animation_journal_close :: proc(j: ^Animation_Journal) {
	delete(j.path); delete(j.entries); j^ = {}
}
animation_journal_open :: proc(j: ^Animation_Journal, path: string) -> string {
	j.path = strings.clone(path)
	j.entries = make(map[u32]wire.Entry)
	fd := posix.open(
		strings.clone_to_cstring(path, context.temp_allocator),
		{.NOFOLLOW, .NONBLOCK, .CLOEXEC},
	)
	if fd < 0 {
		if posix.errno() == .ENOENT {
			return ""
		}
		return "cannot open animation recovery journal"
	}
	defer posix.close(fd)
	info: posix.stat_t
	if posix.fstat(fd, &info) != nil ||
	   !posix.S_ISREG(info.st_mode) ||
	   u32(info.st_uid) != getuid() ||
	   info.st_size <= 0 ||
	   info.st_size > 65536 {
		return "invalid animation recovery journal file"
	}
	bytes := make([]u8, int(info.st_size), context.temp_allocator)
	offset := 0
	for offset < len(bytes) {
		n := posix.read(
			fd,
			raw_data(bytes[offset:]),
			uint(int(len(bytes)) - offset),
		)
		if n < 0 && posix.errno() == .EINTR {
			continue
		}
		if n <= 0 {
			return "cannot read animation recovery journal"
		}
		offset += int(n)
	}
	data: Journal_Data
	if json.unmarshal(bytes, &data, allocator = context.temp_allocator) !=
		   nil ||
	   data.version != 1 ||
	   len(data.entries) > JOURNAL_LIMIT {
		return "invalid animation recovery journal data"
	}
	for entry in data.entries {
		if entry.window == 0 ||
		   entry.proxy == 0 ||
		   entry.owner == 0 ||
		   entry.proxy_owner == 0 ||
		   entry.window in j.entries {
			return "invalid animation recovery entry"
		}
		j.entries[entry.window] = entry
	}
	return ""
}
animation_journal_save :: proc(j: ^Animation_Journal) -> string {
	if j.path == "" {
		return "animation recovery journal is unavailable"
	}
	entries := make(
		[dynamic]wire.Entry,
		0,
		len(j.entries),
		context.temp_allocator,
	)
	for _, entry in j.entries { append(&entries, entry) }
	bytes, err := json.marshal(
		Journal_Data{1, entries[:]},
		allocator = context.temp_allocator,
	)
	if err != nil {
		return "cannot encode animation recovery journal"
	}
	// mkstemp creates mode 0600. fsync before atomic rename ensures a crash
	// cannot leave a partial journal after the real window has been hidden.
	temporary := strings.clone_to_cstring(
		fmt.tprintf("%s.XXXXXX", j.path),
		context.temp_allocator,
	)
	fd := posix.mkstemp(temporary)
	if fd < 0 {
		return "cannot create animation recovery journal"
	}
	defer posix.close(fd)
	defer posix.unlink(temporary)
	offset := 0
	for offset < len(bytes) {
		n := posix.write(
			fd,
			raw_data(bytes[offset:]),
			uint(int(len(bytes)) - offset),
		)
		if n < 0 && posix.errno() == .EINTR {
			continue
		}
		if n <= 0 {
			return "cannot write animation recovery journal"
		}
		offset += int(n)
	}
	if posix.fsync(fd) != nil || os.rename(string(temporary), j.path) != nil {
		return "cannot commit animation recovery journal"
	}
	return ""
}
animation_journal_record :: proc(
	j: ^Animation_Journal,
	entry: wire.Entry,
) -> string {
	if entry.window in j.entries {
		return "window has unfinished animation recovery"
	}
	if len(j.entries) >= JOURNAL_LIMIT {
		return "animation recovery journal is full"
	}
	j.entries[entry.window] = entry
	if err := animation_journal_save(j); err != "" {
		delete_key(&j.entries, entry.window); return err
	}
	return ""
}
animation_journal_remove :: proc(
	j: ^Animation_Journal,
	window: u32,
) -> string {
	entry, exists := j.entries[window]
	if !exists {
		return ""
	}
	delete_key(&j.entries, window)
	if err := animation_journal_save(j); err != "" {
		j.entries[window] = entry; return err
	}
	return ""
}
animation_recovery_owner :: proc(user: rawptr, window: u32) -> (i32, bool) {
	state := (^State)(user)
	owner: i32
	if window == 0 {
		return owner, false
	}
	return animation_recovery_query_owner(state.connection, window)
}
foreign recovery_sls {
	SLSGetWindowOwner :: proc "c" (cid: i32, window: u32, owner: ^i32) -> i32 ---
}
animation_recovery_query_owner :: proc(cid: i32, window: u32) -> (i32, bool) {
	owner: i32
	code := SLSGetWindowOwner(cid, window, &owner)
	return owner, code == 0
}
animation_recovery_restore :: proc(
	user: rawptr,
	entry: wire.Entry,
	proxy_valid: bool,
) -> bool {
	return(
		animation_swap(
			{window = entry.window, id = proxy_valid ? entry.proxy : 0},
			false,
		) ==
		"" \
	)
}
animation_recovery_tick :: proc(state: ^State, now: time.Time) {
	j := &state.animation_journal
	if len(j.entries) == 0 || time.diff(now, j.next_retry) > 0 {
		return
	}
	j.next_retry = time.time_add(now, time.Second)
	// A unavailable Dock must not cause journal entries to be discarded.
	if _, err := addition_check(); err != "" {
		return
	}
	windows := make([dynamic]u32, context.temp_allocator)
	backend := wire.Backend {
		animation_recovery_owner,
		animation_recovery_restore,
		state,
	}
	for window, entry in j.entries {
		if window in state.animations || window in state.opening_guards {
			continue
		}
		result := wire.restore(entry, backend, false)
		if result == .Restored || result == .Gone {
			append(&windows, window)
		}
	}
	for window in windows {
		if err := animation_journal_remove(j, window); err != "" {
			fmt.eprintln("shoji:", err)
		}
	}
}

// Owned native surfaces
// ------------------------------------------------------------------------

Animation_Transform :: struct {
	a, b, c, d, tx, ty: f64,
}
@(default_calling_convention = "c")
foreign surface_sls {
	CGSNewRegionWithRect :: proc(rect: ^Rect, region: ^Ref) -> i32 ---
	CGRegionCreateEmptyRegion :: proc() -> Ref ---
	SLSNewWindowWithOpaqueShapeAndContext :: proc(cid, type: i32, region, empty: Ref, flags: i32, tags: ^u64, x, y: f32, tag_size: i32, window: ^u32, ctx: rawptr) -> i32 ---
	SLWindowContextCreate :: proc(cid: i32, window: u32, options: Ref) -> Ref ---
	SLSReleaseWindow :: proc(cid: i32, window: u32) -> i32 ---
	SLSSetWindowOpacity :: proc(cid: i32, window: u32, opaque: bool) -> i32 ---
	SLSSetWindowResolution :: proc(cid: i32, window: u32, scale: f64) -> i32 ---
	SLSSetWindowAlpha :: proc(cid: i32, window: u32, alpha: f32) -> i32 ---
	SLSSetWindowLevel :: proc(cid: i32, window: u32, level: i32) -> i32 ---
	SLSSetWindowSubLevel :: proc(cid: i32, window: u32, level: i32) -> i32 ---
	SLSSetWindowTransform :: proc(cid: i32, window: u32, transform: Animation_Transform) -> i32 ---
}
@(default_calling_convention = "c")
foreign surface_cg {
	CGContextClearRect :: proc(ctx: Ref, rect: Rect) ---
	CGContextFlush :: proc(ctx: Ref) ---
	CGContextRelease :: proc(ctx: Ref) ---
}

// Owns one Shoji-created WindowServer surface and its drawing context.
// Capture, real-window hiding, and crash recovery belong to animation alone.
Owned_Surface :: struct {
	id: u32,
	ctx: Ref,
	frame: Rect,
}

surface_destroy :: proc(state: ^State, surface: Owned_Surface) {
	if surface.ctx != nil {
		CGContextRelease(surface.ctx)
	}
	if surface.id != 0 {
		SLSReleaseWindow(state.connection, surface.id)
	}
}

surface_create :: proc(
	state: ^State,
	frame: Rect,
	owner: u32,
	tags: u64,
	flags: i32,
	scale: f64,
) -> (
	surface: Owned_Surface,
	err: string,
) {
	surface.frame = frame
	region: Ref
	if CGSNewRegionWithRect(&surface.frame, &region) != 0 || region == nil {
		return {}, "could not allocate surface region"
	}
	defer CFRelease(region)
	empty := CGRegionCreateEmptyRegion()
	if empty == nil {
		return {}, "could not allocate empty surface region"
	}
	defer CFRelease(empty)
	tags := tags
	if SLSNewWindowWithOpaqueShapeAndContext(
		   state.connection,
		   2,
		   region,
		   empty,
		   flags,
		   &tags,
		   0,
		   0,
		   64,
		   &surface.id,
		   nil,
	   ) !=
	   0 {
		return {}, "could not create surface"
	}
	success := false
	defer {
		if !success {
			surface_destroy(state, surface)
		}
	}
	surface.ctx = SLWindowContextCreate(state.connection, surface.id, nil)
	if surface.ctx == nil {
		return {}, "could not create surface drawing context"
	}
	SLSSetWindowOpacity(state.connection, surface.id, false)
	SLSSetWindowResolution(state.connection, surface.id, scale)
	level: i32
	SLSGetWindowLevel(state.connection, owner, &level)
	SLSSetWindowLevel(state.connection, surface.id, level)
	SLSSetWindowSubLevel(
		state.connection,
		surface.id,
		SLSGetWindowSubLevel(state.connection, owner),
	)
	success = true
	return surface, ""
}

surface_update :: proc(
	state: ^State,
	surface: Owned_Surface,
	frame: Rect,
) -> string {
	transform := Animation_Transform {
		a = surface.frame.w / frame.w,
		d = surface.frame.h / frame.h,
	}
	transform.tx, transform.ty = -frame.x * transform.a, -frame.y * transform.d
	if SLSSetWindowTransform(state.connection, surface.id, transform) != 0 {
		return "could not transform surface"
	}
	return ""
}

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

// Interaction feedback
// ------------------------------------------------------------------------

Feedback_Window :: struct {
	plan: Feedback_Plan,
	surface: Owned_Surface,
}
Feedback_Backend :: struct {
	create: proc(
		state: ^State,
		plan: Feedback_Plan,
	) -> (
		Owned_Surface,
		string,
	),
	destroy: proc(state: ^State, surface: Owned_Surface),
	update: proc(
		state: ^State,
		surface: Owned_Surface,
		frame: Rect,
	) -> string,
	reorder: proc(
		state: ^State,
		owner: u32,
		surfaces: []Owned_Surface,
	) -> string,
}

Focus_Ring :: struct {
	window, owner: u32,
	generation: u64,
	config: Focus_Ring_Config,
	failed: bool,
	order_dirty: bool,
	bars: [8]Feedback_Window,
}

Tab_Indicator_State :: struct {
	bars: [MAX_STACK]Feedback_Window,
	tabs: [MAX_STACK]Tab_Indicator,
	count: int,
	order_dirty: bool,
}

tab_indicator_stop :: proc(state: ^State) {
	backend := feedback_backend(state)
	for bar in state.tab_indicator.bars {
		if bar.surface.id != 0 { backend.destroy(state, bar.surface) }
	}
	state.tab_indicator = {}
}

tab_indicator_tick :: proc(state: ^State, frame: Rect, relative: u32) {
	tabs, count := tab_indicators(&state.manager, frame)
	backend := feedback_backend(state)
	indicator := &state.tab_indicator
	for i in 0 ..< MAX_STACK {
		bar := &indicator.bars[i]
		if i >= count {
			if bar.surface.id != 0 { backend.destroy(state, bar.surface) }
			bar^ = {}; indicator.tabs[i] = {}; continue
		}
		color := tabs[i].active \
			? (state.manager.tab_indicator_active_color.? or_else state.manager.focus_ring.color) \
			: (state.manager.tab_indicator_inactive_color.? or_else u32(0xff505050))
		plan := Feedback_Plan{window = relative, frame = tabs[i].frame, color = color, solid = true}
		if plan != bar.plan {
			indicator.order_dirty = true
			if bar.surface.id != 0 && bar.plan.window == plan.window && bar.plan.color == plan.color && backend.update != nil {
				if err := backend.update(state, bar.surface, plan.frame); err != "" {
					backend.destroy(state, bar.surface); bar.surface = {}
					fmt.eprintln("shoji: tab indicator:", err)
				}
			} else {
				if bar.surface.id != 0 { backend.destroy(state, bar.surface) }
				err: string
				bar.surface, err = backend.create(state, plan)
				if err != "" { fmt.eprintln("shoji: tab indicator:", err) }
			}
			bar.plan = plan
		}
		indicator.tabs[i] = tabs[i]
	}
	indicator.count = count
	if count > 0 && indicator.order_dirty && backend.reorder != nil {
		indicator.order_dirty = false
		surfaces: [MAX_STACK]Owned_Surface; surface_count := 0
		for i in 0 ..< count {
			if indicator.bars[i].surface.id != 0 {
				surfaces[surface_count] = indicator.bars[i].surface
				surface_count += 1
			}
		}
		if err := backend.reorder(state, relative, surfaces[:surface_count]); err != "" {
			fmt.eprintln("shoji: tab indicator:", err)
		}
	}
}

focus_ring_stop :: proc(state: ^State) {
	backend := feedback_backend(state)
	for bar in state.focus_ring.bars {
		if bar.surface.id != 0 {
			backend.destroy(state, bar.surface)
		}
	}
	state.focus_ring = {}
}

focus_ring_prune_unordered :: proc(
	state: ^State,
	probe: proc(state: ^State, window: u32) -> Maybe(bool) = nil,
) {
	ring := &state.focus_ring
	owner, generation := ring.owner, ring.generation
	if owner == 0 {
		for i in 0 ..< state.tab_indicator.count {
			tab := state.tab_indicator.tabs[i]
			if tab.active { owner, generation = tab.window, tab.generation; break }
		}
	}
	if owner == 0 {
		return
	}
	w := state.manager.windows[owner]
	if w == nil || w.generation != generation {
		focus_ring_stop(state); tab_indicator_stop(state); return
	}
	probe := probe
	if probe == nil {
		if state.connection == 0 {
			return
		}
		probe = window_ordered_in
	}
	// A retained NSWindow can close by ordering out without an AX destruction
	// notification. Trust a known native result; failed reads preserve state.
	if ordered, known := probe(state, w.id).?; known && !ordered {
		w.ordered_in = false
		focus_ring_stop(state); tab_indicator_stop(state)
	}
}

focus_ring_note_action :: proc(state: ^State, action: Action) {
	if action.window != state.manager.focused {
		return
	}
	#partial switch action.kind {
	case .Order, .Layer, .Focus, .Focus_Without_Raise:
		state.focus_ring.order_dirty = true
		state.tab_indicator.order_dirty = true
	}
}

focus_ring_fail :: proc(state: ^State, err: string) {
	backend := feedback_backend(state)
	for &bar in state.focus_ring.bars {
		if bar.surface.id != 0 {
			backend.destroy(state, bar.surface); bar.surface = {}
		}
	}
	state.focus_ring.failed = true
	fmt.eprintln("shoji: focus ring:", err)
}

focus_ring_tick :: proc(state: ^State) {
	w := state.manager.windows[state.manager.focused]
	if state.read_only ||
	   w == nil ||
	   (state.connection == 0 && state.feedback_backend.create == nil) {
		focus_ring_stop(state); tab_indicator_stop(state); return
	}
	if !managed(w) &&
	   (state.focus_geometry_dirty || state.mouse.buttons != 0) &&
	   w.id not_in state.animations {
		state.focus_geometry_dirty = false
		probe := state.focus_frame_probe
		if probe == nil && state.connection != 0 {
			probe = mouse_native_resize_frame
		}
		if probe != nil {
			if observed, valid := probe(state, w.id);
			   valid && valid_frame(observed) {
				w.frame = observed
			}
		}
	}
	frame, relative := w.frame, w.id
	if s := space_by_id(&state.manager, w.space);
	   s != nil && s.view.layout == .Scroll && managed(w) && w.id not_in state.animations {
		moving := s.view.scroll.dragging || s.view.scroll.motion.active || s.view.scroll.geometry_active
		if moving {
			state.focus_scroll_pending = w.id
			state.focus_scroll_deadline = CACurrentMediaTime() + 1
		}
		if moving || state.focus_scroll_pending == w.id {
			probe := state.focus_frame_probe
			if probe == nil && state.connection != 0 { probe = mouse_native_resize_frame }
			if probe != nil {
				observed, valid := probe(state, w.id)
				if !valid || !valid_frame(observed) {
					focus_ring_stop(state); tab_indicator_stop(state); return
				}
				frame = observed
				if !moving && (CACurrentMediaTime() >= state.focus_scroll_deadline ||
				   math.abs(observed.x-w.frame.x) < 1.5 &&
				   math.abs(observed.y-w.frame.y) < 1.5 &&
				   math.abs(observed.w-w.frame.w) < 1.5 &&
				   math.abs(observed.h-w.frame.h) < 1.5) {
					state.focus_scroll_pending = 0
				}
			}
		}
	} else {
		state.focus_scroll_pending = 0
	}
	if job, exists := state.animations[w.id];
	   exists && animation_matches(state, w.id, job) {
		switch presentation in job.presentation {
		case Live_Resize:
			frame = presentation.current
		case Animation_Proxy:
			frame = interpolate_frame(
				job.from,
				job.target,
				job.progress,
				.Linear,
			)
			relative = presentation.id
		}
	}
	tab_indicator_tick(state, frame, relative)
	plans, valid := focus_ring_plans(&state.manager, frame)
	if !valid {
		focus_ring_stop(state); return
	}
	if state.focus_ring.window != relative ||
	   state.focus_ring.owner != w.id ||
	   state.focus_ring.generation != w.generation ||
	   state.focus_ring.config != state.manager.focus_ring {
		previous := state.manager.windows[state.focus_ring.owner]
		space := space_by_id(&state.manager, w.space)
		reuse := previous != nil && previous.generation == state.focus_ring.generation &&
			previous.space == w.space && space != nil && space.visible && space.view.layout == .Scroll &&
			state.focus_ring.config == state.manager.focus_ring && !state.focus_ring.failed &&
			state.focus_ring.window == state.focus_ring.owner && relative == w.id
		if !reuse { focus_ring_stop(state) }
		state.focus_ring.window, state.focus_ring.generation =
			relative, w.generation
		state.focus_ring.owner = w.id
		state.focus_ring.config = state.manager.focus_ring
		state.focus_ring.order_dirty = true
	}
	if state.focus_ring.failed {
		return
	}
	backend := feedback_backend(state)
	for plan, i in plans {
		plan := plan; plan.window = relative
		bar := &state.focus_ring.bars[i]
		if plan.frame.w <= 0 || plan.frame.h <= 0 {
			if bar.surface.id != 0 {
				backend.destroy(state, bar.surface)
			}
			bar^ = {}; continue
		}
		if bar.plan == plan {
			continue
		}
		err: string
		corner_changed :=
			plan.corner != .None &&
			(bar.plan.frame.w != plan.frame.w ||
					bar.plan.frame.h != plan.frame.h ||
					bar.plan.stroke_width != plan.stroke_width)
		if bar.surface.id != 0 && backend.update != nil && !corner_changed {
			err = backend.update(state, bar.surface, plan.frame)
		} else {
			if bar.surface.id != 0 {
				backend.destroy(state, bar.surface)
			}
			bar.surface, err = backend.create(state, plan)
		}
		if err != "" {
			focus_ring_fail(state, err); return
		}
		// An unchanged plan performs no native work on idle loop iterations.
		bar.plan = plan
	}
	if state.focus_ring.order_dirty && backend.reorder != nil {
		// Native opening/focus can raise the owner or restore its layer after
		// these surfaces were created, even when geometry has not changed.
		state.focus_ring.order_dirty = false
		surfaces: [8]Owned_Surface; count := 0
		for bar in state.focus_ring.bars {
			if bar.surface.id != 0 {
				surfaces[count] = bar.surface; count += 1
			}
		}
		if err := backend.reorder(state, relative, surfaces[:count]);
		   err != "" {
			focus_ring_fail(state, err)
		}
	}
}

focus_ring_sublevel :: proc(owner: i32) -> i32 {
	return owner < max(i32) ? owner + 1 : owner
}

native_focus_ring_reorder :: proc(
	state: ^State,
	owner: u32,
	surfaces: []Owned_Surface,
) -> string {
	level: i32
	if SLSGetWindowLevel(state.connection, owner, &level) != 0 {
		return "could not read focus owner level"
	}
	// Native same-window clicks can raise the owner without changing focus.
	// Keep its decoration on the next sublevel of the same window level,
	// rather than relying on a one-time relative order within its own plane.
	sublevel := focus_ring_sublevel(
		SLSGetWindowSubLevel(state.connection, owner),
	)
	for surface in surfaces {
		if SLSSetWindowLevel(state.connection, surface.id, level) != 0 ||
		   SLSSetWindowSubLevel(state.connection, surface.id, sublevel) != 0 ||
		   SLSOrderWindow(state.connection, surface.id, 1, owner) != 0 {
			return "could not order focus ring above its owner"
		}
	}
	return ""
}

@(default_calling_convention = "c")
foreign feedback_sls {
	SLSOrderWindow :: proc(cid: i32, window: u32, order: i32, relative: u32) -> i32 ---
	SLSSetWindowTags :: proc(cid: i32, window: u32, tags: ^u64, count: uint) -> i32 ---
}
@(default_calling_convention = "c")
foreign feedback_cg {
	CGContextSaveGState :: proc(ctx: Ref) ---
	CGContextRestoreGState :: proc(ctx: Ref) ---
	CGContextGetCTM :: proc(ctx: Ref) -> Animation_Transform ---
	CGContextTranslateCTM :: proc(ctx: Ref, x, y: f64) ---
	CGContextScaleCTM :: proc(ctx: Ref, x, y: f64) ---
	CGContextBeginPath :: proc(ctx: Ref) ---
	CGContextAddEllipseInRect :: proc(ctx: Ref, rect: Rect) ---
	CGContextEOFillPath :: proc(ctx: Ref) ---
	CGContextSetRGBFillColor :: proc(ctx: Ref, r, g, b, a: f64) ---
	CGContextSetRGBStrokeColor :: proc(ctx: Ref, r, g, b, a: f64) ---
	CGContextSetLineWidth :: proc(ctx: Ref, width: f64) ---
	CGContextFillRect :: proc(ctx: Ref, rect: Rect) ---
	CGContextStrokeRect :: proc(ctx: Ref, rect: Rect) ---
}

native_feedback_create :: proc(
	state: ^State,
	plan: Feedback_Plan,
) -> (
	surface: Owned_Surface,
	err: string,
) {
	if plan.frame.w <= 0 || plan.frame.h <= 0 {
		return {}, "feedback area is too small"
	}
	surface, err = surface_create(
		state,
		plan.frame,
		plan.window,
		(1 << 1) | (1 << 9),
		13,
		1,
	)
	if err != "" {
		return {}, err
	}
	success := false
	defer {
		if !success {
			surface_destroy(state, surface)
		}
	}
	shadow: u64 = 1 << 3
	SLSSetWindowTags(state.connection, surface.id, &shadow, 64)
	native_feedback_paint(surface.ctx, plan)
	if error := surface_update(state, surface, surface.frame); error != "" {
		return {}, error
	}
	if SLSOrderWindow(state.connection, surface.id, 1, plan.window) != 0 {
		return {}, "could not order feedback window"
	}
	success = true
	return surface, ""
}

native_feedback_paint :: proc(ctx: Ref, plan: Feedback_Plan) {
	CGContextSaveGState(ctx)
	defer CGContextRestoreGState(ctx)
	// Ring plans use screen coordinates (Y down). Bitmap contexts and window
	// contexts can have different base transforms; normalize before drawing.
	if CGContextGetCTM(ctx).d > 0 {
		CGContextTranslateCTM(ctx, 0, plan.frame.h)
		CGContextScaleCTM(ctx, 1, -1)
	}
	r, g, b, a :=
		f64((plan.color >> 16) & 255) /
		255,
		f64((plan.color >> 8) & 255) /
		255,
		f64(plan.color & 255) /
		255,
		f64(plan.color >> 24) /
		255
	frame := Rect{0, 0, plan.frame.w, plan.frame.h}
	CGContextClearRect(ctx, frame)
	CGContextSetRGBFillColor(ctx, r, g, b, plan.solid ? a : a * 0.25)
	if plan.corner != .None {
		// Clip a quarter annulus to this small corner surface. The center stays
		// transparent; no full-window bitmap or stretched curved border is used.
		radius := frame.w
		x :=
			plan.corner == .Top_Left || plan.corner == .Bottom_Left \
				? radius \
				: f64(0)
		y :=
			plan.corner == .Top_Left || plan.corner == .Top_Right \
				? radius \
				: f64(0)
		CGContextBeginPath(ctx)
		CGContextAddEllipseInRect(
			ctx,
			{x - radius, y - radius, radius * 2, radius * 2},
		)
		inner := max(0, radius - plan.stroke_width)
		if inner > 0 {
			CGContextAddEllipseInRect(
				ctx,
				{x - inner, y - inner, inner * 2, inner * 2},
			)
		}
		CGContextEOFillPath(ctx)
	} else {
		CGContextFillRect(ctx, frame)
	}
	if !plan.solid && frame.w > 2 && frame.h > 2 {
		CGContextSetRGBStrokeColor(ctx, r, g, b, a)
		CGContextSetLineWidth(ctx, 2)
		CGContextStrokeRect(ctx, {1, 1, frame.w - 2, frame.h - 2})
	}
	CGContextFlush(ctx)
}

feedback_backend :: proc(state: ^State) -> Feedback_Backend {
	if state.feedback_backend.create != nil {
		return state.feedback_backend
	}
	return {
		native_feedback_create,
		surface_destroy,
		surface_update,
		native_focus_ring_reorder,
	}
}

feedback_sync :: proc(state: ^State, plans: map[u32]Feedback_Plan) {
	backend := feedback_backend(state)
	removed := make([dynamic]u32, context.temp_allocator)
	for key, window in state.feedback {
		window := window
		plan, exists := plans[key]
		if exists &&
		   plan != window.plan &&
		   plan.solid &&
		   window.plan.solid &&
		   plan.window == window.plan.window &&
		   plan.color == window.plan.color &&
		   plan.corner == window.plan.corner &&
		   plan.stroke_width == window.plan.stroke_width {
			if window.surface.id == 0 || backend.update != nil {
				if window.surface.id != 0 {
					if err := backend.update(
						state,
						window.surface,
						plan.frame,
					); err != "" {
						backend.destroy(state, window.surface)
						window.surface = {}
						fmt.eprintln("shoji: feedback:", err)
					}
				}
				window.plan = plan; state.feedback[key] = window
				continue
			}
		}
		if !exists || plan != window.plan {
			backend.destroy(state, window.surface); append(&removed, key)
		}
	}
	for key in removed { delete_key(&state.feedback, key) }
	for key, plan in plans {
		if _, exists := state.feedback[key]; exists {
			continue
		}
		surface, err := backend.create(state, plan)
		if err != "" {
			fmt.eprintln("shoji: feedback:", err)
		}
		if state.feedback == nil {
			state.feedback = make(map[u32]Feedback_Window)
		}
		// Cache failed plans too, avoiding a log/allocation storm every frame.
		state.feedback[key] = Feedback_Window{plan, surface}
	}
}

feedback_tick :: proc(state: ^State) {
	plans := make(map[u32]Feedback_Plan, context.temp_allocator)
	if !state.read_only {
		for s in state.manager.spaces {
			if plan, valid := insertion_feedback(&state.manager, s); valid {
				plans[plan.window] = plan
			}
		}
		mouse := &state.mouse
		if mouse_drag_moved(mouse) &&
		   !mouse_drag_finished(mouse) &&
		   !mouse.failed {
			if plan, valid := drag_feedback(
				&state.manager,
				mouse.drag,
				mouse.target,
				mouse.point,
			); valid {
				plans[0] = plan
			}
		}
	}
	feedback_sync(state, plans)
}

feedback_stop :: proc(state: ^State) {
	focus_ring_stop(state)
	tab_indicator_stop(state)
	backend := feedback_backend(state)
	for _, window in state.feedback { backend.destroy(state, window.surface) }
	delete(state.feedback); state.feedback = nil
}
