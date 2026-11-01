package main

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:time"
import "core:sys/posix"
import objc "core:sys/darwin/Foundation"

Object :: ^objc.Object
Rect :: struct {x, y, w, h: f64}

foreign import cocoa "system:Cocoa.framework"
foreign import sls "system:SkyLight.framework"
foreign cocoa {NSApplicationLoad :: proc "c" () -> bool ---}
foreign sls {
	SLSMainConnectionID :: proc "c" () -> i32 ---
	SLSOrderWindow :: proc "c" (connection: i32, window, order, relative: u32) -> i32 ---
}

main :: proc() {
	if !NSApplicationLoad() {
		fmt.eprintln("FAIL: AppKit initialization")
		os.exit(1)
	}
	pool := intrinsics.objc_send(Object, (^objc.Object)(objc.objc_lookUpClass("NSAutoreleasePool")), "new")
	defer intrinsics.objc_send(nil, pool, "drain")
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
	defer intrinsics.objc_send(nil, window, "release")
	color := intrinsics.objc_send(Object, (^objc.Object)(objc.objc_lookUpClass("NSColor")), "redColor")
	intrinsics.objc_send(nil, window, "setBackgroundColor:", color)
	intrinsics.objc_send(nil, window, "setOpaque:", bool(true))
	number := intrinsics.objc_send(uint, window, "windowNumber")
	connection := SLSMainConnectionID()
	if connection == 0 || number == 0 {
		fmt.eprintln("FAIL: SLS connection or window number")
		os.exit(1)
	}
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
	if code := SLSOrderWindow(connection, u32(number), 1, 0); code != 0 {
		fmt.eprintf("FAIL: SLSOrderWindow front (%d)\n", code)
		os.exit(1)
	}
	time.sleep(1200 * time.Millisecond)
	if code := SLSOrderWindow(connection, u32(number), 0, 0); code != 0 {
		fmt.eprintf("FAIL: SLSOrderWindow out (%d)\n", code)
		os.exit(1)
	}
	time.sleep(250 * time.Millisecond)
	intrinsics.objc_send(nil, window, "close")
	fmt.printf("PASS: ordering trigger completed window=%d connection=%d\n", number, connection)
}
