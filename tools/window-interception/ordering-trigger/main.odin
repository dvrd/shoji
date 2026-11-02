package main

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:time"
import "core:sys/posix"
import objc "core:sys/darwin/Foundation"

Object :: ^objc.Object
Rect :: struct {x, y, w, h: f64}

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
	SLSOrderWindow :: proc "c" (connection: i32, window, order, relative: u32) -> i32 ---
	SLSTransactionCreate :: proc "c" (cid: i32) -> rawptr ---
	SLSTransactionOrderWindow :: proc "c" (txn: rawptr, window, order, relative: u32) -> i32 ---
	SLSTransactionCommit :: proc "c" (txn: rawptr, flags: i32) -> i32 ---
}

main :: proc() {
	no_hold := false
	txn_mode := false
	for arg in os.args[1:] {
		if arg == "--no-hold" {no_hold = true}
		if arg == "--txn" {txn_mode = true}
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
		SLSTransactionOrderWindow(txn, u32(number), 1, 0)
		if code := SLSTransactionCommit(txn, 1); code != 0 {
			fmt.eprintf("FAIL: SLSTransactionCommit (%d)\n", code)
			os.exit(1)
		}
		pump(1.2)
		intrinsics.objc_send(bool, window, "orderOut:", Object(nil))
		pump(0.25)
		intrinsics.objc_send(nil, window, "close")
		fmt.printf("PASS: transaction trigger completed window=%d connection=%d\n", number, connection)
		os.exit(0)
	}
	if no_hold {
		time.sleep(500 * time.Millisecond)
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
	pump(1.2)
	intrinsics.objc_send(bool, window, "orderOut:", Object(nil))
	pump(0.25)
	intrinsics.objc_send(nil, window, "close")
	fmt.printf("PASS: ordering trigger completed window=%d connection=%d\n", number, connection)
	// Skip the Objective-C teardown path; earlier runs faulted or exited 255
	// after PASS during pool drain and window release.
	os.exit(0)
}
