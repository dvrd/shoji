package main

import e "../../../../src/engine"
import mac "../../../../src/macos"
import "base:intrinsics"
import "core:fmt"
import objc "core:sys/darwin/Foundation"

owned_wait_hit :: proc(state: ^mac.State, anchor, expected: u32) -> bool {
	frame: e.Rect
	if mac.SLSGetWindowBounds(state.connection, anchor, &frame) != 0 {return false}
	point := mac.Point{frame.x + 40, frame.y + 80}
	for _ in 0 ..< 40 {
		local: mac.Point;hit: u32;owner: i32
		if mac.SLSFindWindowAndOwner(state.connection, 0, 1, 0, &point, &local, &hit, &owner) == 0 && hit == expected {return true}
		mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, 0.005, false)
	}
	return false
}

// Keep both fixture-owned surfaces alive for every comparison. No AX windows
// are exposed to the running daemon, and no user window enters this model.
run_owned_opening_order :: proc() -> bool {
	app := intrinsics.objc_send(^objc.Object, Application, "sharedApplication")
	intrinsics.objc_send(bool, app, "setActivationPolicy:", int(1))
	intrinsics.objc_send(nil, app, "finishLaunching")
	state: mac.State;mac.state_init(&state);defer mac.state_destroy(&state)
	state.validation_pid = mac.getpid();state.manager.default_layout = .BSP
	mac.refresh_displays(&state)
	s := e.space_by_id(&state.manager, state.manager.active_space)
	if s == nil {return false}
	surfaces: [2]mac.Owned_Surface
	defer {for surface in surfaces {mac.surface_destroy(&state, surface)}}
	ids: [2]u32
	for i in 0 ..< 2 {
		surface, err := mac.surface_create(&state, {200, 200, 400, 280}, 0, 0, 13, 1)
		if err != "" {fmt.eprintln(err);return false}
		surfaces[i] = surface;ids[i] = surface.id
		mac.CGContextSetRGBFillColor(surface.ctx, i == 0 ? 1 : 0, i == 1 ? 1 : 0, 0, 1)
		mac.CGContextFillRect(surface.ctx, {0, 0, 400, 280});mac.CGContextFlush(surface.ctx)
		if mac.surface_update(&state, surface, surface.frame) != "" {return false}
		// Attach only this owned surface to the already-active Space.
		if err := mac.addition_action({kind = .Space, window = surface.id, space = s.id}); err != "" {fmt.eprintln(err);return false}
		w := e.add_window(&state.manager, {id = surface.id, pid = mac.getpid(), space = s.id, display = s.display, role = "AXWindow", subrole = "AXStandardWindow", frame = surface.frame, layer = "normal"})
		if err := e.perform(&state.manager, {kind = .Layer, window = w.id, value = -1}); err != "" {fmt.eprintln(err);return false}
		if i == 0 {w.layer = "below"}
		if err := e.perform(&state.manager, {kind = .Order, window = w.id, value = 1}); err != "" {fmt.eprintln(err);return false}
	}
	if !owned_wait_hit(&state, ids[0], ids[1]) {fmt.eprintln("front-order positive control failed");return false}
	if err := e.perform(&state.manager, {kind = .Order, window = ids[1], value = -1}); err != "" {fmt.eprintln(err);return false}
	if !owned_wait_hit(&state, ids[0], ids[0]) {fmt.eprintln("new surface did not move behind existing surface");return false}
	if err := e.perform(&state.manager, {kind = .Order, window = ids[1], value = 1}); err != "" {fmt.eprintln(err);return false}
	if !owned_wait_hit(&state, ids[0], ids[1]) {fmt.eprintln("front restoration failed");return false}
	fmt.println("PASS: owned window lowers behind its peer and restores front order; verified by WindowServer hit-tests")
	return true
}
