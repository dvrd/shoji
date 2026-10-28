package main

import "base:intrinsics"
import "core:fmt"
import "core:os"
import objc "core:sys/darwin/Foundation"
import posix "core:sys/posix"

Object :: ^objc.Object
Rect :: struct {
	x, y, w, h: f64,
}
foreign import cocoa "system:Cocoa.framework"
foreign cocoa { NSApplicationLoad :: proc "c" () -> bool --- }

require :: proc(ok: bool, message: string) {
	if !ok {
		fmt.eprintln("FAIL:", message); os.exit(1)
	}
}

main :: proc() {
	require(NSApplicationLoad(), "AppKit initialization")
	pool := intrinsics.objc_send(
		Object,
		(^objc.Object)(objc.objc_lookUpClass("NSAutoreleasePool")),
		"new",
	)
	defer intrinsics.objc_send(nil, pool, "drain")
	app := intrinsics.objc_send(
		Object,
		(^objc.Object)(objc.objc_lookUpClass("NSApplication")),
		"sharedApplication",
	)
	intrinsics.objc_send(bool, app, "setActivationPolicy:", int(1))
	intrinsics.objc_send(nil, app, "finishLaunching")

	// Loading through DYLD must install the hook before this unmodified call.
	stats := cast(proc "c" () -> u64)posix.dlsym(
		posix.Symbol_Table(~uintptr(1)),
		"shoji_window_agent_stats",
	)
	require(stats != nil, "agent injected before main")
	pre_show_ready := cast(proc "c" () -> bool)posix.dlsym(
		posix.Symbol_Table(~uintptr(1)),
		"shoji_window_agent_pre_show_ready",
	)
	require(pre_show_ready != nil, "agent pre-show evidence available")
	mode := "front"
	if len(os.args) > 1 {
		mode = os.args[1]
	}
	w := intrinsics.objc_send(
		Object,
		(^objc.Object)(objc.objc_lookUpClass("NSWindow")),
		"alloc",
	)
	w = intrinsics.objc_send(
		Object,
		w,
		"initWithContentRect:styleMask:backing:defer:",
		Rect{30, 30, 300, 200},
		uint(15),
		uint(2),
		bool(false),
	)
	require(w != nil, "window allocation")
	intrinsics.objc_send(nil, w, "setReleasedWhenClosed:", bool(false))
	defer intrinsics.objc_send(nil, w, "release")
	defer intrinsics.objc_send(nil, w, "close")
	require(
		!intrinsics.objc_send(bool, w, "isVisible"),
		"window remains hidden after constructor",
	)
	frame := intrinsics.objc_send(Rect, w, "frame")
	content := intrinsics.objc_send(Rect, w, "contentRectForFrameRect:", frame)
	if mode == "passthrough" {
		require(
			content.w == 300 && content.h == 200,
			"disabled agent preserves constructor arguments",
		)
		intrinsics.objc_send(nil, w, "setLevel:", int(3))
		intrinsics.objc_send(nil, w, "orderFront:", Object(nil))
		require(
			intrinsics.objc_send(bool, w, "isVisible"),
			"disabled agent preserves visibility",
		)
		require(
			intrinsics.objc_send(int, w, "level") == 3 && stats() == 0,
			"disabled agent preserves layer without intercepting",
		)
		fmt.println(
			"PASS: no opt-in leaves construction and ordering unchanged",
		)
		return
	}
	require(
		content.w == 640 && content.h == 480,
		"constructor size arguments intercepted",
	)
	require(
		u32(stats()) == 1 && stats() >> 32 == 0,
		"creation precedes first-show interception",
	)

	// An app can change geometry between construction and its first show.
	intrinsics.objc_send(
		nil,
		w,
		"setFrame:display:",
		Rect{70, 70, 900, 600},
		bool(false),
	)
	intrinsics.objc_send(nil, w, "setLevel:", int(3))
	intrinsics.objc_send(nil, w, "orderOut:", Object(nil))
	require(
		stats() >> 32 == 0,
		"ordering out must not consume the first-show policy",
	)
	if mode == "key" {
		intrinsics.objc_send(nil, w, "makeKeyAndOrderFront:", Object(nil))
	} else if mode == "regardless" {
		intrinsics.objc_send(nil, w, "orderFrontRegardless")
	} else if mode == "back" {
		intrinsics.objc_send(nil, w, "orderBack:", Object(nil))
	} else {
		intrinsics.objc_send(nil, w, "orderFront:", Object(nil))
	}
	require(
		intrinsics.objc_send(bool, w, "isVisible"),
		"original show call forwarded",
	)
	require(
		intrinsics.objc_send(Rect, w, "frame") == Rect{160, 160, 640, 480},
		"first-show geometry applied",
	)
	require(
		intrinsics.objc_send(int, w, "level") == 0,
		"first-show layer applied",
	)
	require(stats() >> 32 == 1, "first-show interception ran exactly once")
	require(
		pre_show_ready(),
		"frame and layer were ready while hidden before forwarding the first show",
	)

	// Later app/user operations must remain usable after admission.
	later := Rect{220, 220, 800, 500}
	intrinsics.objc_send(nil, w, "setFrame:display:", later, bool(false))
	intrinsics.objc_send(nil, w, "setLevel:", int(3))
	intrinsics.objc_send(nil, w, "orderOut:", Object(nil))
	intrinsics.objc_send(nil, w, "orderFront:", Object(nil))
	require(
		intrinsics.objc_send(Rect, w, "frame") == later,
		"later geometry preserved",
	)
	require(
		intrinsics.objc_send(int, w, "level") == 3,
		"later layer preserved",
	)
	require(stats() >> 32 == 1, "reopening does not rerun initial placement")
	fmt.println(
		"PASS: injected constructor and first-show interception, geometry, layer, forwarding and reopening",
	)
}
