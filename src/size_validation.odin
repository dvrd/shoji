package shoji

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"

// Owned-window size validation
// ------------------------------------------------------------------------

// A separate controller process using Shoji's existing signed executable. It
// creates no daemon/socket and rejects every window outside the named fixture.
validate_window_sizes :: proc(pid: i32, swipe: bool = false) -> int {
	if !AXIsProcessTrusted() {
		fmt.eprintln(
			"size validation requires Shoji's existing Accessibility access",
		); return 3
	}
	pool := pool_push(); defer pool_pop(pool)
	state: State
	state_init(&state); defer state_destroy(&state)
	state.validation_pid = pid
	if state.connection == 0 {
		fmt.eprintln("size validation requires the logged-in GUI session")
		return 3
	}
	app := AXUIElementCreateApplication(pid)
	if app == nil {
		return 3
	}
	state.applications[pid] = {
		element = app,
		name    = strings.clone("Shoji size fixture"),
	}
	array := attribute(app, "AXWindows")
	if array == nil {
		fmt.eprintln("size fixture has no accessible windows"); return 3
	}
	defer CFRelease(array)
	bounds := CGDisplayBounds(CGMainDisplayID())
	area := Rect{80, 80, min(1280, bounds.w - 160), min(800, bounds.h - 160)}
	if area.w < 1000 || area.h < 600 {
		fmt.eprintln("display is too small for this size fixture"); return 3
	}
	append(
		&state.manager.displays,
		Display {
			id = 1,
			index = 1,
			active_space = 1,
			frame = area,
			usable = area,
		},
	)
	s := add_space(&state.manager, 1, 1, 1, area)
	s.visible = true; s.view.gap = 16; state.manager.active_space = 1
	a, b := u32(0), u32(0)
	count := CFArrayGetCount(array)
	if count != 2 {
		fmt.eprintln("expected exactly two disposable size fixture windows")
		return 3
	}
	for i in 0 ..< count {
		element := CFArrayGetValueAtIndex(array, i)
		title := attribute_text(element, "AXTitle")
		if !strings.has_prefix(title, "Shoji size fixture ") {
			fmt.eprintln("refusing a non-fixture window"); return 3
		}
		id: u32
		if _AXUIElementGetWindow(element, &id) != 0 || id == 0 {
			return 3
		}
		owner, known := animation_recovery_query_owner(state.connection, id)
		actual_pid: i32
		if !known ||
		   SLSConnectionGetPID(owner, &actual_pid) != 0 ||
		   actual_pid != pid {
			return 3
		}
		state.windows[id] = CFRetain(element)
		frame: Rect
		if SLSGetWindowBounds(state.connection, id, &frame) != 0 {
			return 3
		}
		add_window(
			&state.manager,
			{
				id = id,
				pid = pid,
				app = "Shoji size fixture",
				title = title,
				frame = frame,
				space = 1,
				display = 1,
				role = "AXWindow",
				subrole = "AXStandardWindow",
				opacity = 1,
			},
		)
		if strings.has_prefix(title, "Shoji size fixture A") {
			a = id
		}
		if strings.has_prefix(title, "Shoji size fixture B") {
			b = id
		}
	}
	if a == 0 || b == 0 {
		return 3
	}
	if swipe { return validate_fixture_swipe(&state, s, a, b) }
	set_layout(&state.manager, s, .Scroll)
	focus_window(&state.manager, b)
	state.manager.scroll_time = size_validation_seconds()
	if response := execute(
		&state.manager,
		{"window", fmt.tprintf("%d", a), "--column-width", "abs:300"},
	); response.failed {
		fmt.eprintln(response.text); return 1
	}
	if !size_validation_settle(&state, 1.2) {
		return 1
	}
	actual_a, actual_b: Rect
	if SLSGetWindowBounds(state.connection, a, &actual_a) != 0 ||
	   SLSGetWindowBounds(state.connection, b, &actual_b) != 0 {
		return 1
	}
	aw := state.manager.windows[a]
	if !aw.size_feedback.width_valid ||
	   actual_a.w < 699 ||
	   math.abs(aw.frame.w - actual_a.w) > 1 ||
	   actual_b.x - actual_a.x - actual_a.w < 14 {
		size_validation_print("clamped-width-failed", &state, a, b)
		return 1
	}
	size_validation_print("clamped-width-adapted", &state, a, b)
	if find(s.view.root, a).column_size.value != 300 {
		return 1
	}
	state.manager.animation_duration = 0.5
	state.manager.scroll_time = size_validation_seconds()
	if response := execute(
		&state.manager,
		{"window", fmt.tprintf("%d", a), "--column-width", "abs:1000"},
	); response.failed {
		fmt.eprintln(response.text); return 1
	}
	intermediate := false
	focused_x := actual_b.x
	deadline := time.time_add(time.now(), time.Second)
	for time.diff(time.now(), deadline) > 0 {
		state.manager.scroll_time = size_validation_seconds()
		scroll_native_tick(&state, time.now())
		CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false)
		if SLSGetWindowBounds(state.connection, a, &actual_a) != 0 ||
		   SLSGetWindowBounds(state.connection, b, &actual_b) != 0 {
			return 1
		}
		if actual_a.w > 702 && actual_a.w < 998 {
			intermediate = true
		}
		size_validation_print("resize-sample", &state, a, b)
		if math.abs(actual_b.x - focused_x) > 2 {
			size_validation_print("focused-neighbor-moved", &state, a, b)
			return 1
		}
		frame_size_feedback_tick(&state, time.now())
		if !s.view.scroll.geometry_active && !s.view.scroll.motion.active {
			break
		}
	}
	if !intermediate || !size_validation_settle(&state, 0.4) {
		return 1
	}
	if SLSGetWindowBounds(state.connection, a, &actual_a) != 0 ||
	   math.abs(actual_a.w - 1000) > 2 {
		return 1
	}
	size_validation_print("coordinated-width-settled", &state, a, b)
	state.manager.animation_duration = 0
	if response := execute(
		&state.manager,
		{"window", fmt.tprintf("%d", a), "--column-width", "abs:1600"},
	); response.failed {
		return 1
	}
	if !size_validation_settle(&state, 0.6) {
		return 1
	}
	if SLSGetWindowBounds(state.connection, a, &actual_a) != 0 ||
	   math.abs(actual_a.w - 1200) > 1 ||
	   !aw.size_feedback.width_valid {
		return 1
	}
	if find(s.view.root, a).column_size.value != 1600 ||
	   math.abs(find(s.view.root, a).column_width - 1200) > 1 {
		return 1
	}
	size_validation_print("maximum-width-adapted", &state, a, b)
	if response := execute(
		&state.manager,
		{"window", fmt.tprintf("%d", a), "--stack", fmt.tprintf("%d", b)},
	); response.failed {
		return 1
	}
	if response := execute(
		&state.manager,
		{"window", fmt.tprintf("%d", a), "--row-height", "abs:200"},
	); response.failed {
		return 1
	}
	if !size_validation_settle(&state, 0.8) {
		return 1
	}
	if SLSGetWindowBounds(state.connection, a, &actual_a) != 0 ||
	   SLSGetWindowBounds(state.connection, b, &actual_b) != 0 {
		return 1
	}
	if !aw.size_feedback.height_valid ||
	   math.abs(actual_a.h - 280) > 1 ||
	   actual_b.y - actual_a.y - actual_a.h < 14 ||
	   aw.row_fixed != 200 {
		size_validation_print("row-height-adaptation-failed", &state, a, b)
		return 1
	}
	size_validation_print("row-height-adapted", &state, a, b)
	fmt.println(
		"PASS: foreign AX minimum/maximum width and row-height adaptation, retained requests and coordinated resize with stationary focused neighbor",
	)
	return 0
}
validate_fixture_swipe :: proc(state: ^State, s: ^Space, a, b: u32) -> int {
	m := &state.manager
	m.resize_fade = false
	set_layout(m, s, .Scroll)
	focus_window(m, a)
	m.animation_duration, m.scroll_animate = 0, true
	if flush(m, s) != "" || !size_validation_settle(state, .5) { return 1 }
	if execute(m, {"window", fmt.tprintf("%d", a), "--column-width", "abs:1000"}).failed || !size_validation_settle(state, .5) { return 1 }
	frame_a, frame_b: Rect
	if SLSGetWindowBounds(state.connection, a, &frame_a) != 0 || SLSGetWindowBounds(state.connection, b, &frame_b) != 0 { return 1 }
	base_gap := frame_b.x - frame_a.x - frame_a.w
	start_x := frame_a.x
	maximum_error: f64
	scroll_begin_pan(m, s)
	for i in 0 ..< 30 {
		m.scroll_time = size_validation_seconds()
		if err := scroll_gesture_pan(m, s.id, i < 5 ? 60 : 0); err != "" { fmt.eprintln(err); return 1 }
		if SLSGetWindowBounds(state.connection, a, &frame_a) != 0 || SLSGetWindowBounds(state.connection, b, &frame_b) != 0 { return 1 }
		gap := frame_b.x - frame_a.x - frame_a.w
		maximum_error = max(maximum_error, math.abs(gap - base_gap))
		fmt.printf("sample=%d a_x=%.1f gap=%.1f baseline=%.1f\n", i, frame_a.x, gap, base_gap)
		CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.016, false)
	}
	s.view.scroll.dragging = false
	fmt.printf("maximum transient native-bounds gap error: %.1f points\n", maximum_error)
	return maximum_error <= 16 && math.abs(frame_a.x - start_x) >= 100 ? 0 : 1
}
size_validation_seconds :: proc() -> f64 {
	return time.duration_seconds(time.diff(time.Time{}, time.now()))
}
size_validation_settle :: proc(state: ^State, seconds: f64) -> bool {
	deadline := time.time_add(time.now(), time.Duration(seconds * 1e9))
	for time.diff(time.now(), deadline) > 0 {
		CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false)
		state.manager.scroll_time = size_validation_seconds()
		scroll_native_tick(state, time.now())
		frame_size_feedback_tick(state, time.now())
		for s in state.manager.spaces {
			if flush(&state.manager, s) != "" {
				return false
			}
		}
	}
	return true
}
size_validation_print :: proc(step: string, state: ^State, a, b: u32) {
	for id in ([2]u32{a, b}) {
		actual: Rect
		code := SLSGetWindowBounds(state.connection, id, &actual)
		w := state.manager.windows[id]
		data, err := json.marshal(struct {
			at: f64,
			readback_status: i32,
			step: string,
			window: u32,
			actual, expected: Rect,
			requested_width: f64,
			adjusted: bool,
		} {
			size_validation_seconds(),
			code,
			step,
			id,
			actual,
			w.frame,
			w.size_intent.w,
			w.size_feedback.width_valid,
		})
		if err == nil {
			fmt.println(string(data)); delete(data)
		}
	}
}
