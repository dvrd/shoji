package main

import mac "../../../../src"
import "base:intrinsics"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import objc "core:sys/darwin/Foundation"
import "core:time"

@(objc_class = "NSApplication")
Application :: struct {
	using _: objc.Object,
}
@(objc_class = "NSWindow")
Window :: struct {
	using _: objc.Object,
}
foreign import sls "system:SkyLight.framework"
@(default_calling_convention = "c")
foreign sls {
	SLSGetWindowTransform :: proc(cid: i32, window: u32, transform: ^mac.Animation_Transform) -> i32 ---
	SLSWindowIteratorGetAlpha :: proc(iterator: mac.Ref) -> f32 ---
	SLSTransactionCreate :: proc(cid: i32) -> mac.Ref ---
	SLSTransactionSetWindowSystemAlpha :: proc(transaction: mac.Ref, window: u32, alpha: f32) ---
	SLSTransactionCommit :: proc(transaction: mac.Ref, synchronous: i32) ---
}
make_window :: proc(title: string, regular: bool = false) -> ^objc.Object {
	app := intrinsics.objc_send(^objc.Object, Application, "sharedApplication")
	intrinsics.objc_send(
		bool,
		app,
		"setActivationPolicy:",
		regular ? int(0) : int(1),
	)
	intrinsics.objc_send(nil, app, "finishLaunching")
	window := intrinsics.objc_send(^objc.Object, Window, "alloc")
	window = intrinsics.objc_send(
		^objc.Object,
		window,
		"initWithContentRect:styleMask:backing:defer:",
		mac.Rect{220, 180, 440, 260},
		uint(15),
		uint(2),
		bool(false),
	)
	intrinsics.objc_send(nil, window, "setReleasedWhenClosed:", bool(false))
	t := mac.cf_string(title)
	intrinsics.objc_send(nil, window, "setTitle:", (^objc.Object)(t))
	mac.CFRelease(t)
	intrinsics.objc_send(nil, window, "orderFrontRegardless")
	return window
}
print_alpha :: proc(id: u32, alpha, query_alpha: f32) {
	observation := struct {
		window: u32,
		alpha, query_alpha: f32,
	}{id, alpha, query_alpha}
	data, err := json.marshal(observation)
	if err != nil {
		fmt.eprintln("could not encode alpha observation:", err); os.exit(3)
	}
	defer delete(data)
	fmt.println(string(data))
}
window_alpha :: proc(cid: i32, id: u32) {
	id := id
	number := mac.CFNumberCreate(nil, 3, &id); defer mac.CFRelease(number)
	array := mac.CFArrayCreate(nil, &number, 1, nil)
	defer mac.CFRelease(array)
	query := mac.SLSWindowQueryWindows(cid, array, 1)
	if query == nil {
		os.exit(3)
	}; defer mac.CFRelease(query)
	iterator := mac.SLSWindowQueryResultCopyWindows(query)
	if iterator == nil {
		os.exit(3)
	}; defer mac.CFRelease(iterator)
	if mac.SLSWindowIteratorGetCount(iterator) != 1 ||
	   !mac.SLSWindowIteratorAdvance(iterator) {
		os.exit(3)
	}
	alpha: f32
	mac.SLSGetWindowAlpha(cid, id, &alpha)
	print_alpha(id, alpha, SLSWindowIteratorGetAlpha(iterator))
}
main :: proc() {
	if len(os.args) < 2 {
		os.exit(2)
	}
	if os.args[1] == "memory-check" {
		if !memory_check(os.args[2:]) {
			os.exit(1)
		}; return
	}
	if os.args[1] == "motion-check" {
		if !lab_cli(false, os.args[2:]) {
			os.exit(1)
		}; return
	}
	if os.args[1] == "motion-report" {
		if !motion_report(os.args[2:]) {
			os.exit(1)
		}; return
	}
	if os.args[1] == "--self-test-output" {
		print_alpha(123, 1, 0.5); return
	}
	mac.NSApplicationLoad()
	pool := mac.pool_push(); defer mac.pool_pop(pool)
	state: mac.State; state.connection = mac.SLSMainConnectionID()
	if state.connection == 0 {
		fmt.eprintln(
			"No WindowServer connection; run this test from a terminal in your logged-in macOS session",
		); os.exit(3)
	}
	mode := os.args[1]
	if mode == "focus-ring-check" {
		if !focus_ring_check(&state) {
			os.exit(1)
		}
		return
	}
	if mode == "motion-lab" || mode == "motion-lab-paced" {
		if !lab_cli(true, os.args[2:], mode == "motion-lab-paced") {
			os.exit(1)
		}; return
	}
	if mode == "opening-order" {
		if !run_owned_opening_order() {
			os.exit(1)
		}
		return
	}
	if mode == "scroll-layout" || mode == "scroll-motion" {
		if !run_owned_scroll(state.connection, mode == "scroll-motion") {
			fmt.eprintln("FAIL: owned native scrolling layout"); os.exit(1)
		}
		return
	}
	if mode == "transaction-alpha-control" {
		window := make_window("Shoji disposable alpha control")
		if window == nil {
			os.exit(3)
		}
		defer intrinsics.objc_send(nil, window, "close")
		for alpha in ([4]f32{1, 0, 0.5, 1}) {
			for _ in 0 ..< 20 { mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, 0.01, true) }
			id := u32(intrinsics.objc_send(int, window, "windowNumber"))
			if id == 0 {
				os.exit(3)
			}
			transaction := SLSTransactionCreate(state.connection)
			if transaction == nil {
				os.exit(3)
			}
			SLSTransactionSetWindowSystemAlpha(transaction, id, alpha)
			SLSTransactionCommit(transaction, 0)
			mac.CFRelease(transaction)
			for _ in 0 ..< 20 { mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, 0.01, true) }
			fmt.eprintln("Requested system alpha:", alpha)
			window_alpha(state.connection, id)
		}
		return
	}
	if mode == "spaces" {
		mac.manager_init(&state.manager, nil, nil)
		defer mac.manager_destroy(&state.manager)
		mac.refresh_displays(&state)
		fmt.print(
			"{\"spaces\":",
			mac.query(&state.manager, []string{"--spaces"}).text,
			",\"displays\":",
			mac.query(&state.manager, []string{"--displays"}).text,
			"}\n",
		)
		return
	}
	if mode == "space-create-tracked" ||
	   mode == "space-focus" ||
	   mode == "space-destroy" {
		if len(os.args) != 3 {
			os.exit(2)
		}
		id, ok := strconv.parse_u64(os.args[2]); if !ok || id == 0 {
			os.exit(2)
		}
		if mode == "space-create-tracked" {
			fresh, err := mac.addition_create_tracked_space(id)
			if err != "" {
				fmt.eprintln(err); os.exit(1)
			}
			fmt.println(fresh); return
		}
		kind :=
			mode == "space-focus" \
				? mac.Action_Kind.Space_Focus \
				: mac.Action_Kind.Space_Destroy
		if err := mac.addition_action({kind = kind, space = id}); err != "" {
			fmt.eprintln(err); os.exit(1)
		}
		fmt.println("ok"); return
	}
	if mode == "desktop" ||
	   mode == "floating-desktop" ||
	   mode == "size-fixture" {
		suffix :=
			len(os.args) > 2 ? os.args[2] : fmt.tprintf("%d", mac.getpid())
		windows := [2]^objc.Object {
			make_window(
				fmt.tprintf(
					"%s A %s",
					mode == "size-fixture" \
						? "Shoji size fixture" \
						: "Shoji desktop test",
					suffix,
				),
				mode == "desktop",
			),
			make_window(
				fmt.tprintf(
					"%s B %s",
					mode == "size-fixture" \
						? "Shoji size fixture" \
						: "Shoji desktop test",
					suffix,
				),
				mode == "desktop",
			),
		}
		if mode == "size-fixture" {
			intrinsics.objc_send(
				nil,
				windows[0],
				"setMinSize:",
				mac.Size{700, 280},
			)
			intrinsics.objc_send(
				nil,
				windows[0],
				"setMaxSize:",
				mac.Size{1200, 1000},
			)
		}
		defer {
			for window in windows {
				if window != nil {
					intrinsics.objc_send(nil, window, "close")
				}
			}
		}
		ids: [2]u32
		for window, i in windows {
			if window == nil {
				fmt.eprintln("could not allocate desktop test window")
				os.exit(3)
			}
			ids[i] = u32(intrinsics.objc_send(int, window, "windowNumber"))
			if ids[i] == 0 {
				fmt.eprintln("desktop test window has no ID"); os.exit(3)
			}
		}
		data, err := json.marshal(struct {
			pid: i32,
			windows: [2]u32,
		}{mac.getpid(), ids})
		if err != nil {
			fmt.eprintln(err); os.exit(3)
		}
		fmt.println(string(data)); delete(data)
		began := time.now()
		lifetime :=
			mode == "floating-desktop" ? 60 * time.Second : 120 * time.Second
		for time.diff(began, time.now()) <
		    lifetime { mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, 0.016, true) }
		return
	}
	if mode == "query" {
		id, ok := strconv.parse_u64(os.args[2]); if !ok {
			os.exit(2)
		}
		window_alpha(state.connection, u32(id)); return
	}
	if mode == "frame" {
		if len(os.args) != 3 {
			os.exit(2)
		}
		id, ok := strconv.parse_u64(os.args[2])
		if !ok || id == 0 || id > 0xffffffff {
			os.exit(2)
		}
		frame: mac.Rect
		if code := mac.SLSGetWindowBounds(state.connection, u32(id), &frame);
		   code != 0 {
			fmt.eprintln("could not query frame:", code); os.exit(3)
		}
		data, err := json.marshal(frame)
		if err != nil {
			fmt.eprintln(err); os.exit(3)
		}
		fmt.println(string(data)); delete(data); return
	}
	if mode == "recover" {
		if err := mac.animation_journal_open(
			&state.animation_journal,
			os.args[2],
		); err != "" {
			fmt.eprintln(err); os.exit(1)
		}
		defer mac.animation_journal_close(&state.animation_journal)
		mac.animation_recovery_tick(&state, time.now())
		if len(state.animation_journal.entries) != 0 {
			fmt.eprintln("recovery is still pending"); os.exit(1)
		}
		fmt.println("recovered"); return
	}
	window := make_window(
		mode == "real" \
			? "Shoji crash recovery test" \
			: "Shoji animation test proxy",
	)
	if window == nil {
		os.exit(3)
	}
	defer intrinsics.objc_send(nil, window, "close")
	for _ in 0 ..< 10 { mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, 0.02, true) }
	id := u32(intrinsics.objc_send(int, window, "windowNumber"))
	if id == 0 {
		fmt.eprintf(
			"fixture window has no WindowServer ID (visible=%v, connection=%d)\n",
			intrinsics.objc_send(bool, window, "isVisible"),
			state.connection,
		); os.exit(3)
	}
	if mode == "proxy" {
		real_id, ok := strconv.parse_u64(os.args[2]); if !ok {
			os.exit(2)
		}
		if err := mac.animation_journal_open(
			&state.animation_journal,
			os.args[3],
		); err != "" {
			fmt.eprintln(err); os.exit(1)
		}
		owner, real_ok := mac.animation_recovery_query_owner(
			state.connection,
			u32(real_id),
		)
		proxy_owner, proxy_ok := mac.animation_recovery_query_owner(
			state.connection,
			id,
		)
		if !real_ok || !proxy_ok {
			os.exit(3)
		}
		if err := mac.animation_journal_record(
			&state.animation_journal,
			{u32(real_id), id, owner, proxy_owner},
		); err != "" {
			fmt.eprintln(err); os.exit(1)
		}
		if err := mac.animation_swap({window = u32(real_id), id = id}, true);
		   err != "" {
			fmt.eprintln(err); os.exit(1)
		}
	}
	fmt.println(id)
	// Bound fixture lifetime even if the test driver is interrupted.
	began := time.now()
	for time.diff(began, time.now()) < 120 * time.Second {
		mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, 0.016, true)
	}
}

