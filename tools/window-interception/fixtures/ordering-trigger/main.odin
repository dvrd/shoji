package main

import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:time"
import "core:sys/posix"
import objc "core:sys/darwin/Foundation"
import dockwire "../../../../src/dock"

Object :: ^objc.Object
Rect :: struct {x, y, w, h: f64}
Point :: struct {x, y: f64}

// Pump the run loop so Core Animation commits the window surface; without it
// the window never becomes onscreen in a process that only sleeps.
pump :: proc(seconds: f64) {
	run_loop := intrinsics.objc_send(Object, (^objc.Object)(objc.objc_lookUpClass("NSRunLoop")), "currentRunLoop")
	deadline := intrinsics.objc_send(
		Object,
		(^objc.Object)(objc.objc_lookUpClass("NSDate")),
		"dateWithTimeIntervalSinceNow:",
		seconds,
	)
	intrinsics.objc_send(bool, run_loop, "runUntilDate:", deadline)
}

foreign import cocoa "system:Cocoa.framework"
foreign import sls "system:SkyLight.framework"
foreign cocoa {NSApplicationLoad :: proc "c" () -> bool ---}
foreign sls {
	SLSMainConnectionID :: proc "c" () -> i32 ---
	SLSMoveWindow :: proc "c" (connection: i32, window: u32, point: ^Point) -> i32 ---
	SLSGetWindowBounds :: proc "c" (connection: i32, window: u32, bounds: ^Rect) -> i32 ---
	SLSOrderWindow :: proc "c" (connection: i32, window, order, relative: u32) -> i32 ---
	SLSGetActiveSpace :: proc "c" (cid: i32) -> u64 ---
	SLSSpaceCreate :: proc "c" (cid: i32, flags: u64, type: u64) -> u64 ---
	SLSSpaceDestroy :: proc "c" (cid: i32, space: u64) -> i32 ---
	SLSTransactionCreate :: proc "c" (cid: i32) -> rawptr ---
	SLSTransactionOrderWindow :: proc "c" (txn: rawptr, window, order, relative: u32) -> i32 ---
	SLSTransactionAddWindowToSpace :: proc "c" (txn: rawptr, window: u32, space: u64) -> i32 ---
	SLSTransactionRemoveWindowFromSpace :: proc "c" (txn: rawptr, window: u32, space: u64) -> i32 ---
	SLSTransactionCommit :: proc "c" (txn: rawptr, flags: i32) -> i32 ---
	SLSMoveWindowsToManagedSpace :: proc "c" (cid: i32, windows: rawptr, space: u64) ---
	CGSNewRegionWithRect :: proc "c" (rect: ^Rect, region: ^rawptr) -> i32 ---
	SLSNewWindowWithOpaqueShapeAndContext :: proc "c" (cid, type: i32, region, empty: rawptr, flags: i32, tags: ^u64, x, y: f32, tag_size: i32, window: ^u32, ctx: rawptr) -> i32 ---
	SLSSetWindowAlpha :: proc "c" (cid: i32, window: u32, alpha: f32) -> i32 ---
	SLSReleaseWindow :: proc "c" (cid: i32, window: u32) -> i32 ---
}

foreign import cg "system:CoreGraphics.framework"
foreign cg {CGRegionCreateEmptyRegion :: proc "c" () -> rawptr ---}

// C1 probe: a marker made the way Shoji makes its surfaces (motion.odin
// surface_create): raw SkyLight window, alpha 0, ordered in with
// SLSOrderWindow after DELAY ms, then out and released.
sls_marker :: proc(delay_ms: int) -> int {
	cid := SLSMainConnectionID()
	if cid == 0 {fmt.eprintln("FAIL: SLS connection"); return 1}
	frame := Rect{0, 0, 1, 1}
	region: rawptr
	if CGSNewRegionWithRect(&frame, &region) != 0 || region == nil {return 1}
	empty := CGRegionCreateEmptyRegion()
	tags: u64
	id: u32
	if SLSNewWindowWithOpaqueShapeAndContext(cid, 2, region, empty, 0, &tags, 0, 0, 64, &id, nil) != 0 || id == 0 {
		fmt.eprintln("FAIL: SLSNewWindow")
		return 1
	}
	SLSSetWindowAlpha(cid, id, 0)
	fmt.printf("window=%d connection=%d\n", id, cid)
	time.sleep(time.Duration(delay_ms) * time.Millisecond)
	start := time.now()
	code := SLSOrderWindow(cid, id, 1, 0)
	fmt.printf("order_in=%d call_ms=%.3f\n", code, time.duration_milliseconds(time.since(start)))
	time.sleep(100 * time.Millisecond)
	SLSOrderWindow(cid, id, 0, 0)
	SLSReleaseWindow(cid, id)
	return code == 0 ? 0 : 1
}

