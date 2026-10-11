package macos

import wire "../addition/protocol"
import e "../engine"
import "core:fmt"
import "core:time"

Animation_Proxy :: struct {
	window, id: u32,
	ctx:        Ref,
	frame:      e.Rect,
}
Animation_Job :: struct {
	proxy:    Animation_Proxy,
	target:   e.Rect,
	began:    time.Time,
	duration: f64,
	easing:   e.Easing,
}
Animation_Backend :: struct {
	create:  proc(state: ^State, window: u32) -> (Animation_Proxy, string),
	update:  proc(state: ^State, proxy: Animation_Proxy, frame: e.Rect) -> string,
	restore: proc(state: ^State, proxy: Animation_Proxy) -> string,
	destroy: proc(state: ^State, proxy: Animation_Proxy),
	apply:   proc(state: ^State, action: e.Action) -> string,
}

foreign import animation_sls "system:SkyLight.framework"
foreign import animation_cg "system:CoreGraphics.framework"
Animation_Transform :: struct {
	a, b, c, d, tx, ty: f64,
}
@(default_calling_convention = "c")
foreign animation_sls {
	SLSHWCaptureWindowList :: proc(cid: i32, windows: ^u32, count, options: i32) -> Ref ---
	CGSNewRegionWithRect :: proc(rect: ^e.Rect, region: ^Ref) -> i32 ---
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
foreign animation_cg {
	CGPreflightScreenCaptureAccess :: proc() -> bool ---
	CGContextClearRect :: proc(ctx: Ref, rect: e.Rect) ---
	CGContextDrawImage :: proc(ctx: Ref, rect: e.Rect, image: Ref) ---
	CGContextFlush :: proc(ctx: Ref) ---
	CGContextRelease :: proc(ctx: Ref) ---
}

animation_swap :: proc(proxy: Animation_Proxy, hide: bool) -> string {
	packet := wire.begin(hide ? wire.Opcode.Proxy_In : wire.Opcode.Proxy_Out)
	wire.pack(&packet, i32(1));wire.pack(&packet, proxy.window);wire.pack(&packet, proxy.id)
	_, err := addition_exchange(&packet)
	return err
}

native_proxy_destroy :: proc(state: ^State, proxy: Animation_Proxy) {
	if proxy.ctx != nil {CGContextRelease(proxy.ctx)}
	if proxy.id != 0 {SLSReleaseWindow(state.connection, proxy.id)}
}

native_proxy_create :: proc(state: ^State, window: u32) -> (proxy: Animation_Proxy, err: string) {
	window := window
	if !CGPreflightScreenCaptureAccess(
		
	) {return {}, "Screen Recording permission is required for window animations"}
	if _, error := addition_check(); error != "" {return {}, error}
	proxy.window = window
	if SLSGetWindowBounds(state.connection, window, &proxy.frame) != 0 ||
	   proxy.frame.w <= 0 ||
	   proxy.frame.h <= 0 {return {}, "could not capture window bounds"}
	images := SLSHWCaptureWindowList(state.connection, &window, 1, (1 << 11) | (1 << 8))
	if images == nil {return {}, "could not capture window image"}
	defer CFRelease(images)
	if CFArrayGetCount(images) == 0 {return {}, "window capture returned no images"}
	region: Ref
	if CGSNewRegionWithRect(&proxy.frame, &region) != 0 ||
	   region == nil {return {}, "could not allocate proxy region"}
	defer CFRelease(region)
	empty := CGRegionCreateEmptyRegion()
	if empty == nil {return {}, "could not allocate empty proxy region"}
	defer CFRelease(empty)
	tags: u64 = 1 << 46
	if SLSNewWindowWithOpaqueShapeAndContext(
		   state.connection,
		   2,
		   region,
		   empty,
		   13 | (1 << 18),
		   &tags,
		   0,
		   0,
		   64,
		   &proxy.id,
		   nil,
	   ) !=
	   0 {return {}, "could not create animation proxy"}
	success := false
	defer {if !success {native_proxy_destroy(state, proxy)}}
	proxy.ctx = SLWindowContextCreate(state.connection, proxy.id, nil)
	if proxy.ctx == nil {return {}, "could not create proxy drawing context"}
	alpha: f32 = 1;level: i32
	SLSGetWindowAlpha(state.connection, window, &alpha)
	SLSGetWindowLevel(state.connection, window, &level)
	SLSSetWindowOpacity(state.connection, proxy.id, false)
	SLSSetWindowResolution(state.connection, proxy.id, 2)
	SLSSetWindowAlpha(state.connection, proxy.id, alpha)
	SLSSetWindowLevel(state.connection, proxy.id, level)
	SLSSetWindowSubLevel(
		state.connection,
		proxy.id,
		SLSGetWindowSubLevel(state.connection, window),
	)
	frame := e.Rect{0, 0, proxy.frame.w, proxy.frame.h}
	CGContextClearRect(proxy.ctx, frame)
	CGContextDrawImage(proxy.ctx, frame, CFArrayGetValueAtIndex(images, 0))
	CGContextFlush(proxy.ctx)
	if error := native_proxy_update(state, proxy, proxy.frame); error != "" {return {}, error}
	if error := animation_swap(proxy, true); error != "" {
		// An exchange may time out after Dock has hidden the real window.
		// Attempt restoration before releasing the proxy.
		if restored := animation_swap(proxy, false); restored != "" {
			if state.animations == nil {state.animations = make(map[u32]Animation_Job)}
			state.animations[window] = Animation_Job {
				proxy = proxy,
			}
			success = true
		}
		return {}, error
	}
	success = true
	return proxy, ""
}

native_proxy_update :: proc(state: ^State, proxy: Animation_Proxy, frame: e.Rect) -> string {
	transform := Animation_Transform {
		a = proxy.frame.w / frame.w,
		d = proxy.frame.h / frame.h,
	}
	transform.tx, transform.ty = -frame.x * transform.a, -frame.y * transform.d
	if SLSSetWindowTransform(state.connection, proxy.id, transform) !=
	   0 {return "could not transform animation proxy"}
	return ""
}
native_proxy_restore :: proc(
	state: ^State,
	proxy: Animation_Proxy,
) -> string {return animation_swap(proxy, false)}
native_proxy_apply :: proc(state: ^State, action: e.Action) -> string {return perform(
		state,
		action,
	)}

animation_backend :: proc(state: ^State) -> Animation_Backend {
	if state.animation_backend.create != nil {return state.animation_backend}
	return {
		native_proxy_create,
		native_proxy_update,
		native_proxy_restore,
		native_proxy_destroy,
		native_proxy_apply,
	}
}

animation_finish :: proc(state: ^State, window: u32) -> string {
	job, exists := state.animations[window]
	if !exists {return ""}
	backend := animation_backend(state)
	if err := backend.restore(state, job.proxy); err != "" {return err}
	backend.destroy(state, job.proxy)
	delete_key(&state.animations, window)
	return ""
}

animation_start :: proc(state: ^State, action: e.Action) -> string {
	if err := animation_finish(state, action.window); err != "" {return err}
	backend := animation_backend(state)
	proxy, err := backend.create(state, action.window)
	if err != "" {return err}
	if state.animations == nil {state.animations = make(map[u32]Animation_Job)}
	state.animations[action.window] = Animation_Job {
		proxy,
		action.frame,
		time.now(),
		action.duration,
		state.manager.animation_easing,
	}
	raw := action;raw.duration = 0
	if err := backend.apply(state, raw); err != "" {
		animation_finish(state, action.window)
		return err
	}
	return ""
}

animation_tick :: proc(state: ^State, now: time.Time) {
	backend := animation_backend(state)
	finished := make([dynamic]u32, context.temp_allocator)
	for window, job in state.animations {
		if job.duration <= 0 {append(&finished, window);continue}
		t := time.duration_seconds(time.diff(job.began, now)) / job.duration
		if state.manager.suspended ||
		   state.manager.gesture_active ||
		   state.manager.windows[window] == nil ||
		   t >= 1 {append(&finished, window);continue}
		if err := backend.update(
			state,
			job.proxy,
			e.interpolate_frame(job.proxy.frame, job.target, t, job.easing),
		); err != "" {append(&finished, window)}
	}
	for window in finished {animation_finish(state, window)}
}

animation_stop :: proc(state: ^State) {
	for window in state.animations {
		if err := animation_finish(state, window);
		   err != "" {fmt.eprintln("shoji: could not restore animated window", window, ":", err)}
	}
	// Failed restores remain owned for a retry rather than deleting the only
	// visible representation of a window after a transport timeout.
	if len(state.animations) == 0 {delete(state.animations);state.animations = nil}
}
