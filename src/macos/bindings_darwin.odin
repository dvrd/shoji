package macos

import e "../engine"
import "base:intrinsics"
import "core:strings"
import CF "core:sys/darwin/CoreFoundation"
import objc "core:sys/darwin/Foundation"

foreign import cf "system:CoreFoundation.framework"
foreign import cg "system:CoreGraphics.framework"
foreign import ax "system:ApplicationServices.framework"
foreign import sls "system:SkyLight.framework"
foreign import cocoa "system:Cocoa.framework"
foreign cocoa {NSApplicationLoad :: proc "c" () -> bool ---}
foreign import libc "system:c"
Ref :: rawptr
Point :: struct {
	x, y: f64,
}

Size :: struct {
	w, h: f64,
}

AX_Callback :: proc "c" (observer, element, notification: Ref, user: rawptr)
@(default_calling_convention = "c")
foreign cf {
	CFEqual :: proc(a, b: Ref) -> bool ---
	CFRelease :: proc(ref: Ref) ---
	CFRetain :: proc(ref: Ref) -> Ref ---
	CFGetTypeID :: proc(ref: Ref) -> uint ---
	CFStringGetTypeID :: proc() -> uint ---
	CFStringCreateWithCString :: proc(allocator: Ref, text: cstring, encoding: u32) -> Ref ---
	CFStringGetLength :: proc(ref: Ref) -> int ---
	CFArrayGetCount :: proc(ref: Ref) -> int ---
	CFArrayGetValueAtIndex :: proc(ref: Ref, index: int) -> Ref ---
	CFArrayCreate :: proc(allocator: Ref, values: [^]Ref, count: int, callbacks: Ref) -> Ref ---
	CFDictionaryGetValue :: proc(ref, key: Ref) -> Ref ---
	CFNumberCreate :: proc(allocator: Ref, type: i32, value: rawptr) -> Ref ---
	CFNumberGetValue :: proc(ref: Ref, type: i32, value: rawptr) -> bool ---
	CFBooleanGetValue :: proc(ref: Ref) -> bool ---
	CFUUIDCreateFromString :: proc(allocator, string: Ref) -> Ref ---
	CFUUIDCreateString :: proc(allocator, uuid: Ref) -> Ref ---
	CFRunLoopGetMain :: proc() -> Ref ---
	CFRunLoopAddSource :: proc(loop, source, mode: Ref) ---
	CFRunLoopRemoveSource :: proc(loop, source, mode: Ref) ---
	CFRunLoopRunInMode :: proc(mode: Ref, seconds: f64, return_after_source: bool) -> i32 ---
	kCFRunLoopDefaultMode: Ref
	kCFBooleanTrue, kCFBooleanFalse: Ref
}
@(default_calling_convention = "c")
foreign cg {
	CGWindowListCopyWindowInfo :: proc(options, relative: u32) -> Ref ---
	CGGetActiveDisplayList :: proc(maximum: u32, displays: [^]u32, count: ^u32) -> i32 ---
	CGMainDisplayID :: proc() -> u32 ---
	CGDisplayBounds :: proc(display: u32) -> e.Rect ---
	CGDisplayCreateUUIDFromDisplayID :: proc(display: u32) -> Ref ---
	CGDisplayGetDisplayIDFromUUID :: proc(uuid: Ref) -> u32 ---
}
@(default_calling_convention = "c")
foreign ax {
	AXIsProcessTrusted :: proc() -> bool ---
	AXUIElementCreateApplication :: proc(pid: i32) -> Ref ---
	AXUIElementCreateSystemWide :: proc() -> Ref ---
	AXUIElementCopyAttributeValue :: proc(element, attribute: Ref, value: ^Ref) -> i32 ---
	AXUIElementSetAttributeValue :: proc(element, attribute, value: Ref) -> i32 ---
	AXUIElementIsAttributeSettable :: proc(element, attribute: Ref, value: ^bool) -> i32 ---
	AXUIElementPerformAction :: proc(element, action: Ref) -> i32 ---
	AXUIElementSetMessagingTimeout :: proc(element: Ref, timeout: f32) -> i32 ---
	AXValueCreate :: proc(type: u32, value: rawptr) -> Ref ---
	AXValueGetValue :: proc(value: Ref, type: u32, output: rawptr) -> bool ---
	_AXUIElementGetWindow :: proc(element: Ref, window: ^u32) -> i32 ---
	AXObserverCreate :: proc(pid: i32, callback: AX_Callback, observer: ^Ref) -> i32 ---
	AXObserverRemoveNotification :: proc(observer, element, notification: Ref) -> i32 ---
	AXObserverAddNotification :: proc(observer, element, notification: Ref, user: rawptr) -> i32 ---
	AXObserverGetRunLoopSource :: proc(observer: Ref) -> Ref ---
}
@(default_calling_convention = "c")
foreign sls {
	SLSWindowQueryWindows :: proc(connection: i32, windows: Ref, count: i32) -> Ref ---
	SLSWindowQueryResultCopyWindows :: proc(query: Ref) -> Ref ---
	SLSWindowIteratorGetCount :: proc(iterator: Ref) -> i32 ---
	SLSWindowIteratorAdvance :: proc(iterator: Ref) -> bool ---
	SLSWindowIteratorGetParentID :: proc(iterator: Ref) -> u32 ---
	SLSSetActiveMenuBarDisplayIdentifier :: proc(connection: i32, uuid, repeat_uuid: Ref) -> i32 ---
	SLSMainConnectionID :: proc() -> i32 ---
	CoreDockSendNotification :: proc(notification: Ref, unknown: i32) -> i32 ---
	SLSCopyManagedDisplaySpaces :: proc(connection: i32) -> Ref ---
	SLSCopyActiveMenuBarDisplayIdentifier :: proc(connection: i32) -> Ref ---
	SLSManagedDisplayGetCurrentSpace :: proc(connection: i32, display: Ref) -> u64 ---
	SLSCopySpacesForWindows :: proc(connection, selector: i32, windows: Ref) -> Ref ---
	SLSCopyManagedDisplayForWindow :: proc(connection: i32, window: u32) -> Ref ---
	SLSGetWindowBounds :: proc(connection: i32, window: u32, frame: ^e.Rect) -> i32 ---
	SLSGetWindowLevel :: proc(connection: i32, window: u32, level: ^i32) -> i32 ---
	SLSGetWindowSubLevel :: proc(connection: i32, window: u32) -> i32 ---
	SLSGetWindowTags :: proc(connection: i32, window: u32, tags: ^u64, size: uint) -> i32 ---
	SLSGetWindowAlpha :: proc(connection: i32, window: u32, alpha: ^f32) -> i32 ---
	SLSWindowIsOrderedIn :: proc(connection: i32, window: u32, ordered: ^u8) -> i32 ---
}
@(default_calling_convention = "c")
foreign libc {
	getuid :: proc() -> u32 ---
	geteuid :: proc() -> u32 ---
	getpid :: proc() -> i32 ---
	__error :: proc() -> ^i32 ---
}

