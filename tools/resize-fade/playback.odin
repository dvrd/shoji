package main

import e "../../src/engine"
import mac "../../src/macos"
import "base:intrinsics"
import objc "core:sys/darwin/Foundation"
import "core:time"

Resize_Playback :: struct {
	samples, native_writes, retained_images: int,
	cleaned, passed: bool,
}
Resize_Playback_Context :: struct {
	window: ^objc.Object,
	writes: int,
}
resize_playback_apply :: proc(
	state: ^mac.State,
	id: u32,
	frame: e.Rect,
) -> string {
	r := (^Resize_Playback_Context)(state.event_user)
	previous: e.Rect
	if mac.SLSGetWindowBounds(state.connection, id, &previous) != 0 {
		return "fixture bounds unavailable"
	}
	mac.resize_cover_frame(
		state,
		id,
		frame,
		previous,
		mac.CACurrentMediaTime(),
	)
	cocoa := frame
	cocoa.y = mac.CGDisplayBounds(mac.CGMainDisplayID()).h - frame.y - frame.h
	intrinsics.objc_send(nil, r.window, "setFrame:display:", cocoa, bool(true))
	state.manager.windows[id].frame = frame
	r.writes += 1
	return ""
}

// Exercise the production display clock, BSP job sampling, presentation batch
// and cover renderer together. AppKit owns these disposable windows, so this
// verifies scheduling/presentation execution without touching foreign windows.
run_resize_playback :: proc(
	state: ^mac.State,
	window: ^objc.Object,
	id: u32,
) -> Resize_Playback {
	r := Resize_Playback_Context {
		window = window,
	}
	state.event_user = &r
	state.animation_backend = {
		create = mac.native_proxy_create,
		apply  = resize_playback_apply,
	}
	state.manager.animation_easing = .Out_Cubic
	defer mac.animation_stop(state)
	clock: mac.Display_Clock
	defer mac.display_clock_stop(&clock)
	mac.display_clock_prepare(&clock, mac.CGMainDisplayID(), true)
	base := state.manager.windows[id].frame
	target := base; target.w += 220
	mac.animation_start_at(
		state,
		{window = id, frame = target, duration = .3, live_resize = true},
		time.now(),
	)
	result: Resize_Playback
	last_image: mac.Ref
	start := mac.CACurrentMediaTime()
	retargets := 0
	at := [3]f64{.08, .15, .17}
	width := [3]f64{40, 260, 100}
	for mac.CACurrentMediaTime() - start < .9 {
		mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, .012, true)
		elapsed := mac.CACurrentMediaTime() - start
		if retargets < 3 && elapsed >= at[retargets] {
			target.w = base.w + width[retargets]
			mac.animation_start_at(
				state,
				{
					window = id,
					frame = target,
					duration = .3,
					live_resize = true,
				},
				time.now(),
			)
			retargets += 1
		}
		ready, sample, _ := mac.display_clock_take(&clock, time.now())
		mac.motion_frame_tick(state, ready, sample, mac.CACurrentMediaTime())
		if ready {
			result.samples += 1
		}
		if cover, exists := state.resize_covers[id]; exists {
			image := state.resize_snapshots[cover.surface.id].initial
			if image != last_image {
				result.retained_images += 1; last_image = image
			}
		}
		if retargets == 3 && len(state.animations) == 0 {
			break
		}
	}
	result.native_writes = r.writes
	result.cleaned =
		len(state.animations) == 0 &&
		len(state.resize_covers) == 0 &&
		state.frame_updates.depth == 0
	result.passed =
		result.cleaned &&
		result.samples >= 8 &&
		result.native_writes >= 8 &&
		result.retained_images == 1
	state.event_user = nil
	return result
}