foreign import cf "system:CoreFoundation.framework"
foreign cf {
	CFNumberCreate :: proc "c" (allocator: rawptr, type: i32, value: rawptr) -> rawptr ---
	CFArrayCreate :: proc "c" (allocator: rawptr, values: ^rawptr, count: int, callbacks: rawptr) -> rawptr ---
	CFRelease :: proc "c" (object: rawptr) ---
	kCFTypeArrayCallBacks: u8
	kCFBooleanTrue: rawptr
	CFStringCreateWithCString :: proc "c" (allocator: rawptr, text: cstring, encoding: u32) -> rawptr ---
	CFArrayGetCount :: proc "c" (array: rawptr) -> int ---
	CFArrayGetValueAtIndex :: proc "c" (array: rawptr, index: int) -> rawptr ---
}

foreign import hiservices "system:ApplicationServices.framework"
foreign hiservices {
	AXIsProcessTrusted :: proc "c" () -> bool ---
	AXUIElementCreateApplication :: proc "c" (pid: i32) -> rawptr ---
	AXUIElementCopyAttributeValue :: proc "c" (element, attribute: rawptr, value: ^rawptr) -> i32 ---
	AXUIElementSetAttributeValue :: proc "c" (element, attribute, value: rawptr) -> i32 ---
	AXUIElementPerformAction :: proc "c" (element, action: rawptr) -> i32 ---
	_AXUIElementGetWindow :: proc "c" (element: rawptr, window: ^u32) -> i32 ---
}

cf_str :: proc(text: cstring) -> rawptr {return CFStringCreateWithCString(nil, text, 0x08000100)}

// C2 probe: Shoji's .Focus sequence from a third process (backend.odin
// perform_native .Focus): activate the owner app, AXMain, AXRaise.
ax_focus :: proc(pid: i32, wid: u32) -> int {
	fmt.printf("ax_trusted=%v\n", AXIsProcessTrusted())
	app := intrinsics.objc_send(Object, (^objc.Object)(objc.objc_lookUpClass("NSRunningApplication")), "runningApplicationWithProcessIdentifier:", pid)
	activated := app != nil && intrinsics.objc_send(bool, app, "activateWithOptions:", uint(2))
	element := AXUIElementCreateApplication(pid)
	windows_key := cf_str("AXWindows")
	windows: rawptr
	code := AXUIElementCopyAttributeValue(element, windows_key, &windows)
	if code != 0 || windows == nil {
		fmt.printf("ax_focus: activated=%v AXWindows=%d\n", activated, code)
		return 1
	}
	target: rawptr
	for index in 0 ..< CFArrayGetCount(windows) {
		candidate := CFArrayGetValueAtIndex(windows, index)
		id: u32
		if _AXUIElementGetWindow(candidate, &id) == 0 && id == wid {target = candidate; break}
	}
	if target == nil {
		fmt.printf("ax_focus: activated=%v window %d not in AXWindows\n", activated, wid)
		return 1
	}
	main_code := AXUIElementSetAttributeValue(target, cf_str("AXMain"), kCFBooleanTrue)
	raise_code := AXUIElementPerformAction(target, cf_str("AXRaise"))
	fmt.printf("ax_focus: activated=%v main=%d raise=%d\n", activated, main_code, raise_code)
	return raise_code == 0 ? 0 : 1
}

