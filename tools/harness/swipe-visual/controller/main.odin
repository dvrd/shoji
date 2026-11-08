package main

import mac "../../../../src"
import dock "../../../../src/dock"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import native "../../../../src/native"

foreign import system "system:System"
foreign system { proc_pidpath :: proc "c" (pid: i32, buffer: rawptr, size: u32) -> i32 --- }

fail :: proc(message: string) { fmt.eprintln("visual motion controller:", message); os.exit(1) }
ignore_fixture_moves: bool
dock_fixture_moves: bool
skip_enhanced_probe: bool
Async_Job :: struct {target: mac.Motion_Target, element: mac.Ref}
Async_Fixture :: struct {
	mutex: sync.Mutex,
	jobs: [2]Async_Job,
	queue: mac.Motion_Coordinator,
	application: mac.Ref,
	stopping, failed: bool,
	applied, focused: int,
}
async_fixture: Async_Fixture
async_fixture_enabled: bool
async_focus_enabled: bool
async_worker :: proc(_: ^thread.Thread) {
	pool := mac.pool_push(); defer mac.pool_pop(pool)
	for {
		sync.mutex_lock(&async_fixture.mutex)
		request, available := mac.motion_take(&async_fixture.queue)
		element: mac.Ref
		if available {for entry in async_fixture.jobs {if entry.target == request.target {element = entry.element; break}}}
		stopping := async_fixture.stopping
		sync.mutex_unlock(&async_fixture.mutex)
		if element != nil {
			focus := request.kind == .Focus
			code: i32 = -1
			if focus {
				_ = mac.set_attribute(element, "AXMain", native.kCFBooleanTrue)
				raise := mac.cf_string("AXRaise")
				code = mac.AXUIElementPerformAction(element, raise)
				mac.CFRelease(raise)
				if code != 0 {
					actual := mac.attribute(async_fixture.application, "AXFocusedWindow")
					if actual != nil {id: u32; if mac._AXUIElementGetWindow(actual, &id) == 0 && id == request.target.window {code = 0}; mac.CFRelease(actual)}
				}
			} else {
				point := mac.Point{request.frame.x, request.frame.y}
				position := mac.AXValueCreate(1, &point)
				if position != nil {
					code = mac.native_frame_set(nil, element, "AXPosition", position)
					mac.CFRelease(position)
				}
			}
			sync.mutex_lock(&async_fixture.mutex)
			if focus {async_fixture.focused += 1} else {async_fixture.applied += 1}
			current := mac.motion_request_current(&async_fixture.queue, request)
			_ = mac.motion_complete(&async_fixture.queue, request, code == 0)
			if code != 0 && current {async_fixture.failed = true; mac.motion_invalidate_space(&async_fixture.queue, 1)}
			sync.mutex_unlock(&async_fixture.mutex)
		} else if stopping {break} else {time.sleep(2 * time.Millisecond)}
	}
}
Notification :: struct {at: f64, window: u32, bounds: mac.Rect, status: i32}
notifications: [dynamic]Notification
notification_connection: i32
notification_timing_only: bool
fixture_notification :: proc "c" (observer, element, notification, user: mac.Ref) {
	context = runtime.default_context()
	if notification_timing_only {return}
	id: u32
	if mac._AXUIElementGetWindow(element, &id) != 0 {return}
	frame: mac.Rect
	code := mac.SLSGetWindowBounds(notification_connection, id, &frame)
	if len(notifications) < 1024 {
		append(&notifications, Notification{mac.CACurrentMediaTime(), id, frame, code})
	}
}
requested_ring_frame :: proc(state: ^mac.State, id: u32) -> (mac.Rect, bool) {
	w := state.manager.windows[id]
	if w == nil {return {}, false}
	return w.frame, true
}
hybrid_ring_frame :: proc(state: ^mac.State, id: u32) -> (mac.Rect, bool) {
	observed, valid := mac.mouse_native_resize_frame(state, id)
	if !valid {return {}, false}
	w := state.manager.windows[id]
	if w == nil {return {}, false}
	requested := w.frame
	if math.abs(requested.x-observed.x) <= 4.5 && math.abs(requested.y-observed.y) <= 4.5 &&
	   math.abs(requested.w-observed.w) <= 1 && math.abs(requested.h-observed.h) <= 1 {
		return requested, true
	}
	return observed, true
}
fixture_backend :: proc(user: rawptr, action: mac.Action) -> string {
	state := (^mac.State)(user)
	if async_focus_enabled && action.kind == .Focus {
		sync.mutex_lock(&async_fixture.mutex)
		defer sync.mutex_unlock(&async_fixture.mutex)
		if async_fixture.failed {return "fixture worker failed"}
		for job in async_fixture.jobs {
			if job.target.window == action.window && mac.motion_queue_focus(&async_fixture.queue, job.target) {return ""}
		}
		return "focus is outside fixture worker"
	}
	if async_fixture_enabled && action.kind == .Frame {
		sync.mutex_lock(&async_fixture.mutex)
		defer sync.mutex_unlock(&async_fixture.mutex)
		if async_fixture.failed {return "fixture worker failed"}
		for job in async_fixture.jobs {
			if job.target.window == action.window && mac.motion_queue_position(&async_fixture.queue, job.target, action.frame) {return ""}
		}
		return "window is outside fixture worker"
	}
	if ignore_fixture_moves && action.kind == .Frame && action.window == state.manager.focused {
		// Simulate an application that silently ignores a requested move.
		return ""
	}
	if skip_enhanced_probe && action.kind == .Frame {
		w := state.manager.windows[action.window]
		if w == nil || w.pid != state.validation_pid {return "window is outside fixture"}
		element := state.windows[action.window]
		if element == nil {return "fixture accessibility window unavailable"}
		previous: mac.Rect
		if mac.SLSGetWindowBounds(state.connection, action.window, &previous) != 0 {return "fixture bounds unavailable"}
		start := time.tick_now()
		err := mac.write_accessibility_frame(element, action.frame, {nil, mac.native_frame_enhanced, mac.native_frame_set}, previous, .5)
		observed: mac.Rect
		code := mac.SLSGetWindowBounds(state.connection, action.window, &observed)
		if err != "" {code = -1}
		mac.motion_trace_record(&state.manager.motion_trace, {kind="native-frame",window=action.window,requested=action.frame,observed=observed,status=code,duration_ms=f64(time.tick_since(start))/1e6})
		return err
	}
	if dock_fixture_moves && action.kind == .Frame {
		w := state.manager.windows[action.window]
		if w == nil || w.pid != state.validation_pid {return "window is outside fixture"}
		p := dock.begin(.Window_Move)
		dock.pack(&p, action.window)
		dock.pack(&p, i32(math.round(action.frame.x)))
		dock.pack(&p, i32(math.round(action.frame.y)))
		start := time.tick_now()
		_, err := mac.addition_exchange(&p)
		frame: mac.Rect
		code := mac.SLSGetWindowBounds(state.connection, action.window, &frame)
		if err != "" {code = -1}
		mac.motion_trace_record(&state.manager.motion_trace, {kind="dock-frame",window=action.window,requested=action.frame,observed=frame,status=code,duration_ms=f64(time.tick_since(start))/1e6})
		return err
	}
	return mac.perform_native(user, action)
}
no_update_suppression :: proc(_: rawptr, _: i32, _: bool) -> i32 {return 0}
main :: proc() {
	if len(os.args) != 8 { fail("expected fixture PID, ready path, start path, observed|requested|hybrid, normal|ignored|dock, step, batch|unbatched") }
	if os.args[4] != "observed" && os.args[4] != "requested" && os.args[4] != "hybrid" {fail("invalid ring strategy")}
	if os.args[5] != "normal" && os.args[5] != "ignored" && os.args[5] != "dock" && os.args[5] != "position-only" && os.args[5] != "timeout" && os.args[5] != "keyboard" && os.args[5] != "keyboard-async" && os.args[5] != "keyboard-async-focus" && os.args[5] != "keyboard-async-rapid" && os.args[5] != "keyboard-stop" {fail("invalid fixture behavior")}
	step, step_valid := strconv.parse_f64(os.args[6]); if !step_valid || step < 1 || step > 16 {fail("invalid gesture step")}
	if os.args[7] != "batch" && os.args[7] != "unbatched" {fail("invalid presentation mode")}
	parsed, valid := strconv.parse_i64(os.args[1]); if !valid || parsed <= 0 || parsed > 0x7fffffff {fail("invalid PID")}
	pid := i32(parsed)
	path: [4096]u8
	if proc_pidpath(pid, &path[0], u32(len(path))) <= 0 || string(cstring(&path[0])) != "/private/tmp/shoji-swipe-visual" {fail("fixture executable mismatch")}
	if !mac.AXIsProcessTrusted() {fail("Accessibility permission unavailable")}
	pool := mac.pool_push(); defer mac.pool_pop(pool)
	state: mac.State; mac.state_init(&state); defer mac.state_destroy(&state)
	state.validation_pid = pid
	if state.connection == 0 {fail("WindowServer connection unavailable")}
	app := mac.AXUIElementCreateApplication(pid); if app == nil {fail("fixture app unavailable")}
	state.applications[pid] = {element = app, name = strings.clone("Shoji swipe visual fixture")}
	array := mac.attribute(app, "AXWindows"); if array == nil {fail("fixture has no windows")}; defer mac.CFRelease(array)
	if mac.CFArrayGetCount(array) != 2 {fail("expected exactly two fixture windows")}
	bounds := mac.CGDisplayBounds(mac.CGMainDisplayID())
	area := mac.Rect{80, 80, min(1280, bounds.w-160), min(800, bounds.h-160)}
	if area.w < 1000 || area.h < 600 {fail("display too small")}
	append(&state.manager.displays, mac.Display{id = 1, index = 1, active_space = 1, frame = area, usable = area})
	s := mac.add_space(&state.manager, 1, 1, 1, area); s.visible = true; s.view.gap = 16; state.manager.active_space = 1
	a,b: u32
	for i in 0..<2 {
		el := mac.CFArrayGetValueAtIndex(array, i)
		title := mac.attribute_text(el, "AXTitle")
		if title != "Shoji swipe visual fixture A" && title != "Shoji swipe visual fixture B" {fail("unexpected fixture title")}
		id: u32; if mac._AXUIElementGetWindow(el, &id) != 0 || id == 0 {fail("fixture window ID unavailable")}
		owner, known := mac.animation_recovery_query_owner(state.connection, id); actual: i32
		if !known || mac.SLSConnectionGetPID(owner, &actual) != 0 || actual != pid {fail("fixture owner mismatch")}
		state.windows[id] = mac.CFRetain(el)
		frame: mac.Rect; if mac.SLSGetWindowBounds(state.connection, id, &frame) != 0 {fail("fixture bounds unavailable")}
		mac.add_window(&state.manager, {id=id,pid=pid,app="Shoji swipe visual fixture",title=title,frame=frame,space=1,display=1,role="AXWindow",subrole="AXStandardWindow",opacity=1})
		if strings.has_suffix(title," A") {a=id} else {b=id}
	}
	if a == 0 || b == 0 {fail("fixture IDs invalid")}
	notifications = make([dynamic]Notification); defer delete(notifications)
	notification_connection = state.connection
	observer: mac.Ref
	if mac.AXObserverCreate(pid, fixture_notification, &observer) != 0 {fail("AX observer unavailable")}
	defer mac.CFRelease(observer)
	source := mac.AXObserverGetRunLoopSource(observer)
	mac.CFRunLoopAddSource(mac.CFRunLoopGetMain(), source, mac.kCFRunLoopDefaultMode)
	defer mac.CFRunLoopRemoveSource(mac.CFRunLoopGetMain(), source, mac.kCFRunLoopDefaultMode)
	for id in ([2]u32{a,b}) {
		name := mac.cf_string("AXMoved")
		code := mac.AXObserverAddNotification(observer, state.windows[id], name, nil)
		mac.CFRelease(name)
		if code != 0 {fail("AX move observer registration failed")}
	}
	m := &state.manager
	m.resize_fade = false; m.focus_ring.color = 0xff0000ff; m.focus_ring.width = 6
	mac.set_layout(m,s,.Scroll); mac.focus_window(m,a); m.animation_duration=0; m.scroll_animate=true
	if err := mac.flush(m,s); err != "" {fmt.eprintln("initial layout:", err); fail("initial layout failed")}
	if response := mac.execute(m,{"window",fmt.tprintf("%d",a),"--column-width","abs:800"}); response.failed {fmt.eprintln(response.text); fail("fixture width failed")}
	for _ in 0..<30 { mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, 0.01, false) }
	mac.focus_ring_tick(&state)
	rings: [dynamic]u32; defer delete(rings)
	for bar in state.focus_ring.bars {if bar.surface.id != 0 {append(&rings,bar.surface.id)}}
	if len(rings) < 4 {fail("actual focus ring not created")}
	ready := struct {pid:i32, a,b:u32, rings:[]u32}{pid,a,b,rings[:]}
	data, err := json.marshal(ready); if err != nil {fail("ready encoding failed")}; defer delete(data)
	if os.write_entire_file(os.args[2], data) != nil {fail("ready write failed")}
	deadline := time.time_add(time.now(), 10*time.Second)
	for !os.exists(os.args[3]) && time.diff(time.now(),deadline)>0 {mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode,0.02,false)}
	if !os.exists(os.args[3]) {fail("capture readiness timed out")}
	if os.args[4] == "requested" {state.focus_frame_probe = requested_ring_frame}
	if os.args[4] == "hybrid" {state.focus_frame_probe = hybrid_ring_frame}
	if os.args[7] == "unbatched" {state.frame_updates.set_enabled = no_update_suppression}
	if os.args[5] == "timeout" {
		if mac.AXUIElementSetMessagingTimeout(app, .025) != 0 {fail("fixture app timeout unavailable")}
		for id in ([2]u32{a,b}) {
			if mac.AXUIElementSetMessagingTimeout(state.windows[id], .025) != 0 {fail("fixture window timeout unavailable")}
		}
	}
	ignore_fixture_moves = os.args[5] == "ignored"
	dock_fixture_moves = os.args[5] == "dock"
	skip_enhanced_probe = os.args[5] == "position-only"
	m.backend = fixture_backend
	mac.motion_debug(m,{"motion","start"})
	keyboard := os.args[5] == "keyboard" || os.args[5] == "keyboard-async" || os.args[5] == "keyboard-async-focus" || os.args[5] == "keyboard-async-rapid" || os.args[5] == "keyboard-stop"
	notification_timing_only = keyboard
	worker: ^thread.Thread
	if os.args[5] == "keyboard-async" || os.args[5] == "keyboard-async-focus" || os.args[5] == "keyboard-async-rapid" || os.args[5] == "keyboard-stop" {
		async_fixture.jobs = {{target = mac.motion_register(&async_fixture.queue, a, 1), element = state.windows[a]}, {target = mac.motion_register(&async_fixture.queue, b, 1), element = state.windows[b]}}
		async_fixture.application = app
		if os.args[5] == "keyboard-async-focus" || os.args[5] == "keyboard-async-rapid" || os.args[5] == "keyboard-stop" {
			if err := mac.perform_native(&state, {kind = .Focus, window = a}); err != "" {fail("fixture activation failed")}
			async_focus_enabled = true
		}
		worker = thread.create(async_worker)
		if worker == nil {fail("fixture worker could not start")}
		thread.start(worker); async_fixture_enabled = true
	}
	if keyboard {m.animation_duration = 0.2} else {
		m.mouse.scroll = true
		state.mouse.scroll_tracking = true; state.mouse.scroll_begin = true; state.mouse.scroll.space = 1
	}
	start_x := m.windows[a].frame.x
	max_movement: f64
	for i in 0..<80 {
		if os.args[5] == "keyboard-stop" && i == 20 {
			sync.mutex_lock(&async_fixture.mutex)
			mac.motion_coordinator_stop(&async_fixture.queue)
			async_fixture.stopping = true
			sync.mutex_unlock(&async_fixture.mutex)
			break
		}
		now := time.now()
		if keyboard {
			step_count := os.args[5] == "keyboard-async-rapid" ? 3 : 20
			if i % step_count == 0 {
				m.scroll_time = time.duration_seconds(time.diff(time.Time{}, now))
				target := (i / step_count) % 2 == 0 ? b : a
				focus_start := time.tick_now()
				response := mac.execute(m, {"window", fmt.tprintf("%d", target), "--focus"})
				fmt.printf("focus %d duration_ms %.3f\n", i, f64(time.tick_since(focus_start))/1e6)
				if response.failed {fmt.eprintln(response.text); fail("keyboard focus failed")}
			}
		} else {
			state.mouse.scroll_last = time.duration_seconds(time.diff(time.Time{},now))
			state.mouse.scroll_delta = i < 25 ? step : i < 50 ? -step : 0
			if i == 79 {state.mouse.scroll_end = true}
		}
		frame_start := time.tick_now()
		mac.motion_frame_tick(&state,true,now,mac.CACurrentMediaTime())
		fmt.printf("tick %d duration_ms %.3f\n", i, f64(time.tick_since(frame_start))/1e6)
		wa, wb := m.windows[a], m.windows[b]
		max_movement = max(max_movement, abs(wa.frame.x-start_x))
		fmt.printf("sample %d uptime %.9f requested %.2f %.2f %.2f %.2f ring %.2f %.2f\n",i,mac.CACurrentMediaTime(),wa.frame.x,wa.frame.w,wb.frame.x,wb.frame.w,state.focus_ring.bars[2].plan.frame.x,state.focus_ring.bars[2].plan.frame.y)
		runloop_start := time.tick_now()
		mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode,0.016,false)
		fmt.printf("runloop %d duration_ms %.3f\n", i, f64(time.tick_since(runloop_start))/1e6)
	}
	if worker != nil {
		async_fixture_enabled, async_focus_enabled = false, false
		sync.mutex_lock(&async_fixture.mutex); async_fixture.stopping = true; sync.mutex_unlock(&async_fixture.mutex)
		thread.join(worker); thread.destroy(worker)
		if os.args[5] == "keyboard-stop" {
			if !mac.motion_coordinator_idle(&async_fixture.queue) {fail("fixture worker did not stop")}
			fmt.println("async stopped and drained")
		}
		defer mac.motion_coordinator_destroy(&async_fixture.queue)
		fmt.printf("async applied %d focus %d failed %v\n", async_fixture.applied, async_fixture.focused, async_fixture.failed)
		if async_fixture.failed {fail("fixture worker failed")}
		if os.args[5] == "keyboard-async-focus" || os.args[5] == "keyboard-async-rapid" {
			focused := mac.attribute(app, "AXFocusedWindow")
			if focused == nil {fail("fixture final focus unavailable")}
			id: u32; code := mac._AXUIElementGetWindow(focused, &id); mac.CFRelease(focused)
			fmt.printf("async focused requested %d observed %d\n", m.focused, id)
			if code != 0 || id != m.focused {fail("fixture worker did not reach final focus")}
		}
		if os.args[5] != "keyboard-stop" {for id in ([2]u32{a, b}) {
			observed: mac.Rect
			wanted := m.windows[id].frame
			for _ in 0..<50 {
				if mac.SLSGetWindowBounds(state.connection, id, &observed) != 0 {fail("fixture final bounds unavailable")}
				if math.abs(wanted.x-observed.x) <= 2 && math.abs(wanted.y-observed.y) <= 2 {break}
				time.sleep(20 * time.Millisecond)
			}
			fmt.printf("async final %d requested %.2f %.2f observed %.2f %.2f\n", id, wanted.x, wanted.y, observed.x, observed.y)
			if math.abs(wanted.x-observed.x) > 2 || math.abs(wanted.y-observed.y) > 2 {fail("fixture worker did not reach final position")}
		}}
	}
	mac.motion_debug(m,{"motion","stop"})
	trace := mac.motion_debug(m,{"motion","dump"}); fmt.println("TRACE:",trace.text)
	if events, err := json.marshal(notifications[:]); err == nil {fmt.println("NOTIFICATIONS:",string(events)); delete(events)}
	if max_movement < 30 {fail("no meaningful fixture swipe observed")}
}