// Native malloc accounting complements Odin's tracking allocator. This mode
// queries Dock's process identity only; it never creates or rearranges windows.
Malloc_Statistics :: struct {
	blocks_in_use: u32,
	size_in_use, max_size_in_use, size_allocated: uint,
}
foreign import memory_system "system:System"
foreign memory_system {
	malloc_zone_statistics :: proc "c" (zone: rawptr, statistics: ^Malloc_Statistics) ---
}
Memory_Check :: struct {
	version: int,
	iterations: int,
	native_blocks_delta, native_bytes_delta: i64,
	passed: bool,
}
memory_statistics :: proc() -> Malloc_Statistics {
	value: Malloc_Statistics
	malloc_zone_statistics(nil, &value)
	return value
}
// This uses only fixture-owned WindowServer surfaces. It never captures,
// moves, focuses or changes the opacity of a foreign application window.
focus_ring_check :: proc(state: ^mac.State) -> bool {
	mac.manager_init(&state.manager); defer mac.manager_destroy(&state.manager)
	defer mac.callback_scratch_destroy(&state.callback_scratch)
	frame := mac.Rect{200, 200, 520, 300}
	background, err := mac.native_feedback_create(
		state,
		{window = 0, frame = frame, color = 0xff303030, solid = true},
	)
	if err != "" {
		fmt.eprintln(err); return false
	}
	defer mac.surface_destroy(state, background)
	defer mac.focus_ring_stop(state)
	s := mac.add_space(&state.manager, 1, 1, 1, {0, 0, 1720, 1100})
	s.visible = true; state.manager.active_space = 1
	mac.add_window(
		&state.manager,
		{
			id = background.id,
			pid = mac.getpid(),
			space = 1,
			display = 1,
			role = "AXWindow",
			subrole = "AXStandardWindow",
			frame = frame,
		},
	)
	state.manager.focused = background.id
	mac.focus_ring_tick(state)
	for bar in state.focus_ring.bars {
		if bar.surface.id != 0 {
			fmt.eprintln("single window unexpectedly has a focus ring")
			return false
		}
	}
	companion, companion_error := mac.native_feedback_create(
		state,
		{
			window = 0,
			frame = {780, 200, 200, 300},
			color = 0xff303030,
			solid = true,
		},
	)
	if companion_error != "" {
		fmt.eprintln(companion_error); return false
	}
	defer mac.surface_destroy(state, companion)
	mac.add_window(
		&state.manager,
		{
			id = companion.id,
			pid = mac.getpid(),
			space = 1,
			display = 1,
			role = "AXWindow",
			subrole = "AXStandardWindow",
			frame = companion.frame,
		},
	)
	state.manager.focused = background.id
	mac.focus_ring_tick(state)
	ids: [8]u32
	for bar, i in state.focus_ring.bars {
		ids[i] = bar.surface.id
		tags: u64
		if ids[i] == 0 ||
		   mac.SLSGetWindowTags(state.connection, ids[i], &tags, 64) != 0 ||
		   tags & (1 << 9) == 0 {
			fmt.eprintln(
				"focus ring creation/input-transparent tag check failed",
			); return false
		}
	}
	// Opening completion restores the owner's sublevel after the ring exists.
	// A focus notification can name the same owner with unchanged geometry.
	if mac.SLSSetWindowSubLevel(state.connection, background.id, 1) != 0 {
		return false
	}
	notification := mac.cf_string("AXFocusedWindowChanged")
	mac.observer_callback(nil, nil, notification, state)
	mac.CFRelease(notification)
	mac.focus_ring_tick(state)
	for bar in state.focus_ring.bars {
		if mac.SLSGetWindowSubLevel(state.connection, bar.surface.id) != 2 {
			fmt.eprintln(
				"FAIL: ring shares the owner's sublevel and can be covered by a same-window raise",
			); return false
		}
	}
	for i in 0 ..< 100 {
		// AppKit can raise an already-key window without another focus event.
		if mac.SLSOrderWindow(state.connection, background.id, 1, 0) != 0 {
			return false
		}
		w := state.manager.windows[background.id]
		w.frame = {
			200 + f64(i) / 2,
			200 + f64(i) / 3,
			520 + f64(i),
			300 + f64(i) / 2,
		}
		if mac.surface_update(state, background, w.frame) != "" {
			return false
		}
		mac.focus_ring_tick(state)
		for bar, j in state.focus_ring.bars {
			if mac.SLSGetWindowSubLevel(state.connection, bar.surface.id) <=
			   mac.SLSGetWindowSubLevel(state.connection, background.id) {
				fmt.eprintln(
					"same-owner raise covered the ring's ordering plane",
				); return false
			}
			actual: mac.Animation_Transform
			if bar.surface.id != ids[j] ||
			   SLSGetWindowTransform(state.connection, ids[j], &actual) != 0 {
				fmt.eprintln("focus ring lost a reused surface"); return false
			}
			r := bar.plan.frame
			a, d := bar.surface.frame.w / r.w, bar.surface.frame.h / r.h
			if abs(actual.a - a) > .001 ||
			   abs(actual.d - d) > .001 ||
			   abs(actual.tx + r.x * a) > .001 ||
			   abs(actual.ty + r.y * d) > .001 {
				fmt.eprintln("focus ring transform readback disagreed")
				return false
			}
		}
		mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, .002, false)
	}
	// Retained native windows close by ordering out, without being destroyed.
	// Their ring must disappear in the notification callback, before a tick.
	if mac.SLSOrderWindow(state.connection, background.id, 0, 0) != 0 {
		return false
	}
	closed_notification := mac.cf_string("AXFocusedWindowChanged")
	mac.observer_callback(nil, nil, closed_notification, state)
	mac.CFRelease(closed_notification)
	for bar in state.focus_ring.bars {
		if bar.surface.id != 0 {
			fmt.eprintln("focus ring survived native owner order-out")
			return false
		}
	}
	mac.remove_window(&state.manager, companion.id)
	mac.focus_ring_tick(state)
	mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, .01, false)
	for id in ids {
		bounds: mac.Rect
		if mac.SLSGetWindowBounds(state.connection, id, &bounds) == 0 {
			fmt.eprintln("focus ring surface survived cleanup"); return false
		}
	}
	fmt.println(
		"PASS: single-window suppression, eight reused input-transparent rounded focus surfaces, 800 transform readbacks and immediate order-out cleanup (owned surfaces only)",
	)
	return true
}

