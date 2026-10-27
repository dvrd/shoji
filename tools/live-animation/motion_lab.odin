package main

import e "../../src/engine"
import mac "../../src/macos"
import "base:intrinsics"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import objc "core:sys/darwin/Foundation"
import "core:time"

Lab_Event :: struct {
	at: f64,
	kind: enum {Focus, Width, Begin, Pan, End, Open, Close, Stack, Height},
	index: int,
	value: f64,
}
Lab_Frame :: struct {
	scenario: string,
	repetition: int,
	model_seconds, elapsed_ms, interval_ms, work_ms, max_bounds_error: f64,
	camera, velocity: f64,
	active: bool,
	worst_window: u32,
	invalid_readbacks: int,
	expected, observed: e.Rect,
}
Lab_Result :: struct {
	version: int,
	backend: string,
	slowdown: f64,
	frames: [dynamic]Lab_Frame,
	failed: bool,
	failure: string,
}
Lab_Backend :: struct {
	owned: Owned_Scroll,
	native: bool,
}
lab_apply :: proc(user: rawptr, action: e.Action) -> string {
	lab := (^Lab_Backend)(user)
	if lab.native {return owned_scroll_apply(&lab.owned, action)}
	return ""
}
lab_cli :: proc(native: bool, args: []string, paced: bool = false) -> bool {
	if len(args) < 1 || len(args) > 3 {
		fmt.eprintln("motion-lab|motion-check OUTPUT.json [SLOWDOWN=1] [REPEAT=1]"); return false
	}
	slowdown := 1.0
	repeat := i64(1)
	if len(args) >= 2 {
		value, ok := strconv.parse_f64(args[1])
		if !ok || math.is_nan(value) || math.is_inf(value) || value < 0.1 || value > 10 {return false}
		slowdown = value
	}
	if len(args) == 3 {
		value, ok := strconv.parse_i64(args[2])
		if !ok || value < 1 || value > 10 {return false}
		repeat = value
	}
	result := Lab_Result{version = 1, backend = native ? "owned AppKit; native bounds are not displayed frames" : "deterministic model; no native windows", slowdown = slowdown}
	if paced {result.backend = "owned AppKit display-paced; native bounds are not displayed frames"}
	defer delete(result.frames)
	defer delete(result.failure)
	for rep in 0 ..< int(repeat) {
		if !lab_run(&result, native, slowdown, rep, paced) {result.failed = true; break}
	}
	bytes, err := json.marshal(result)
	if err != nil {return false}
	defer delete(bytes)
	if os.write_entire_file(args[0], bytes) != nil {fmt.eprintln("could not write motion evidence"); return false}
	fmt.printf("%s (scenario execution/continuity only): %d motion samples; evidence: %s\n", result.failed ? "FAIL" : "PASS", len(result.frames), args[0])
	return !result.failed
}
lab_run :: proc(result: ^Lab_Result, native: bool, slowdown: f64, repetition: int, paced: bool = false) -> bool {
	backend := Lab_Backend{native = native, owned = {windows = make(map[u32]^objc.Object)}}
	defer delete(backend.owned.windows)
	if native {backend.owned.height = mac.CGDisplayBounds(mac.CGMainDisplayID()).h}
	defer {
		for _, window in backend.owned.windows {intrinsics.objc_send(nil, window, "close")}
	}
	m: e.Manager
	e.manager_init(&m, lab_apply, &backend)
	defer e.manager_destroy(&m)
	s := e.add_space(&m, 1, 1, 1, {80, 80, 1280, 800})
	s.visible = true; s.view.gap = 16; m.active_space = 1
	e.set_layout(&m, s, .Scroll)
	ids: [4]u32
	for i in 0 ..< 4 {
		ids[i] = u32(i + 1)
		if native {
			window := make_window(fmt.tprintf("Shoji motion fixture %d", i + 1))
			ids[i] = u32(intrinsics.objc_send(int, window, "windowNumber"))
			if ids[i] == 0 {return false}
			backend.owned.windows[ids[i]] = window
			intrinsics.objc_send(nil, window, "orderOut:", rawptr(nil))
		}
		if i < 3 {
			e.add_window(&m, {id = ids[i], pid = mac.getpid(), space = 1, display = 1, role = "AXWindow", subrole = "AXStandardWindow", opacity = 1})
			e.focus_window(&m, ids[i])
		}
	}
	e.focus_window(&m, ids[0])
	if e.flush(&m, s) != "" {return false}
	if native {
		for i in 0 ..< 3 {intrinsics.objc_send(nil, backend.owned.windows[ids[i]], "orderFrontRegardless")}
		mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, 0.05, false)
	}
	m.scroll_animate, m.animation_duration = true, 0.5
	if e.flush(&m, s) != "" {return false}
	events := []Lab_Event {
		{0.05, .Focus, 2, 0}, {0.15, .Focus, 0, 0}, {0.26, .Focus, 2, 0},
		{0.8, .Width, 1, 900}, {0.9, .Width, 1, 400}, {1.05, .Width, 1, 750}, {1.45, .Width, 1, 756},
		{1.6, .Begin, 0, 0}, {1.62, .Pan, 0, 100}, {1.66, .Pan, 0, 120}, {1.7, .Pan, 0, -60}, {1.74, .Pan, 0, -100}, {1.78, .End, 0, -400},
		{2.3, .Open, 3, 0}, {2.4, .Focus, 0, 0}, {2.5, .Close, 2, 0},
		{3.0, .Stack, 0, 0}, {3.1, .Height, 0, 250}, {3.2, .Height, 0, 400}, {3.65, .Height, 0, 405},
	}
	clock: mac.Display_Clock
	defer mac.display_clock_stop(&clock)
	if native && paced {mac.display_clock_prepare(&clock, mac.CGMainDisplayID(), true)}
	start := time.tick_now()
	last := start
	index := 0
	cid := native ? mac.SLSMainConnectionID() : 0
	for frame := 0; ; frame += 1 {
		now := time.tick_now()
		lead := 0.0
		if native && paced {
			wall := time.now()
			ready, target, _ := mac.display_clock_take(&clock, wall)
			if !ready {mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, .016, true); continue}
			lead = time.duration_seconds(time.diff(wall, target))
		}
		model := native ? (time.duration_seconds(time.tick_diff(start, now)) + lead) / slowdown : f64(frame) / 120
		if model > 4.1 {break}
		interval := native ? f64(time.tick_diff(last, now)) / 1e6 : 1000.0 / 120
		last = now
		m.scroll_time = model
		if err := e.scroll_motion_tick(&m, model); err != "" {fmt.eprintln(err); return false}
		for index < len(events) && events[index].at <= model {
			ev := events[index]; index += 1
			id := fmt.tprintf("%d", ids[ev.index])
			before: map[u32]e.Rect
			if ev.kind == .Focus || ev.kind == .Width || ev.kind == .Height {
				before = make(map[u32]e.Rect)
				for id, w in m.windows {before[id] = w.frame}
			}
			err: string
			switch ev.kind {
			case .Focus: err = e.execute(&m, {"window", id, "--focus"}).text
			case .Width: err = e.execute(&m, {"window", id, "--column-width", fmt.tprintf("abs:%.0f", ev.value)}).text
			case .Height: err = e.execute(&m, {"window", id, "--row-height", fmt.tprintf("abs:%.0f", ev.value)}).text
			case .Stack: err = e.execute(&m, {"window", id, "--stack", fmt.tprintf("%d", ids[1])}).text
			case .Begin: e.scroll_begin_pan(&m, s)
			case .Pan: err = e.scroll_gesture_pan(&m, s.id, ev.value)
			case .End: err = e.scroll_finish_pan(&m, s, ev.value)
			case .Open:
				e.add_window(&m, {id = ids[ev.index], pid = mac.getpid(), space = 1, display = 1, role = "AXWindow", subrole = "AXStandardWindow", opacity = 1})
				e.focus_window(&m, ids[ev.index]); err = e.flush(&m, s)
				if native {intrinsics.objc_send(nil, backend.owned.windows[ids[ev.index]], "orderFrontRegardless")}
			case .Close:
				e.remove_window(&m, ids[ev.index])
				if native {intrinsics.objc_send(nil, backend.owned.windows[ids[ev.index]], "orderOut:", rawptr(nil))}
				err = e.flush(&m, s)
			}
			if err != "" {delete(before); result.failure = fmt.aprintf("scenario %.4f: %s", model, err); fmt.eprintln(result.failure); return false}
			for id, prior in before {
				current := m.windows[id].frame
				allowed := prior
				f := &m.windows[id].scroll_frame
				if f.snap_width && math.abs(current.w-prior.w) <= 10 {allowed.w = current.w}
				if f.snap_height && math.abs(current.h-prior.h) <= 10 {allowed.h = current.h}
				tolerance := allowed != prior ? f64(1.5) : f64(.001)
				if !e.scroll_rect_near(allowed, current, tolerance) {delete(before); result.failure = fmt.aprintf("frame jumped while retargeting at %.4f window %d: %v -> %v", model, id, prior, m.windows[id].frame); fmt.eprintln(result.failure); return false}
			}
			delete(before)
		}
		max_error := 0.0
		invalid_readbacks := 0
		worst_window: u32
		expected, observed: e.Rect
		for id, w in m.windows {
			if math.is_nan(w.frame.x) || math.is_nan(w.frame.w) || w.frame.w <= 0 || w.frame.h <= 0 {return false}
			if native {
				actual: e.Rect
				if code := mac.SLSGetWindowBounds(cid, id, &actual); code != 0 {result.failure = fmt.aprintf("bounds read failed: window %d code %d", id, code); return false}
				if actual.w <= 0 || actual.h <= 0 || math.is_nan(actual.w) || math.is_nan(actual.h) {invalid_readbacks += 1; continue}
				error := max(math.abs(actual.x - w.frame.x), math.abs(actual.y - w.frame.y), math.abs(actual.w - w.frame.w), math.abs(actual.h - w.frame.h))
				if error > max_error {max_error, worst_window, expected, observed = error, id, w.frame, actual}
			}
		}
		scenario := model < 0.8 ? "focus-reversal" : model < 1.6 ? "resize-retarget" : model < 2.3 ? "gesture-reversal" : model < 3 ? "insert-close" : "row-resize"
		if model >= 1.45 && model < 1.6 || model >= 3.65 {scenario = "small-resize"}
		append(&result.frames, Lab_Frame{scenario, repetition, model, native ? time.duration_seconds(time.tick_diff(start, now))*1000 : model*1000, interval, native ? f64(time.tick_since(now))/1e6 : 0, max_error, s.view.scroll.motion.position, s.view.scroll.motion.velocity, s.view.scroll.motion.active || s.view.scroll.geometry_active, worst_window, invalid_readbacks, expected, observed})
		if native {mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, 0.016, true)}
	}
	return index == len(events) && !s.view.scroll.motion.active && !s.view.scroll.geometry_active
}