// C2 probe: Shoji's .Order (Dock payload Window_Order, transaction commit).
dock_order :: proc(wid: u32) -> int {
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {return 1}
	defer posix.close(fd)
	address: posix.sockaddr_un
	address.sun_family = .UNIX
	path := fmt.tprintf("/tmp/shoji-sa_%d.socket", posix.getuid())
	copy(address.sun_path[:], path)
	if posix.connect(fd, (^posix.sockaddr)(&address), size_of(address)) != .OK {
		fmt.println("dock_order: payload socket unavailable")
		return 1
	}
	packet := dockwire.begin(.Window_Order)
	dockwire.pack(&packet, wid)
	dockwire.pack(&packet, i32(1))
	dockwire.pack(&packet, u32(0))
	bytes := dockwire.finish(&packet)
	if posix.write(fd, raw_data(bytes), uint(len(bytes))) != len(bytes) {return 1}
	status: [1]u8
	n := posix.read(fd, &status[0], 1)
	fmt.printf("dock_order: read=%d status=%d\n", n, status[0])
	return n == 1 && status[0] == 0 ? 0 : 1
}

main :: proc() {
	no_hold := false
	txn_mode := false
	txn_space := false
	space_move := false
	move_space_id: u64
	delay_ms := 500
	visible_ms := 1200
	owner_move := false
	managed_move := false
	report_frame := false
	if len(os.args) == 4 && os.args[1] == "--ax-focus" {
		pid, pok := strconv.parse_i64(os.args[2])
		wid, wok := strconv.parse_u64(os.args[3])
		if !pok || !wok {os.exit(2)}
		os.exit(ax_focus(i32(pid), u32(wid)))
	}
	if len(os.args) == 3 && os.args[1] == "--sls-marker" {
		ms, ok := strconv.parse_u64(os.args[2])
		if !ok || ms > 60_000 {os.exit(2)}
		os.exit(sls_marker(int(ms)))
	}
	if len(os.args) == 3 && os.args[1] == "--dock-order" {
		wid, wok := strconv.parse_u64(os.args[2])
		if !wok {os.exit(2)}
		os.exit(dock_order(u32(wid)))
	}
	for i := 1; i < len(os.args); i += 1 {
		arg := os.args[i]
		if arg == "--no-hold" {no_hold = true}
		if arg == "--owner-move" {owner_move = true}
		// C4: the Dock payload's Window_To_Space path (SLSMoveWindowsToManagedSpace).
		if arg == "--managed-move" {managed_move = true}
		if arg == "--report-frame" {report_frame = true}
		if arg == "--txn" {txn_mode = true}
		if arg == "--txn-space" {txn_mode = true; txn_space = true}
		if arg == "--space-move" && i + 1 < len(os.args) {
			i += 1
			space_id, ok := strconv.parse_u64(os.args[i])
			if !ok || space_id == 0 {
				fmt.eprintln("--space-move requires a decimal space id")
				os.exit(2)
			}
			space_move = true
			move_space_id = space_id
		}
		if arg == "--delay" && i + 1 < len(os.args) {
			i += 1
			ms, ok := strconv.parse_u64(os.args[i])
			if ok && ms > 0 && ms <= 60_000 {delay_ms = int(ms)}
		}
		if arg == "--visible-ms" && i + 1 < len(os.args) {
			i += 1
			ms, ok := strconv.parse_u64(os.args[i])
			if ok && ms > 0 && ms <= 60_000 {visible_ms = int(ms)}
		}
	}	if !NSApplicationLoad() {
		fmt.eprintln("FAIL: AppKit initialization")
		os.exit(1)
	}
	pool := intrinsics.objc_send(Object, (^objc.Object)(objc.objc_lookUpClass("NSAutoreleasePool")), "new")
	app := intrinsics.objc_send(Object, (^objc.Object)(objc.objc_lookUpClass("NSApplication")), "sharedApplication")
	intrinsics.objc_send(bool, app, "setActivationPolicy:", int(1))
	intrinsics.objc_send(nil, app, "finishLaunching")
	window := intrinsics.objc_send(Object, (^objc.Object)(objc.objc_lookUpClass("NSWindow")), "alloc")
	window = intrinsics.objc_send(
		Object,
		window,
		"initWithContentRect:styleMask:backing:defer:",
		Rect{120, 120, 320, 200},
		uint(15),
		uint(2),
		bool(false),
	)
	if window == nil {
		fmt.eprintln("FAIL: window allocation")
		os.exit(1)
	}
	_ = pool
	color := intrinsics.objc_send(Object, (^objc.Object)(objc.objc_lookUpClass("NSColor")), "redColor")
	intrinsics.objc_send(nil, window, "setBackgroundColor:", color)
	intrinsics.objc_send(nil, window, "setOpaque:", bool(true))
	number := intrinsics.objc_send(uint, window, "windowNumber")
	connection := SLSMainConnectionID()
	if connection == 0 || number == 0 {
		fmt.eprintln("FAIL: SLS connection or window number")
		os.exit(1)
	}
	fmt.printf("window=%d\n", number)
	if space_move {
		// C3: move the window between two real spaces through the gated
		// transaction ops 0x18/0x19. SLSSpaceCreate is gated behind the
		// WindowManager-bridge enablement (process-local once-token + delegate
		// check), so the target space is taken from --space-id instead.
		space1 := SLSGetActiveSpace(connection)
		space2 := move_space_id
		if space1 == 0 || space2 == 0 {
			fmt.eprintf("FAIL: spaces (%d, %d)\n", space1, space2)
			os.exit(1)
		}
		fmt.printf("space1=%d space2=%d\n", space1, space2)
		intrinsics.objc_send(bool, window, "orderFrontRegardless")
		pump(1.0)
		time.sleep(time.Duration(delay_ms) * time.Millisecond)
		txn := SLSTransactionCreate(connection)
		if txn == nil {
			fmt.eprintln("FAIL: SLSTransactionCreate")
			os.exit(1)
		}
		start := time.now()
		if managed_move {
			id := u64(number)
			value := CFNumberCreate(nil, 4, &id) // kCFNumberSInt64Type
			array := CFArrayCreate(nil, &value, 1, &kCFTypeArrayCallBacks)
			SLSMoveWindowsToManagedSpace(connection, array, space2)
			CFRelease(array)
			CFRelease(value)
		} else {
			SLSTransactionAddWindowToSpace(txn, u32(number), space2)
			SLSTransactionRemoveWindowFromSpace(txn, u32(number), space1)
			// Return value is not an error code (reads as garbage); success is
			// judged from observer events, not this register.
			_ = SLSTransactionCommit(txn, 1)
		}
		fmt.printf("move_call_ms=%d managed=%v\n", time.duration_milliseconds(time.since(start)), managed_move)
		pump(3.0)
		intrinsics.objc_send(nil, window, "close")
		fmt.printf("PASS: space move completed window=%d connection=%d\n", number, connection)
		os.exit(0)
	}
	if txn_mode {
		// Transaction path: op 0x01 (PKGTransactionOrderWindow) through the
		// dispatch table, gated by the "thold" command instead of "hold".
		if !no_hold {
			request := fmt.tprintf("thold %d\n", number)
			fd := posix.open("/private/tmp/shoji-ws-observer-request", {.WRONLY, .CREAT, .TRUNC}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
			if fd < 0 {
				fmt.eprintln("FAIL: thold request")
				os.exit(1)
			}
			written := posix.write(fd, raw_data(request), uint(len(request)))
			posix.close(fd)
			if written != len(request) {
				fmt.eprintln("FAIL: thold request write")
				os.exit(1)
			}
		}
		time.sleep(500 * time.Millisecond)
		txn := SLSTransactionCreate(connection)
		if txn == nil {
			fmt.eprintln("FAIL: SLSTransactionCreate")
			os.exit(1)
		}
		if txn_space {
			space := SLSGetActiveSpace(connection)
			if space == 0 {
				fmt.eprintln("FAIL: SLSGetActiveSpace")
				os.exit(1)
			}
			// Space channel: op 0x18 (PKGTransactionAddWindowToSpace).
			SLSTransactionAddWindowToSpace(txn, u32(number), space)
		} else {
			SLSTransactionOrderWindow(txn, u32(number), 1, 0)
		}
		// Return value is not an error code (reads as garbage); success is
		// judged from observer events, not this register.
		_ = SLSTransactionCommit(txn, 1)
		pump(1.2)
		intrinsics.objc_send(bool, window, "orderOut:", Object(nil))
		pump(0.25)
		intrinsics.objc_send(nil, window, "close")
		fmt.printf("PASS: transaction trigger completed window=%d connection=%d\n", number, connection)
		os.exit(0)
	}
	if no_hold {
		time.sleep(time.Duration(delay_ms) * time.Millisecond)
	} else {
		request := fmt.tprintf("hold %d\n", number)
		fd := posix.open("/private/tmp/shoji-ws-observer-request", {.WRONLY, .CREAT, .TRUNC}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
		if fd < 0 {
			fmt.eprintln("FAIL: hold request")
			os.exit(1)
		}
		written := posix.write(fd, raw_data(request), uint(len(request)))
		posix.close(fd)
		if written != len(request) {
			fmt.eprintln("FAIL: hold request write")
			os.exit(1)
		}
		time.sleep(500 * time.Millisecond)
	}
	// AppKit ordering produces a real visible window; raw SLSOrderWindow on a
	// never-ordered-in AppKit window stays onscreen=false with zero bounds.
	intrinsics.objc_send(bool, window, "orderFrontRegardless")
	if owner_move {
		pump(0.2)
		point := Point{600, 400}
		code := SLSMoveWindow(connection, u32(number), &point)
		pump(0.1)
		bounds: Rect
		readback := SLSGetWindowBounds(connection, u32(number), &bounds)
		verified := code == 0 && readback == 0 && bounds.x == point.x && bounds.y == point.y
		fmt.printf("owner_move: status=%d readback=%d verified=%v x=%d y=%d\n", code, readback, verified, i64(bounds.x), i64(bounds.y))
		if !verified {os.exit(1)}
	}
	if report_frame {
		// C1 safety probe: does the owning app learn of a server-side move,
		// and does its next surface commit keep or revert the position?
		steps := visible_ms / 500
		for step in 0 ..< steps {
			pump(0.5)
			NSColor := (^objc.Object)(objc.objc_lookUpClass("NSColor"))
			color := step % 2 == 0 ? intrinsics.objc_send(Object, NSColor, "blueColor") : intrinsics.objc_send(Object, NSColor, "redColor")
			intrinsics.objc_send(nil, window, "setBackgroundColor:", color)
			intrinsics.objc_send(nil, window, "display")
			frame := intrinsics.objc_send(Rect, window, "frame")
			bounds: Rect
			SLSGetWindowBounds(connection, u32(number), &bounds)
			fmt.printf("frame step=%d appkit_x=%d appkit_y=%d sls_x=%d sls_y=%d\n", step, i64(frame.x), i64(frame.y), i64(bounds.x), i64(bounds.y))
			// Resync like an AX position write: the app sets its own origin to
			// where WindowServer already shows it (top-left → Cocoa bottom-left).
			screen := intrinsics.objc_send(Object, (^objc.Object)(objc.objc_lookUpClass("NSScreen")), "mainScreen")
			screen_frame := intrinsics.objc_send(Rect, screen, "frame")
			cocoa_y := screen_frame.h - bounds.y - frame.h
			if math.abs(frame.x - bounds.x) >= 1 || math.abs(frame.y - cocoa_y) >= 1 {
				before := bounds
				intrinsics.objc_send(nil, window, "setFrameOrigin:", Point{bounds.x, cocoa_y})
				pump(0.05)
				after: Rect
				SLSGetWindowBounds(connection, u32(number), &after)
				synced := intrinsics.objc_send(Rect, window, "frame")
				fmt.printf("resync step=%d sls_before=%d,%d sls_after=%d,%d appkit_now=%d,%d\n", step, i64(before.x), i64(before.y), i64(after.x), i64(after.y), i64(synced.x), i64(synced.y))
			}
		}
	} else {
		pump(f64(visible_ms) / 1000)
	}
	intrinsics.objc_send(bool, window, "orderOut:", Object(nil))
	pump(0.25)
	intrinsics.objc_send(nil, window, "close")
	fmt.printf("PASS: ordering trigger completed window=%d connection=%d\n", number, connection)
	// Skip the Objective-C teardown path; earlier runs faulted or exited 255
	// after PASS during pool drain and window release.
	os.exit(0)
}
