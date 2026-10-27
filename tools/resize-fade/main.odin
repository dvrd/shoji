package main

import e "../../src/engine"
import mac "../../src/macos"
import "base:intrinsics"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import objc "core:sys/darwin/Foundation"

foreign import cover_test_cg "system:CoreGraphics.framework"
foreign cover_test_cg {
	CGColorSpaceCreateDeviceRGB :: proc "c" () -> mac.Ref ---
	CGColorSpaceRelease :: proc "c" (space: mac.Ref) ---
	CGBitmapContextCreate :: proc "c" (data: rawptr, width, height, bits, row: uint, space: mac.Ref, flags: u32) -> mac.Ref ---
	CGBitmapContextCreateImage :: proc "c" (ctx: mac.Ref) -> mac.Ref ---
}
run_resize_fade :: proc(path: string) -> bool {
	pool := mac.pool_push(); defer mac.pool_pop(pool)
	state: mac.State; state.connection = mac.SLSMainConnectionID()
	e.manager_init(&state.manager); defer e.manager_destroy(&state.manager)
	defer mac.resize_cover_stop(&state)
	state.manager.resize_fade = true
	color := CGColorSpaceCreateDeviceRGB(); if color == nil {
		return false
	}; defer CGColorSpaceRelease(color)
	pixels: [256 * 256 * 4]u8
	ctx := CGBitmapContextCreate(&pixels[0], 256, 256, 8, 256 * 4, color, 1)
	if ctx == nil {
		return false
	}; defer mac.CGContextRelease(ctx)
	for y in 0 ..< 256 {
		for x in 0 ..< 256 {
			v := (x / 8 + y / 8) % 2 == 0 ? u8(0) : u8(255)
			i := (y * 256 + x) * 4
			pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3] =
				v, v, v, 255
		}
	}
	image := CGBitmapContextCreateImage(ctx); if image == nil {
		return false
	}; defer mac.CGImageRelease(image)
	window := make_window("Shoji disposable resize fade")
	if window == nil {
		return false
	}; defer intrinsics.objc_send(nil, window, "close")
	ns_image := intrinsics.objc_send(
		^objc.Object,
		(^objc.Object)(objc.objc_lookUpClass("NSImage")),
		"alloc",
	)
	ns_image = intrinsics.objc_send(
		^objc.Object,
		ns_image,
		"initWithCGImage:size:",
		image,
		mac.Size{256, 256},
	)
	view := intrinsics.objc_send(
		^objc.Object,
		(^objc.Object)(objc.objc_lookUpClass("NSImageView")),
		"alloc",
	)
	view = intrinsics.objc_send(
		^objc.Object,
		view,
		"initWithFrame:",
		e.Rect{0, 0, 440, 260},
	)
	intrinsics.objc_send(nil, view, "setImage:", ns_image)
	intrinsics.objc_send(nil, view, "setImageScaling:", int(1))
	intrinsics.objc_send(nil, window, "setContentView:", view)
	intrinsics.objc_send(nil, ns_image, "release")
	intrinsics.objc_send(nil, view, "release")
	mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, .1, false)
	id := u32(intrinsics.objc_send(int, window, "windowNumber"))
	frame: e.Rect
	if mac.SLSGetWindowBounds(state.connection, id, &frame) != 0 {
		return false
	}
	s := e.add_space(&state.manager, 1, 1, 1, frame); s.visible = true
	w := e.add_window(
		&state.manager,
		{
			id = id,
			pid = mac.getpid(),
			space = 1,
			display = 1,
			role = "AXWindow",
			subrole = "AXStandardWindow",
			frame = frame,
			opacity = 1,
		},
	)
	target := frame; target.w += 180; target.h += 100
	mac.resize_cover_frame(&state, id, target, frame, mac.CACurrentMediaTime())
	cover, exists := state.resize_covers[id]
	if !exists {
		fmt.eprintln("native resize cover did not start"); return false
	}
	background := state.resize_snapshots[cover.surface.id].background
	initial_contrast := resize_image_contrast(
		state.resize_snapshots[cover.surface.id].initial,
	)
	if mac.native_resize_cover_update(
		   &state,
		   cover.surface,
		   id,
		   target,
		   0,
		   false,
	   ) !=
	   "" {
		return false
	}
	matte := mac.resize_snapshot(&state, cover.surface.id)
	if matte == nil {
		return false
	}; defer mac.CGImageRelease(matte)
	out_contrast := resize_image_contrast(matte)
	intrinsics.objc_send(nil, view, "setImage:", rawptr(nil))
	cocoa := target
	cocoa.y =
		mac.CGDisplayBounds(mac.CGMainDisplayID()).h - target.y - target.h
	intrinsics.objc_send(nil, window, "setFrame:display:", cocoa, bool(true))
	w.frame = target
	mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, .05, false)
	point := mac.Point{target.x + target.w * .5, target.y + target.h * .5}
	local: mac.Point
	hit: u32; owner: i32
	hit_code := mac.SLSFindWindowAndOwner(
		state.connection,
		0,
		1,
		0,
		&point,
		&local,
		&hit,
		&owner,
	)
	alpha: f32; mac.SLSGetWindowAlpha(state.connection, id, &alpha)
	mid_alpha := 1.0
	final_contrast := 255
	start := mac.CACurrentMediaTime()
	for mac.CACurrentMediaTime() - start < 1.2 {
		mac.resize_cover_tick(&state, mac.CACurrentMediaTime())
		if c, ok := state.resize_covers[id]; ok && c.alpha > 0 && c.alpha < 1 {
			mid_alpha = min(mid_alpha, c.alpha)
			final_contrast = resize_image_contrast(
				state.resize_snapshots[cover.surface.id].final,
			)
		}
		mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, .008, true)
	}
	// A coordinated resize uses the same size progress to blend the retained
	// old image over live app contents, with no second screenshot or fade tail.
	manual_cleaned := len(state.resize_covers) == 0
	check_image := intrinsics.objc_send(
		^objc.Object,
		(^objc.Object)(objc.objc_lookUpClass("NSImage")),
		"alloc",
	)
	check_image = intrinsics.objc_send(
		^objc.Object,
		check_image,
		"initWithCGImage:size:",
		image,
		mac.Size{256, 256},
	)
	intrinsics.objc_send(nil, view, "setImage:", check_image)
	intrinsics.objc_send(nil, check_image, "release")
	mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, .03, false)
	state.animations = make(map[u32]mac.Animation_Job)
	defer delete(state.animations)
	next := target; next.w += 180
	middle := target; middle.w += 90
	state.animations[id] = {
		from         = target,
		target       = next,
		presentation = mac.Live_Resize{middle},
		progress     = .5,
	}
	mac.resize_cover_frame(
		&state,
		id,
		middle,
		target,
		mac.CACurrentMediaTime(),
	)
	intrinsics.objc_send(nil, view, "setImage:", rawptr(nil))
	cocoa = middle
	cocoa.y =
		mac.CGDisplayBounds(mac.CGMainDisplayID()).h - middle.y - middle.h
	intrinsics.objc_send(nil, window, "setFrame:display:", cocoa, bool(true))
	mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, .03, false)
	mac.resize_cover_tick(&state, mac.CACurrentMediaTime())
	synced, sync_exists := state.resize_covers[id]
	sync_alpha: f32 = -1
	live_contents := false
	background_readback_skipped := false
	retarget_alpha: f32 = -1
	repeated_retarget_alpha: f32 = -1
	retarget_reuses_snapshot := false
	if sync_exists {
		mac.SLSGetWindowAlpha(state.connection, synced.surface.id, &sync_alpha)
		original_snapshot := state.resize_snapshots[synced.surface.id].initial
		live_contents = state.resize_snapshots[synced.surface.id].final == nil
		background_readback_skipped = !state.resize_snapshots[synced.surface.id].background_ready
		reversed := middle; reversed.w -= 120
		state.animations[id] = {
			from         = middle,
			target       = reversed,
			presentation = mac.Live_Resize{middle},
			progress     = 0,
		}
		mac.resize_cover_frame(
			&state,
			id,
			middle,
			middle,
			mac.CACurrentMediaTime(),
		)
		mac.resize_cover_tick(&state, mac.CACurrentMediaTime())
		mac.SLSGetWindowAlpha(
			state.connection,
			synced.surface.id,
			&retarget_alpha,
		)
		reversed.w -= 40
		state.animations[id] = {
			from         = middle,
			target       = reversed,
			presentation = mac.Live_Resize{middle},
			progress     = 0,
		}
		mac.resize_cover_frame(
			&state,
			id,
			middle,
			middle,
			mac.CACurrentMediaTime(),
		)
		mac.resize_cover_tick(&state, mac.CACurrentMediaTime())
		mac.SLSGetWindowAlpha(
			state.connection,
			synced.surface.id,
			&repeated_retarget_alpha,
		)
		retarget_reuses_snapshot =
			state.resize_snapshots[synced.surface.id].initial ==
			original_snapshot
	}
	delete_key(&state.animations, id)
	w.frame = next
	cocoa = next
	cocoa.y = mac.CGDisplayBounds(mac.CGMainDisplayID()).h - next.y - next.h
	intrinsics.objc_send(nil, window, "setFrame:display:", cocoa, bool(true))
	mac.resize_cover_tick(&state, mac.CACurrentMediaTime())
	finished_with_geometry := len(state.resize_covers) == 0
	playback := run_resize_playback(&state, window, id)
	result := struct {
		initial_contrast, out_contrast, final_contrast: int,
		background: [3]f64,
		real_alpha: f32,
		hit_code: i32,
		hit, window, cover: u32,
		intermediate_alpha: f64,
		coordinated_cover_alpha: f32,
		live_contents, finished_with_geometry: bool,
		background_readback_skipped: bool,
		retarget_alpha, repeated_retarget_alpha: f32,
		retarget_reuses_snapshot: bool,
		playback: Resize_Playback,
		cleaned, passed: bool,
	} {
		initial_contrast,
		out_contrast,
		final_contrast,
		background,
		alpha,
		hit_code,
		hit,
		id,
		cover.surface.id,
		mid_alpha,
		sync_alpha,
		live_contents,
		finished_with_geometry,
		background_readback_skipped,
		retarget_alpha,
		repeated_retarget_alpha,
		retarget_reuses_snapshot,
		playback,
		manual_cleaned && finished_with_geometry,
		false,
	}
	result.passed =
		result.initial_contrast > 150 &&
		result.out_contrast < 10 &&
		result.final_contrast < 10 &&
		alpha > .99 &&
		hit_code == 0 &&
		hit == id &&
		mid_alpha < 1 &&
		sync_alpha > .49 &&
		sync_alpha < .51 &&
		live_contents &&
		finished_with_geometry &&
		background_readback_skipped &&
		retarget_alpha > .49 &&
		retarget_alpha < .51 &&
		repeated_retarget_alpha > .49 &&
		repeated_retarget_alpha < .51 &&
		retarget_reuses_snapshot &&
		result.cleaned &&
		playback.passed
	data, err := json.marshal(result); if err != nil {
		return false
	}; defer delete(data)
	if os.write_entire_file(path, data) != nil {
		return false
	}
	fmt.println(string(data))
	return result.passed
}