memory_check :: proc(args: []string) -> bool {
	if len(args) < 1 || len(args) > 2 {
		fmt.eprintln("memory-check OUTPUT.json [ITERATIONS]"); return false
	}
	iterations := 2000
	if len(args) == 2 {
		value, valid := strconv.parse_int(args[1])
		if !valid || value < 200 || value > 10000 {
			fmt.eprintln("memory-check iterations must be 200..10000")
			return false
		}
		iterations = value
	}
	mac.NSApplicationLoad()
	pool := mac.pool_push(); defer mac.pool_pop(pool)
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch); defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	if mac.workspace_poll_dock() == 0 {
		fmt.eprintln(
			"native memory check needs a running Dock in your logged-in macOS session",
		); return false
	}
	for _ in 0 ..< 200 {
		mac.workspace_poll_dock(); mac.scratch_reset(&scratch)
	}
	before := memory_statistics()
	for _ in 0 ..< iterations {
		mac.workspace_poll_dock(); mac.scratch_reset(&scratch)
	}
	after := memory_statistics()
	report := Memory_Check {
		version             = 1,
		iterations          = iterations,
		native_blocks_delta = i64(
			after.blocks_in_use,
		) - i64(before.blocks_in_use),
		native_bytes_delta  = i64(after.size_in_use) - i64(before.size_in_use),
	}
	// Allow bounded native cache variation, but fail sustained per-poll retention.
	report.passed =
		report.native_bytes_delta <= 16 * 1024 &&
		report.native_blocks_delta <= 128
	data, error := json.marshal(report)
	if error != nil {
		fmt.eprintln("could not encode native memory report"); return false
	}
	defer delete(data)
	if error := os.write_entire_file(args[0], data); error != nil {
		fmt.eprintln(error); return false
	}
	fmt.printf(
		"%s: %d native polls, live growth %d bytes / %d blocks; evidence: %s\n",
		report.passed ? "PASS" : "FAIL",
		iterations,
		report.native_bytes_delta,
		report.native_blocks_delta,
		args[0],
	)
	return report.passed
}