cf_string :: proc(text: string) -> Ref {
	c := strings.clone_to_cstring(text, context.temp_allocator)
	return CFStringCreateWithCString(nil, c, 0x08000100)
}

text :: proc(ref: Ref) -> string {
	if ref == nil || CFGetTypeID(ref) != CFStringGetTypeID() {
		return ""
	}
	size := CF.StringGetMaximumSizeForEncoding(CF.Index(CFStringGetLength(ref)), 0x08000100) + 1
	buffer := make([]u8, int(size), context.temp_allocator)
	if !CF.StringGetCString(CF.String(ref), raw_data(buffer), size, 0x08000100) {
		return ""
	}
	return string(cstring(raw_data(buffer)))
}

attribute :: proc(ref: Ref, name: string) -> Ref {
	if ref == nil {
		return nil
	}
	key := cf_string(name)
	defer CFRelease(key)
	value: Ref
	if AXUIElementCopyAttributeValue(ref, key, &value) != 0 {
		return nil
	}
	return value
}

attribute_text :: proc(ref: Ref, name: string) -> string {
	value := attribute(ref, name)
	if value == nil {
		return ""
	}
	defer CFRelease(value)
	return text(value)
}

attribute_bool :: proc(ref: Ref, name: string) -> bool {
	value := attribute(ref, name)
	if value == nil {
		return false
	}
	defer CFRelease(value)
	return CFBooleanGetValue(value)
}

set_attribute :: proc(ref: Ref, name: string, value: Ref) -> i32 {
	key := cf_string(name)
	defer CFRelease(key)
	return AXUIElementSetAttributeValue(ref, key, value)
}

dictionary :: proc(ref: Ref, key: string) -> Ref {
	if ref == nil {
		return nil
	}
	name := cf_string(key)
	defer CFRelease(name)
	return CFDictionaryGetValue(ref, name)
}

number :: proc(ref: Ref) -> u64 {
	result: u64
	if ref != nil {
		CFNumberGetValue(ref, 4, &result)
	}
	return result
}

objc_text :: proc(object: ^objc.Object) -> string {
	if object == nil {
		return ""
	}
	return string(intrinsics.objc_send(cstring, object, "UTF8String"))
}

workspace :: proc() -> ^objc.Object {
	return intrinsics.objc_send(^objc.Object, Workspace, "sharedWorkspace")
}

pool_push :: proc() -> ^objc.Object {
	pool := intrinsics.objc_send(^objc.Object, objc.AutoreleasePool, "alloc")
	return intrinsics.objc_send(^objc.Object, pool, "init")
}

pool_pop :: proc(pool: ^objc.Object) {
	intrinsics.objc_send(nil, pool, "drain")
}

@(objc_class = "NSWorkspace")
Workspace :: struct {
	using _: objc.Object,
}
@(objc_class = "NSRunningApplication")
Running_Application :: struct {
	using _: objc.Object,
}
