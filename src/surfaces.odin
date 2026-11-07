package shoji


foreign import surface_sls "system:SkyLight.framework"
foreign import surface_cg "system:CoreGraphics.framework"

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
	_, observed_level := window_query_appearance(state.connection, owner)
	level, level_known := observed_level.?
	sublevel, sublevel_known := window_sublevel(state.connection, owner).?
	if !level_known || !sublevel_known {
		return {}, "could not read surface owner layer"
	}
	SLSSetWindowLevel(state.connection, surface.id, level)
	SLSSetWindowSubLevel(state.connection, surface.id, sublevel)
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
