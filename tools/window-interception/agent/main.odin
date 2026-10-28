package window_agent

import "base:intrinsics"
import "base:runtime"
import objc "core:sys/darwin/Foundation"

Object :: ^objc.Object
Rect :: struct {
	x, y, w, h: f64,
}
Init :: proc "c" (
	_: Object,
	_: objc.SEL,
	_: Rect,
	_: uint,
	_: uint,
	_: bool,
) -> Object
Order :: proc "c" (_: Object, _: objc.SEL, _: int, _: int)
Show :: proc "c" (_: Object, _: objc.SEL)

foreign import libc "system:c"
foreign libc {
	getenv :: proc "c" (name: cstring) -> cstring ---
	getprogname :: proc "c" () -> cstring ---
	strcmp :: proc "c" (a, b: cstring) -> i32 ---
}
foreign import cf "system:CoreFoundation.framework"
foreign cf { kCFBooleanTrue: Object }

original_init: Init
original_order: Order
original_regardless: Show
created_key, shown_key: u8
initialized, first_shown: u32
installed: bool
pre_show_ready: bool

// This prototype deliberately accepts only the disposable fixture executable.
// It is not a general injector and must not modify another application's UI.
fixture_enabled :: proc() -> bool {
	opt := getenv("SHOJI_WINDOW_INTERCEPTION_FIXTURE")
	return(
		opt != nil &&
		strcmp(opt, "1") == 0 &&
		strcmp(getprogname(), "shoji-window-interception-fixture") == 0 \
	)
}

intercept_init :: proc "c" (
	self: Object,
	selector: objc.SEL,
	rect: Rect,
	style, backing: uint,
	deferred: bool,
) -> Object {
	context = runtime.default_context()
	// Change the constructor's arguments before calling AppKit. Visibility is
	// controlled separately by the first ordering call, not by AX discovery.
	rect := rect
	rect.w, rect.h = 640, 480
	window := original_init(self, selector, rect, style, backing, deferred)
	if window != nil {
		objc.objc_setAssociatedObject(
			objc.id(window),
			&created_key,
			objc.id(kCFBooleanTrue),
			.Assign,
		)
		initialized += 1
	}
	return window
}

prepare_first_show :: proc(self: Object) {
	if objc.objc_getAssociatedObject(objc.id(self), &created_key) != nil &&
	   objc.objc_getAssociatedObject(objc.id(self), &shown_key) == nil {
		// Mark before setters/original dispatch: AppKit can re-enter ordering.
		objc.objc_setAssociatedObject(
			objc.id(self),
			&shown_key,
			objc.id(kCFBooleanTrue),
			.Assign,
		)
		// No daemon round trip on the app's main thread: an AX query from the
		// daemon back into this blocked thread would deadlock window creation.
		intrinsics.objc_send(
			nil,
			self,
			"setFrame:display:",
			Rect{160, 160, 640, 480},
			bool(false),
		)
		intrinsics.objc_send(nil, self, "setLevel:", int(0))
		pre_show_ready =
			!intrinsics.objc_send(bool, self, "isVisible") &&
			intrinsics.objc_send(Rect, self, "frame") ==
				Rect{160, 160, 640, 480} &&
			intrinsics.objc_send(int, self, "level") == 0
		first_shown += 1
	}
}

intercept_order :: proc "c" (
	self: Object,
	selector: objc.SEL,
	place, relative: int,
) {
	context = runtime.default_context()
	if place != 0 {
		prepare_first_show(self)
	}
	original_order(self, selector, place, relative)
}

intercept_regardless :: proc "c" (self: Object, selector: objc.SEL) {
	context = runtime.default_context()
	prepare_first_show(self)
	original_regardless(self, selector)
}

@(export)
shoji_window_agent_stats :: proc "c" () -> u64 {
	return u64(initialized) | u64(first_shown) << 32
}

@(export)
shoji_window_agent_pre_show_ready :: proc "c" () -> bool {
	return pre_show_ready
}

@(export)
shoji_window_agent_start :: proc "c" () {
	context = runtime.default_context()
	if installed || !fixture_enabled() {
		return
	}
	cls := objc.objc_lookUpClass("NSWindow")
	if cls == nil {
		return
	}
	init_method := objc.class_getInstanceMethod(
		cls,
		objc.sel_registerName("initWithContentRect:styleMask:backing:defer:"),
	)
	order_method := objc.class_getInstanceMethod(
		cls,
		objc.sel_registerName("orderWindow:relativeTo:"),
	)
	regardless_method := objc.class_getInstanceMethod(
		cls,
		objc.sel_registerName("orderFrontRegardless"),
	)
	if init_method == nil || order_method == nil || regardless_method == nil {
		return
	}
	// The local Odin binding discards method_setImplementation's return value.
	// Preserve both original implementations before replacing either method.
	original_init = cast(Init)objc.method_getImplementation(init_method)
	original_order = cast(Order)objc.method_getImplementation(order_method)
	original_regardless = cast(Show)objc.method_getImplementation(
		regardless_method,
	)
	if original_init == nil ||
	   original_order == nil ||
	   original_regardless == nil {
		return
	}
	objc.method_setImplementation(init_method, cast(objc.IMP)intercept_init)
	objc.method_setImplementation(order_method, cast(objc.IMP)intercept_order)
	objc.method_setImplementation(
		regardless_method,
		cast(objc.IMP)intercept_regardless,
	)
	installed = true
}

@(link_section = "__DATA,__mod_init_func", linkage = "strong", require)
initialize_agent: proc "c" () = shoji_window_agent_start
