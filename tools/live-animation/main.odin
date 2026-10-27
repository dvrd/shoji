package main

import e "../../src/engine"
import mac "../../src/macos"
import "base:intrinsics"
import "core:encoding/json"
import "core:fmt"
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
	SLSWindowIteratorGetAlpha :: proc(iterator: mac.Ref) -> f32 ---
	SLSTransactionCreate :: proc(cid: i32) -> mac.Ref ---
	SLSTransactionSetWindowSystemAlpha :: proc(transaction: mac.Ref, window: u32, alpha: f32) ---
	SLSTransactionCommit :: proc(transaction: mac.Ref, synchronous: i32) ---
}
make_window :: proc(title: string, regular: bool = false) -> ^objc.Object {
	app := intrinsics.objc_send(^objc.Object, Application, "sharedApplication")
	intrinsics.objc_send(bool, app, "setActivationPolicy:", regular ? int(0) : int(1))
	intrinsics.objc_send(nil, app, "finishLaunching")
	window := intrinsics.objc_send(^objc.Object, Window, "alloc")
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
	t := mac.cf_string(title)
	intrinsics.objc_send(nil, window, "setTitle:", (^objc.Object)(t));mac.CFRelease(t)
	intrinsics.objc_send(nil, window, "orderFrontRegardless")
	return window
}
print_alpha :: proc(id: u32, alpha, query_alpha: f32) {
	observation := struct {
		window:             u32,
		alpha, query_alpha: f32,
	}{id, alpha, query_alpha}
	data, err := json.marshal(observation)
	if err != nil {fmt.eprintln("could not encode alpha observation:", err);os.exit(3)}
	defer delete(data)
	fmt.println(string(data))
}
window_alpha :: proc(cid: i32, id: u32) {
	id := id
	number := mac.CFNumberCreate(nil, 3, &id);defer mac.CFRelease(number)
	array := mac.CFArrayCreate(nil, &number, 1, nil);defer mac.CFRelease(array)
	query := mac.SLSWindowQueryWindows(cid, array, 1)
	if query == nil {os.exit(3)};defer mac.CFRelease(query)
	iterator := mac.SLSWindowQueryResultCopyWindows(query)
	if iterator == nil {os.exit(3)};defer mac.CFRelease(iterator)
	if mac.SLSWindowIteratorGetCount(iterator) != 1 ||
	   !mac.SLSWindowIteratorAdvance(iterator) {os.exit(3)}
	alpha: f32
	mac.SLSGetWindowAlpha(cid, id, &alpha)
	print_alpha(id, alpha, SLSWindowIteratorGetAlpha(iterator))
}
main :: proc() {
	if len(os.args) < 2 {os.exit(2)}
	if os.args[1] == "motion-check" {if !lab_cli(false, os.args[2:]) {os.exit(1)}; return}
	if os.args[1] == "motion-report" {if !motion_report(os.args[2:]) {os.exit(1)}; return}
	if os.args[1] == "--self-test-output" {print_alpha(123, 1, 0.5);return}
	mac.NSApplicationLoad()
	pool := mac.pool_push();defer mac.pool_pop(pool)
	state: mac.State;state.connection = mac.SLSMainConnectionID()
	if state.connection ==
	   0 {fmt.eprintln("No WindowServer connection; run this test from a terminal in your logged-in macOS session");os.exit(3)}
	mode := os.args[1]
	if mode == "motion-lab" || mode == "motion-lab-paced" {if !lab_cli(true, os.args[2:], mode == "motion-lab-paced") {os.exit(1)}; return}
	if mode == "opening-order" {
		if !run_owned_opening_order() {os.exit(1)}
		return
	}
	if mode == "scroll-layout" || mode == "scroll-motion" {
		if !run_owned_scroll(state.connection, mode == "scroll-motion") {fmt.eprintln("FAIL: owned native scrolling layout"); os.exit(1)}
		return
	}
	if mode == "transaction-alpha-control" {
		window := make_window("Shoji disposable alpha control")
		if window == nil {os.exit(3)}
		defer intrinsics.objc_send(nil, window, "close")
		for alpha in ([4]f32{1, 0, 0.5, 1}) {
			for _ in 0 ..< 20 {mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, 0.01, true)}
			id := u32(intrinsics.objc_send(int, window, "windowNumber"))
			if id == 0 {os.exit(3)}
			transaction := SLSTransactionCreate(state.connection)
			if transaction == nil {os.exit(3)}
			SLSTransactionSetWindowSystemAlpha(transaction, id, alpha)
			SLSTransactionCommit(transaction, 0)
			mac.CFRelease(transaction)
			for _ in 0 ..< 20 {mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, 0.01, true)}
			fmt.eprintln("Requested system alpha:", alpha)
			window_alpha(state.connection, id)
		}
		return
	}
	if mode == "spaces" {
		e.manager_init(&state.manager, nil, nil);defer e.manager_destroy(&state.manager)
		mac.refresh_displays(&state)
		fmt.print(
			"{\"spaces\":",
			e.query(&state.manager, []string{"--spaces"}).text,
			",\"displays\":",
			e.query(&state.manager, []string{"--displays"}).text,
			"}\n",
		)
		return
	}
	if mode == "space-create-tracked" || mode == "space-focus" || mode == "space-destroy" {
		if len(os.args) != 3 {os.exit(2)}
		id, ok := strconv.parse_u64(os.args[2]);if !ok || id == 0 {os.exit(2)}
		if mode == "space-create-tracked" {
			fresh, err := mac.addition_create_tracked_space(id)
			if err != "" {fmt.eprintln(err);os.exit(1)}
			fmt.println(fresh);return
		}
		kind := mode == "space-focus" ? e.Action_Kind.Space_Focus : e.Action_Kind.Space_Destroy
		if err := mac.addition_action({kind = kind, space = id});
		   err != "" {fmt.eprintln(err);os.exit(1)}
		fmt.println("ok");return
	}
	if mode == "desktop" || mode == "floating-desktop" || mode == "size-fixture" {
		suffix := len(os.args) > 2 ? os.args[2] : fmt.tprintf("%d", mac.getpid())
		windows := [2]^objc.Object {
			make_window(fmt.tprintf("%s A %s", mode == "size-fixture" ? "Shoji size fixture" : "Shoji desktop test", suffix), mode == "desktop"),
			make_window(fmt.tprintf("%s B %s", mode == "size-fixture" ? "Shoji size fixture" : "Shoji desktop test", suffix), mode == "desktop"),
		}
		if mode == "size-fixture" {
			intrinsics.objc_send(nil, windows[0], "setMinSize:", mac.Size{700, 280})
			intrinsics.objc_send(nil, windows[0], "setMaxSize:", mac.Size{1200, 1000})
		}
		defer {for window in windows {if window !=
				   nil {intrinsics.objc_send(nil, window, "close")}}}
		ids: [2]u32
		for window, i in windows {
			if window == nil {fmt.eprintln("could not allocate desktop test window");os.exit(3)}
			ids[i] = u32(intrinsics.objc_send(int, window, "windowNumber"))
			if ids[i] == 0 {fmt.eprintln("desktop test window has no ID");os.exit(3)}
		}
		data, err := json.marshal(struct {
			pid:     i32,
			windows: [2]u32,
		}{mac.getpid(), ids})
		if err != nil {fmt.eprintln(err);os.exit(3)}
		fmt.println(string(data));delete(data)
		began := time.now()
		lifetime := mode == "floating-desktop" ? 60*time.Second : 120*time.Second
		for time.diff(began, time.now()) <
		    lifetime {mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, 0.016, true)}
		return
	}
	if mode == "query" {
		id, ok := strconv.parse_u64(os.args[2]);if !ok {os.exit(2)}
		window_alpha(state.connection, u32(id));return
	}
	if mode == "frame" {
		if len(os.args) != 3 {os.exit(2)}
		id, ok := strconv.parse_u64(os.args[2]);if !ok || id == 0 || id > 0xffffffff {os.exit(2)}
		frame: e.Rect
		if code := mac.SLSGetWindowBounds(state.connection, u32(id), &frame);
		   code != 0 {fmt.eprintln("could not query frame:", code);os.exit(3)}
		data, err := json.marshal(frame)
		if err != nil {fmt.eprintln(err);os.exit(3)}
		fmt.println(string(data));delete(data);return
	}
	if mode == "recover" {
		if err := mac.animation_journal_open(&state.animation_journal, os.args[2]);
		   err != "" {fmt.eprintln(err);os.exit(1)}
		defer mac.animation_journal_close(&state.animation_journal)
		mac.animation_recovery_tick(&state, time.now())
		if len(state.animation_journal.entries) !=
		   0 {fmt.eprintln("recovery is still pending");os.exit(1)}
		fmt.println("recovered");return
	}
	window := make_window(
		mode == "real" ? "Shoji crash recovery test" : "Shoji animation test proxy",
	)
	if window == nil {os.exit(3)}
	defer intrinsics.objc_send(nil, window, "close")
	for _ in 0 ..< 10 {mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, 0.02, true)}
	id := u32(intrinsics.objc_send(int, window, "windowNumber"))
	if id ==
	   0 {fmt.eprintf("fixture window has no WindowServer ID (visible=%v, connection=%d)\n", intrinsics.objc_send(bool, window, "isVisible"), state.connection);os.exit(3)}
	if mode == "proxy" {
		real_id, ok := strconv.parse_u64(os.args[2]);if !ok {os.exit(2)}
		if err := mac.animation_journal_open(&state.animation_journal, os.args[3]);
		   err != "" {fmt.eprintln(err);os.exit(1)}
		owner, real_ok := mac.animation_recovery_query_owner(state.connection, u32(real_id))
		proxy_owner, proxy_ok := mac.animation_recovery_query_owner(state.connection, id)
		if !real_ok || !proxy_ok {os.exit(3)}
		if err := mac.animation_journal_record(
			&state.animation_journal,
			{u32(real_id), id, owner, proxy_owner},
		); err != "" {fmt.eprintln(err);os.exit(1)}
		if err := mac.animation_swap({window = u32(real_id), id = id}, true);
		   err != "" {fmt.eprintln(err);os.exit(1)}
	}
	fmt.println(id)
	// Bound fixture lifetime even if the test driver is interrupted.
	began := time.now()
	for time.diff(began, time.now()) < 120 * time.Second {
		mac.CFRunLoopRunInMode(mac.kCFRunLoopDefaultMode, 0.016, true)
	}
}
