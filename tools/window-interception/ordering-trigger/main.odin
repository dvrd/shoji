package main

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:time"
import objc "core:sys/darwin/Foundation"

Object :: ^objc.Object
Rect :: struct {x, y, w, h: f64}

foreign import cocoa "system:Cocoa.framework"
foreign cocoa {NSApplicationLoad :: proc "c" () -> bool ---}

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
	intrinsics.objc_send(nil, window, "orderFrontRegardless")
	time.sleep(250 * time.Millisecond)
	intrinsics.objc_send(nil, window, "orderOut:", Object(nil))
	time.sleep(250 * time.Millisecond)
	intrinsics.objc_send(nil, window, "close")
	fmt.println("PASS: ordering trigger completed")
}