// Nearest-rank percentiles describe sampled call/tick timing, not monitor FPS.
lab_percentile :: proc(values: []f64, fraction: f64) -> f64 {
	if len(values) == 0 {return 0}
	slice.sort(values)
	return values[clamp(int(math.ceil(fraction * f64(len(values)))) - 1, 0, len(values)-1)]
}
motion_report :: proc(args: []string) -> bool {
	if len(args) != 1 {return false}
	bytes, ok := os.read_entire_file(args[0], context.allocator); if ok != nil {return false}; defer delete(bytes)
	trace: e.Motion_Export
	if json.unmarshal(bytes, &trace, allocator = context.temp_allocator) != nil || trace.version != 1 {return false}
	ticks, calls, delays: [dynamic]f64
	defer delete(ticks); defer delete(calls); defer delete(delays)
	last_sample, last_input := -1.0, -1.0
	failures := 0
	for event in trace.events {
		switch event.kind {
		case "input": last_input = event.at_ms
		case "input-consume":
			if last_input >= 0 {append(&delays, max(0, event.at_ms-last_input)); last_input = -1}
		case "sample", "gesture-sample":
			if last_sample >= 0 {append(&ticks, event.at_ms-last_sample)}
			last_sample = event.at_ms
		case "native-frame": append(&calls, event.duration_ms); if event.status != 0 {failures += 1}
		}
	}
	fmt.printf("events=%d full=%t expired=%t\n", len(trace.events), trace.full, trace.expired)
	fmt.printf("sample completion intervals (includes idle gaps): n=%d p50=%.3f p95=%.3f p99=%.3f ms\n", len(ticks), lab_percentile(ticks[:], .5), lab_percentile(ticks[:], .95), lab_percentile(ticks[:], .99))
	fmt.printf("native frame calls: n=%d p50=%.3f p95=%.3f p99=%.3f ms failures=%d\n", len(calls), lab_percentile(calls[:], .5), lab_percentile(calls[:], .95), lab_percentile(calls[:], .99), failures)
	fmt.printf("latest input callback to consume: n=%d p50=%.3f p95=%.3f ms\n", len(delays), lab_percentile(delays[:], .5), lab_percentile(delays[:], .95))
	fmt.println("These are CPU/native-readback observations, not displayed FPS or input-to-photon latency.")
	return true
}
