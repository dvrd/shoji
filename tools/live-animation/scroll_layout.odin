package main

import e "../../src/engine"
import mac "../../src/macos"
import "base:intrinsics"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import objc "core:sys/darwin/Foundation"
import "core:time"

Owned_Scroll :: struct {
	windows: map[u32]^objc.Object,
	height: f64,
}
owned_scroll_apply :: proc(user: rawptr, action: e.Action) -> string {
	owned := (^Owned_Scroll)(user)
	window := owned.windows[action.window]
	if window == nil {
		return "operation is outside the owned scroll fixture"
	}
	#partial switch action.kind {
	case .Frame:
		r := action.frame
		r.y = owned.height - r.y - r.h
		intrinsics.objc_send(nil, window, "setFrame:display:", r, bool(true))
	case .Focus, .Order:
		intrinsics.objc_send(nil, window, "orderFrontRegardless")
	case:
		return "operation is not supported by the owned scroll fixture"
	}
	return ""
}
owned_scroll_readback :: proc(m: ^e.Manager, cid: i32, step: string) -> bool {
	deadline := time.time_add(time.now(), time.Second)
	for time.diff(time.now(), deadline) > 0 {
		mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, 0.02, false)
		settled := true
		for id, w in m.windows {
			actual: e.Rect
			if mac.SLSGetWindowBounds(cid, id, &actual) != 0 ||
			   math.abs(actual.x - w.frame.x) > 1 ||
			   math.abs(actual.y - w.frame.y) > 1 ||
			   math.abs(actual.w - w.frame.w) > 1 ||
			   math.abs(actual.h - w.frame.h) > 1 {
				settled = false
			}
		}
		if settled {
			break
		}
	}
	ok := true
	for id, w in m.windows {
		actual: e.Rect
		code := mac.SLSGetWindowBounds(cid, id, &actual)
		matches :=
			code == 0 &&
			math.abs(actual.x - w.frame.x) <= 1 &&
			math.abs(actual.y - w.frame.y) <= 1 &&
			math.abs(actual.w - w.frame.w) <= 1 &&
			math.abs(actual.h - w.frame.h) <= 1
		data, err := json.marshal(struct {
			step: string,
			window: u32,
			expected, actual: e.Rect,
			matches: bool,
		}{step, id, w.frame, actual, matches})
		if err != nil {
			return false
		}
		fmt.println(string(data)); delete(data)
		ok = ok && matches
	}
	return ok
}
run_owned_scroll :: proc(cid: i32, animate: bool = false) -> bool {
	owned := Owned_Scroll {
		windows = make(map[u32]^objc.Object),
		height  = mac.CGDisplayBounds(mac.CGMainDisplayID()).h,
	}
	defer {
		for _, window in owned.windows {
			intrinsics.objc_send(nil, window, "close")
		}
		delete(owned.windows)
	}
	m: e.Manager
	e.manager_init(&m, owned_scroll_apply, &owned)
	defer e.manager_destroy(&m)
	s := e.add_space(&m, 1, 1, 1, {80, 80, 1280, 800})
	s.visible = true; m.active_space = 1
	s.view.gap = 16
	e.set_layout(&m, s, .Scroll)
	ids: [4]u32
	for i in 0 ..< len(ids) {
		window := make_window(fmt.tprintf("Shoji disposable scroll %d", i + 1))
		if window == nil {
			return false
		}
		id := u32(intrinsics.objc_send(int, window, "windowNumber"))
		if id == 0 {
			intrinsics.objc_send(nil, window, "close"); return false
		}
		owned.windows[id] = window; ids[i] = id
		e.add_window(
			&m,
			{
				id = id,
				pid = mac.getpid(),
				space = 1,
				display = 1,
				role = "AXWindow",
				subrole = "AXStandardWindow",
				opacity = 1,
			},
		)
		e.focus_window(&m, id)
		if e.flush(&m, s) != "" ||
		   !owned_scroll_readback(&m, cid, fmt.tprintf("open-%d", i + 1)) {
			return false
		}
	}
	commands := [][3]string {
		{"window", "--column-width", "ratio:0.6666666666666666"},
		{"window", "--move-column", "west"},
		{"window", "--consume-or-expel", "west"},
		{"window", "--column-display", "tabbed"},
		{"window", "--column-display", "normal"},
		{"window", "--row-height", "abs:250"},
		{"window", "--consume-or-expel", "east"},
		{"window", "--cycle-column-width", "next"},
	}
	for &command, i in commands {
		response := e.execute(&m, command[:])
		if response.failed {
			fmt.eprintln(response.text); return false
		}
		if !owned_scroll_readback(
			&m,
			cid,
			fmt.tprintf("command-%d-%s", i + 1, command[1]),
		) {
			return false
		}
	}
	if animate {
		e.set_layout(&m, s, .Float)
		e.set_layout(&m, s, .Scroll)
		e.focus_window(&m, ids[0]); e.flush(&m, s)
		if !owned_scroll_readback(&m, cid, "motion-baseline") {return false}
		m.scroll_animate, m.animation_duration = true, 0.5
		e.flush(&m, s)
		response := e.execute(&m, {"window", fmt.tprintf("%d", ids[2]), "--focus"})
		if response.failed {fmt.eprintln(response.text); return false}
		for at in ([6]f64{0, 0.04, 0.08, 0.12, 0.2, 0.4}) {
			if e.scroll_motion_tick(&m, at) != "" {return false}
			if !owned_scroll_readback(&m, cid, fmt.tprintf("camera-%.2f", at)) {return false}
			if at > 0 && math.abs(m.windows[ids[2]].frame.x - m.windows[ids[1]].frame.x - 632) > 0.001 {return false}
		}
		if s.view.scroll.motion.active {return false}
		fmt.println("PASS: owned shared-camera spring bounds and visible column spacing")
	}
	fmt.println(
		"PASS: owned native four-column placement, widths, column movement, consume/expel, rows and tabbed geometry",
	)
	return true
}