resize_image_contrast :: proc(image: mac.Ref) -> int {
	if image == nil {
		return 255
	}
	color := CGColorSpaceCreateDeviceRGB(); if color == nil {
		return 255
	}; defer CGColorSpaceRelease(color)
	pixels: [256 * 256 * 4]u8
	ctx := CGBitmapContextCreate(&pixels[0], 256, 256, 8, 256 * 4, color, 1)
	if ctx == nil {
		return 255
	}; defer mac.CGContextRelease(ctx)
	mac.CGContextDrawImage(ctx, {0, 0, 256, 256}, image)
	minimum, maximum := u8(255), u8(0)
	for y in 32 ..< 224 {
		for x in 32 ..< 224 {
			v := pixels[(y * 256 + x) * 4]
			minimum, maximum = min(minimum, v), max(maximum, v)
		}
	}
	return int(maximum) - int(minimum)
}

make_window :: proc(title: string) -> ^objc.Object {
	app := intrinsics.objc_send(
		^objc.Object,
		(^objc.Object)(objc.objc_lookUpClass("NSApplication")),
		"sharedApplication",
	)
	intrinsics.objc_send(bool, app, "setActivationPolicy:", int(1))
	intrinsics.objc_send(nil, app, "finishLaunching")
	window := intrinsics.objc_send(
		^objc.Object,
		(^objc.Object)(objc.objc_lookUpClass("NSWindow")),
		"alloc",
	)
	window = intrinsics.objc_send(
		^objc.Object,
		window,
		"initWithContentRect:styleMask:backing:defer:",
		e.Rect{220, 180, 440, 260},
		uint(15),
		uint(2),
		bool(false),
	)
	intrinsics.objc_send(nil, window, "setReleasedWhenClosed:", bool(false))
	text := mac.cf_string(title)
	intrinsics.objc_send(nil, window, "setTitle:", text); mac.CFRelease(text)
	intrinsics.objc_send(nil, window, "orderFrontRegardless")
	return window
}
main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln("Usage: shoji-resize-fade OUTPUT.json"); os.exit(2)
	}
	mac.NSApplicationLoad()
	pool := mac.pool_push(); defer mac.pool_pop(pool)
	if mac.SLSMainConnectionID() == 0 {
		fmt.eprintln("run in the logged-in macOS session"); os.exit(3)
	}
	if !run_resize_fade(os.args[1]) {
		os.exit(1)
	}
}
