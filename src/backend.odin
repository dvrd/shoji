#+build darwin

package shoji

import n "native"
import "base:intrinsics"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import objc "core:sys/darwin/Foundation"
import "core:time"

foreign import cf "system:CoreFoundation.framework"
foreign import cg "system:CoreGraphics.framework"
foreign import ax "system:ApplicationServices.framework"
foreign import sls "system:SkyLight.framework"
foreign import cocoa "system:Cocoa.framework"
foreign import libc "system:c"

CFRelease :: n.CFRelease
CFGetTypeID :: n.CFGetTypeID
CFStringGetTypeID :: n.CFStringGetTypeID
CFStringGetLength :: n.CFStringGetLength
CFNumberCreate :: n.CFNumberCreate
SLSMainConnectionID :: n.SLSMainConnectionID
SLSManagedDisplayGetCurrentSpace :: n.SLSManagedDisplayGetCurrentSpace
SLSGetWindowBounds :: n.SLSGetWindowBounds
SLSGetWindowAlpha :: n.SLSGetWindowAlpha
getuid :: n.getuid
__error :: n.__error

// Native framework declarations
// ------------------------------------------------------------------------

foreign cocoa { NSApplicationLoad :: proc "c" () -> bool --- }
Ref :: n.Ref
Point :: n.Point

Size :: struct {
	w, h: f64,
}

AX_Callback :: proc "c" (observer, element, notification: Ref, user: rawptr)
@(default_calling_convention = "c")
foreign cf {
	CFEqual :: proc(a, b: Ref) -> bool ---
	CFRetain :: proc(ref: Ref) -> Ref ---
	CFStringCreateWithCString :: proc(allocator: Ref, text: cstring, encoding: u32) -> Ref ---
	CFArrayGetCount :: proc(ref: Ref) -> int ---
	CFArrayGetValueAtIndex :: proc(ref: Ref, index: int) -> Ref ---
	CFArrayCreate :: proc(allocator: Ref, values: [^]Ref, count: int, callbacks: Ref) -> Ref ---
	CFDictionaryGetValue :: proc(ref, key: Ref) -> Ref ---
	CFDictionaryCreate :: proc(allocator: Ref, keys, values: [^]Ref, count: int, key_callbacks, value_callbacks: Ref) -> Ref ---
	CFNumberGetValue :: proc(ref: Ref, type: i32, value: rawptr) -> bool ---
	CFBooleanGetValue :: proc(ref: Ref) -> bool ---
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
	CGDisplayBounds :: proc(display: u32) -> Rect ---
	CGDisplayCreateUUIDFromDisplayID :: proc(display: u32) -> Ref ---
}
@(default_calling_convention = "c")
foreign ax {
	AXIsProcessTrusted :: proc() -> bool ---
	AXIsProcessTrustedWithOptions :: proc(options: Ref) -> bool ---
	kAXTrustedCheckOptionPrompt: Ref
	AXUIElementCreateApplication :: proc(pid: i32) -> Ref ---
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
	CoreDockSendNotification :: proc(notification: Ref, unknown: i32) -> i32 ---
	SLSCopyManagedDisplaySpaces :: proc(connection: i32) -> Ref ---
	SLSCopyActiveMenuBarDisplayIdentifier :: proc(connection: i32) -> Ref ---
	SLSCopySpacesForWindows :: proc(connection, selector: i32, windows: Ref) -> Ref ---
	SLSGetWindowLevel :: proc(connection: i32, window: u32, level: ^i32) -> i32 ---
	SLSGetWindowSubLevel :: proc(connection: i32, window: u32) -> i32 ---
	SLSGetWindowTags :: proc(connection: i32, window: u32, tags: ^u64, size: uint) -> i32 ---
	SLSWindowIsOrderedIn :: proc(connection: i32, window: u32, ordered: ^u8) -> i32 ---
}
@(default_calling_convention = "c")
foreign libc {
	geteuid :: proc() -> u32 ---
	getpid :: proc() -> i32 ---
}

cf_string :: proc(text: string) -> Ref {
	c := strings.clone_to_cstring(text, context.temp_allocator)
	return CFStringCreateWithCString(nil, c, 0x08000100)
}

text :: n.text

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

pool_push :: n.pool_push
pool_pop :: n.pool_pop

@(objc_class = "NSWorkspace")
Workspace :: struct {
	using _: objc.Object,
}
@(objc_class = "NSRunningApplication")
Running_Application :: struct {
	using _: objc.Object,
}

// Native state and action dispatch
// ------------------------------------------------------------------------

// Each nested AX callback owns a separate arena; resetting an inner callback
// must never invalidate the outer callback's borrowed text.
Callback_Scratch :: struct {
	arenas: [dynamic]^mem.Dynamic_Arena,
	depth: int,
	allocator: mem.Allocator,
}
scratch_reset :: proc(arena: ^mem.Dynamic_Arena) {
	mem.dynamic_arena_reset(arena)
	// Keep normal tick capacity, but release exceptional bursts.
	if len(arena.unused_blocks) > 4 {
		mem.dynamic_arena_free_all(arena)
	}
}
callback_scratch_begin :: proc(pool: ^Callback_Scratch) -> ^mem.Dynamic_Arena {
	if pool.allocator.procedure == nil {
		pool.allocator = context.allocator
		pool.arenas.allocator = pool.allocator
	}
	if pool.depth == len(pool.arenas) {
		arena := new(mem.Dynamic_Arena, pool.allocator)
		mem.dynamic_arena_init(arena, pool.allocator, pool.allocator)
		append(&pool.arenas, arena)
	}
	arena := pool.arenas[pool.depth]
	pool.depth += 1
	return arena
}
callback_scratch_end :: proc(pool: ^Callback_Scratch) {
	assert(pool.depth > 0)
	pool.depth -= 1
	scratch_reset(pool.arenas[pool.depth])
}
callback_scratch_destroy :: proc(pool: ^Callback_Scratch) {
	assert(pool.depth == 0)
	for arena in pool.arenas {
		mem.dynamic_arena_destroy(arena)
		free(arena, pool.allocator)
	}
	delete(pool.arenas)
	pool^ = {}
}

Application :: struct {
	element, observer: Ref,
	name: string,
	hidden: bool,
	policy: int,
}

State :: struct {
	callback_scratch: Callback_Scratch,
	opening_tracking: bool,
	opening_collecting: bool,
	structural_dirty: bool,
	opening_backend: Opening_Backend,
	opening_guards: map[u32]Opening_Guard,
	opening_notice: Owned_Surface,
	resize_covers: map[u32]Resize_Cover,
	capture_memory: Capture_Memory,
	resize_cover_backend: Resize_Cover_Backend,
	resize_snapshots: map[u32]Resize_Snapshots,
	resize_cover_retry: f64,
	resize_cover_cancel: bool,
	display_clock: Display_Clock,
	opening_windows: map[u32]bool,
	frame_updates: Frame_Updates,
	validation_pid: i32,
	display_probe: Display_Probe,
	window_probe: Window_Probe,
	animation_journal: Animation_Journal,
	observed: Snapshot,
	observation_next: Snapshot,
	display_focus_backend: Display_Focus_Backend,
	feedback: map[u32]Feedback_Window,
	feedback_backend: Feedback_Backend,
	focus_ring: Focus_Ring,
	tab_indicator: Tab_Indicator_State,
	focus_geometry_dirty: bool,
	focus_frame_probe: proc(state: ^State, window: u32) -> (Rect, bool),
	focus_scroll_pending: u32,
	focus_scroll_deadline: f64,
	read_only: bool,
	animations: map[u32]Animation_Job,
	animation_backend: Animation_Backend,
	event_sink: proc(user: rawptr, event: Event),
	event_user: rawptr,
	workspace_events: Workspace_State,
	mouse: Mouse_State,
	stack_touch: Stack_Touch_State,
	manager: Manager,
	windows: map[u32]Ref,
	applications: map[i32]Application,
	connection: i32,
	dirty: bool,
}

observer_callback :: proc "c" (
	observer, element, notification: Ref,
	user: rawptr,
) {
	context = runtime.default_context()
	state := (^State)(user)
	state.dirty = true
	pool := pool_push(); defer pool_pop(pool)
	scratch := callback_scratch_begin(&state.callback_scratch)
	defer callback_scratch_end(&state.callback_scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(scratch)
	name := text(notification)
	if (name == "AXMoved" || name == "AXResized") &&
	   state.focus_ring.owner != 0 {
		if ref := state.windows[state.focus_ring.owner];
		   ref != nil && CFEqual(ref, element) {
			state.focus_geometry_dirty = true
		}
	}
	if name == "AXFocusedWindowChanged" ||
	   name == "AXApplicationActivated" ||
	   name == "AXApplicationShown" {
		state.focus_ring.order_dirty = true
		state.tab_indicator.order_dirty = true
		focus_ring_prune_unordered(state)
	}
	if name == "AXWindowMiniaturized" || name == "AXApplicationHidden" {
		focus_ring_prune_unordered(state)
	}
	if name == "AXUIElementDestroyed" {
		state.structural_dirty = true; opening_destroyed(state, element)
		return
	}
	// AXCreated can precede AXWindowCreated for AppKit, but also announces
	// controls. Only independent windows require a structural refresh.
	if name == "AXWindowCreated" ||
	   (name == "AXCreated" &&
			   attribute_text(element, "AXRole") == "AXWindow") {
		state.structural_dirty = true
		opening_created(state, observer, element)
	}
}

observe :: proc(state: ^State, observer, element: Ref, name: string) {
	notification := cf_string(name)
	defer CFRelease(notification)
	AXObserverAddNotification(observer, element, notification, state)
}

state_init :: proc(state: ^State) {
	// Initialize Cocoa before requesting the WindowServer connection, as yabai does.
	NSApplicationLoad()
	state.windows = make(map[u32]Ref)
	state.applications = make(map[i32]Application)
	state.connection = SLSMainConnectionID()
	state.dirty = true
	manager_init(&state.manager, perform_native, state)
	state.manager.resize_fade = true
	state.manager.scroll_animate = true
	state.manager.scroll_frame_pacing = true
}

state_destroy :: proc(state: ^State) {
	defer callback_scratch_destroy(&state.callback_scratch)
	resize_cover_stop(state)
	display_clock_stop(&state.display_clock)
	opening_stop(state)
	observations_destroy(state)
	feedback_stop(state)
	animation_stop(state)
	animation_journal_close(&state.animation_journal)
	for _, element in state.windows {
		CFRelease(element)
	}
	delete(state.windows)
	for _, app in state.applications {
		application_destroy(app)
	}
	delete(state.applications)
	manager_destroy(&state.manager)
}

Focus_Verifier :: proc(user: rawptr, pid: i32, window: u32) -> bool

native_focus_verified :: proc(user: rawptr, pid: i32, window: u32) -> bool {
	state := (^State)(user)
	app, exists := state.applications[pid]
	if !exists || app.element == nil {return false}
	front := intrinsics.objc_send(^objc.Object, workspace(), "frontmostApplication")
	if front == nil || intrinsics.objc_send(i32, front, "processIdentifier") != pid {
		return false
	}
	focused := attribute(app.element, "AXFocusedWindow")
	if focused == nil {return false}
	defer CFRelease(focused)
	id: u32
	return _AXUIElementGetWindow(focused, &id) == 0 && id == window
}

focus_raise_result :: proc(code: i32, pid: i32, window: u32, user: rawptr, verify: Focus_Verifier) -> string {
	if code == 0 || (verify != nil && verify(user, pid, window)) {return ""}
	return fmt.tprintf("Accessibility raise failed (%d)", code)
}

perform_native :: proc(user: rawptr, action: Action) -> string {
	state := (^State)(user)
	if state.read_only {
		return "window operations are disabled in read-only inspection"
	}
	if state.validation_pid != 0 {
		if action.kind >= .Display_Focus || action.kind == .Space {
			return(
				"global desktop operations are disabled during owned-window validation" \
			)
		}
		window := state.manager.windows[action.window]
		if window == nil || window.pid != state.validation_pid {
			return "window is outside the validation fixture"
		}
	}
	if action.kind == .Display_Focus {
		return focus_display(state, action.display)
	}
	element := state.windows[action.window]
	if action.kind >= .Space_Focus ||
	   action.kind == .Focus_Without_Raise ||
	   action.kind == .Space ||
	   action.kind == .Opacity ||
	   action.kind == .Layer ||
	   action.kind == .Sticky ||
	   action.kind == .Shadow ||
	   action.kind == .Order ||
	   action.kind == .Scale {
		err := addition_action(action); if err == "" {
			state.dirty = true
			focus_ring_note_action(state, action)
		}; return err
	}
	if element == nil {
		return "window no longer has an Accessibility reference"
	}
	#partial switch action.kind {
	case .Expose:
		if err := perform_native(state, {kind = .Focus, window = action.window});
		   err != "" {
			return err
		}
		notification := cf_string("com.apple.expose.front.awake")
		defer CFRelease(notification)
		if CoreDockSendNotification(notification, 0) != 0 {
			return "could not request application Expose"
		}
	case .Frame:
		if action.duration > 0 {
			return animation_start(
				state,
				animation_frame_action(state, action),
			)
		}
		if err := animation_interrupt(state, action.window); err != "" {
			return err
		}
		return apply_frame_now(state, action.window, action.frame)
	case .Focus:
		w := state.manager.windows[action.window]
		if w == nil {
			return "window no longer exists"
		}
		app := intrinsics.objc_send(
			^objc.Object,
			Running_Application,
			"runningApplicationWithProcessIdentifier:",
			w.pid,
		)
		if app == nil ||
		   !intrinsics.objc_send(bool, app, "activateWithOptions:", uint(2)) {
			return "could not activate application"
		}
		set_attribute(element, "AXMain", kCFBooleanTrue)
		raise := cf_string("AXRaise")
		defer CFRelease(raise)
		code := AXUIElementPerformAction(element, raise)
		if err := focus_raise_result(code, w.pid, w.id, state, native_focus_verified); err != "" {return err}
	case .Close:
		button := attribute(element, "AXCloseButton")
		if button == nil {
			return "window has no close button"
		}
		defer CFRelease(button)
		press := cf_string("AXPress")
		defer CFRelease(press)
		if code := AXUIElementPerformAction(button, press); code != 0 {
			return fmt.tprintf("Accessibility close failed (%d)", code)
		}
	case .Minimize, .Deminimize:
		if code := set_attribute(
			element,
			"AXMinimized",
			action.kind == .Minimize ? kCFBooleanTrue : kCFBooleanFalse,
		); code != 0 {
			return fmt.tprintf("Accessibility minimize failed (%d)", code)
		}
	case .Fullscreen:
		if code := set_attribute(
			element,
			"AXFullScreen",
			action.flag ? kCFBooleanTrue : kCFBooleanFalse,
		); code != 0 {
			return fmt.tprintf("Accessibility fullscreen failed (%d)", code)
		}
	case .Space, .Opacity, .Layer, .Sticky, .Shadow:
		return addition_action(action)
	case:
		return "unsupported macOS operation"
	}
	state.dirty = true
	focus_ring_note_action(state, action)
	return ""
}

window_space :: proc(state: ^State, id: u32) -> u64 {
	id := id
	value := CFNumberCreate(nil, 3, &id)
	defer CFRelease(value)
	array := CFArrayCreate(nil, &value, 1, nil)
	defer CFRelease(array)
	spaces := SLSCopySpacesForWindows(state.connection, 7, array)
	if spaces == nil {
		return 0
	}
	defer CFRelease(spaces)
	if CFArrayGetCount(spaces) == 0 {
		return 0
	}
	return number(CFArrayGetValueAtIndex(spaces, 0))
}

window_is_root :: proc(
	state: ^State,
	id: u32,
	element, application: Ref,
) -> bool {
	id := id
	number := CFNumberCreate(nil, 3, &id); defer CFRelease(number)
	array := CFArrayCreate(nil, &number, 1, nil); defer CFRelease(array)
	query := SLSWindowQueryWindows(state.connection, array, 1)
	parent_id: u32
	if query != nil {
		defer CFRelease(query)
		iterator := SLSWindowQueryResultCopyWindows(query)
		if iterator != nil {
			defer CFRelease(iterator)
			if SLSWindowIteratorGetCount(iterator) == 1 &&
			   SLSWindowIteratorAdvance(iterator) {
				parent_id = SLSWindowIteratorGetParentID(iterator)
			}
		}
	}
	if parent_id == 0 {
		return true
	}
	parent := attribute(element, "AXParent")
	if parent == nil {
		return false
	}; defer CFRelease(parent)
	return CFEqual(parent, application)
}
native_frame_read :: proc(
	element: Ref,
	name: string,
	kind: u32,
	output: rawptr,
) -> bool {
	value := attribute(element, name)
	if value == nil {
		return false
	}
	defer CFRelease(value)
	return AXValueGetValue(value, kind, output)
}

valid_frame :: proc(frame: Rect) -> bool {
	for value in ([4]f64{frame.x, frame.y, frame.w, frame.h}) {
		if math.is_nan(value) || math.is_inf(value) {
			return false
		}
	}
	return frame.w > 0 && frame.h > 0
}

window_frame :: proc(
	element: Ref,
	read: proc(
		_: Ref,
		_: string,
		_: u32,
		_: rawptr,
	) -> bool = native_frame_read,
) -> Maybe(Rect) {
	p: Point
	size: Size
	if !read(element, "AXPosition", 1, &p) ||
	   !read(element, "AXSize", 2, &size) {
		return nil
	}
	frame := Rect{p.x, p.y, size.w, size.h}
	if !valid_frame(frame) {
		return nil
	}
	return frame
}

observe_application :: proc(
	state: ^State,
	pid: i32,
	activation_policy: int,
) -> bool {
	// Accessory apps include System Information's About This Mac window.
	// Prohibited/background apps remain outside window management.
	return(
		(activation_policy == 0 || activation_policy == 1) &&
		(state.validation_pid == 0 || pid == state.validation_pid) \
	)
}

// Accessibility frame writes
// ------------------------------------------------------------------------

Frame_Attributes :: struct {
	user: rawptr,
	enhanced: proc(user: rawptr, application: Ref) -> bool,
	set: proc(user: rawptr, element: Ref, name: string, value: Ref) -> i32,
}

native_frame_enhanced :: proc(_: rawptr, application: Ref) -> bool {
	return attribute_bool(application, "AXEnhancedUserInterface")
}
native_frame_set :: proc(
	_: rawptr,
	element: Ref,
	name: string,
	value: Ref,
) -> i32 {
	return set_attribute(element, name, value)
}

apply_accessibility_frame :: proc(
	application, element: Ref,
	frame: Rect,
	attributes := Frame_Attributes {
		nil,
		native_frame_enhanced,
		native_frame_set,
	},
	previous: Maybe(Rect) = nil,
	size_tolerance: f64 = 0,
) -> string {
	// This optional workaround is best-effort. AppKit's legacy Carbon callback
	// can return NotImplemented after the enhanced-UI flag has changed.
	// Keep frame errors authoritative and always attempt to restore prior state.
	enhanced := attributes.enhanced(attributes.user, application)
	defer {
		if enhanced {
			attributes.set(
				attributes.user, application,
				"AXEnhancedUserInterface", kCFBooleanTrue,
			)
		}
	}
	if enhanced {
		attributes.set(
			attributes.user, application,
			"AXEnhancedUserInterface", kCFBooleanFalse,
		)
	}
	return write_accessibility_frame(
		element, frame, attributes, previous, size_tolerance,
	)
}

write_accessibility_frame :: proc(
	element: Ref,
	frame: Rect,
	attributes: Frame_Attributes,
	previous: Maybe(Rect) = nil,
	size_tolerance: f64 = 0,
) -> string {
	p := Point{frame.x, frame.y}
	size := Size{frame.w, frame.h}
	position := AXValueCreate(1, &p)
	if position == nil {
		return "Accessibility could not allocate window position"
	}
	defer CFRelease(position)
	dimensions := AXValueCreate(2, &size)
	if dimensions == nil {
		return "Accessibility could not allocate window size"
	}
	defer CFRelease(dimensions)
	if old, known := previous.?; known {
		moved := old.x != frame.x || old.y != frame.y
		resized := old.w != frame.w || old.h != frame.h
		// A settled fractional layout size can differ slightly from native
		// readback. Scroll movement must not relayout content for that rounding.
		// Equality at the half-point boundary still requests a real resize.
		if size_tolerance > 0 {
			resized =
				math.abs(old.w - frame.w) >= size_tolerance ||
				math.abs(old.h - frame.h) >= size_tolerance
		}
		// A pure resize needs one size write. Repeating the old position and
		// size can make applications lay out and repaint intermediate frames.
		if !moved {
			if !resized {
				return ""
			}
			if code := attributes.set(
				attributes.user,
				element,
				"AXSize",
				dimensions,
			); code != 0 {
				return fmt.tprintf(
					"Accessibility could not set window size (%d)",
					code,
				)
			}
			return ""
		}
		if !resized {
			if code := attributes.set(
				attributes.user,
				element,
				"AXPosition",
				position,
			); code != 0 {
				return fmt.tprintf(
					"Accessibility could not set window position (%d)",
					code,
				)
			}
			return ""
		}
	}
	// Some applications clamp a size change at the old position; repeat after moving.
	attributes.set(attributes.user, element, "AXSize", dimensions)
	a := attributes.set(attributes.user, element, "AXPosition", position)
	b := attributes.set(attributes.user, element, "AXSize", dimensions)
	if a != 0 || b != 0 {
		return fmt.tprintf(
			"Accessibility could not set window frame (%d, %d)",
			a,
			b,
		)
	}
	return ""
}
apply_frame_now :: proc(state: ^State, window: u32, frame: Rect) -> string {
	if state.read_only {
		return "window operations are disabled in read-only inspection"
	}
	w := state.manager.windows[window]
	if w == nil {
		return "window no longer exists"
	}
	if state.validation_pid != 0 && w.pid != state.validation_pid {
		return "window is outside the validation fixture"
	}
	element := state.windows[window]
	if element == nil {
		return "window no longer has an Accessibility reference"
	}
	app := state.applications[w.pid]
	observed: Rect; previous: Maybe(Rect)
	if SLSGetWindowBounds(state.connection, window, &observed) == 0 &&
	   observed.w > 0 &&
	   observed.h > 0 &&
	   !math.is_nan(observed.w) &&
	   !math.is_nan(observed.h) &&
	   !math.is_inf(observed.w) &&
	   !math.is_inf(observed.h) {
		previous = observed
	}
	scroll := false
	if s := space_by_id(&state.manager, w.space); s != nil {
		scroll = s.view.layout == .Scroll && managed(w)
	}
	effective := frame
	if scroll && previous != nil && size_feedback_duplicate(w, frame) {
		// Position updates remain live, but an outstanding identical size request
		// is not resent while its settled native result is still being observed.
		effective.w, effective.h = observed.w, observed.h
	}
	resize_cover_frame(state, window, frame, previous, CACurrentMediaTime())
	started: time.Tick
	if state.manager.motion_trace.active {
		started = time.tick_now()
	}
	if state.manager.motion_trace.active {
		motion_trace_record(
			&state.manager.motion_trace,
			{
				kind = "native-frame-begin",
				window = window,
				requested = frame,
				observed = observed,
				value = f64(int(w.opening.phase)),
			},
		)
	}
	if err := frame_updates_begin(state); err != "" {
		return err
	}
	err := apply_accessibility_frame(
		app.element,
		element,
		effective,
		previous = previous,
		size_tolerance = scroll ? .5 : 0,
	)
	present := frame_updates_end(state)
	if state.manager.motion_trace.active {
		actual: Rect
		code := SLSGetWindowBounds(state.connection, window, &actual)
		if err != "" || present != "" {
			code = -1
		}
		motion_trace_record(
			&state.manager.motion_trace,
			{
				kind = "native-frame",
				window = window,
				space = w.space,
				requested = frame,
				observed = actual,
				status = code,
				duration_ms = f64(time.tick_since(started)) / 1e6,
			},
		)
	}
	if err != "" {
		resize_cover_remove(state, window)
		w.size_feedback.pending = false
		return err
	}
	if present != "" {
		return present
	}
	if scroll && previous != nil {
		size_feedback_request(
			w,
			frame,
			observed,
			time.duration_seconds(time.diff(time.Time{}, time.now())),
		)
	}
	state.dirty = true
	return ""
}

// Accepted-size feedback
// ------------------------------------------------------------------------

frame_size_feedback_tick :: proc(state: ^State, now: time.Time) {
	seconds := time.duration_seconds(time.diff(time.Time{}, now))
	m := &state.manager
	for id, w in m.windows {
		f := &w.size_feedback
		if !managed(w) {
			if f.pending || f.width_valid || f.height_valid {
				f.pending, f.width_valid, f.height_valid = false, false, false
				f.generation += 1
			}
			continue
		}
		if !f.pending ||
		   seconds - f.requested_at < 0.15 ||
		   seconds - f.checked_at <
			   (seconds - f.requested_at > 3 ? f64(0.5) : f64(0.06)) {
			continue
		}
		s := space_by_id(m, w.space)
		if s == nil ||
		   !s.visible ||
		   s.view.layout != .Scroll ||
		   s.view.scroll.dragging ||
		   s.view.scroll.motion.active ||
		   s.view.scroll.geometry_active ||
		   m.suspended ||
		   m.gesture_active ||
		   w.grabbed ||
		   m.native_resize_window == id {
			continue
		}
		generation := f.generation
		owner, known := animation_recovery_query_owner(state.connection, id)
		pid: i32
		if !known || SLSConnectionGetPID(owner, &pid) != 0 {
			f.checked_at = seconds; continue
		}
		if pid != w.pid {
			f.pending, f.width_valid, f.height_valid = false, false, false
			state.dirty = true; continue
		}
		observed: Rect
		if SLSGetWindowBounds(state.connection, id, &observed) != 0 {
			f.checked_at = seconds; continue
		}
		if size_feedback_observe(w, generation, observed, seconds) {
			// The app is already at its accepted size. Correct layout occupancy
			// immediately instead of animating neighbors through that native frame.
			w.frame = observed
			if err := flush(m, s, true); err != "" {
				fmt.eprintln("shoji: accepted size:", err)
			}
			state.dirty = true
		}
	}
}

// Owned-window size validation
// ------------------------------------------------------------------------

// A separate controller process using Shoji's existing signed executable. It
// creates no daemon/socket and rejects every window outside the named fixture.
validate_window_sizes :: proc(pid: i32, swipe: bool = false) -> int {
	if !AXIsProcessTrusted() {
		fmt.eprintln(
			"size validation requires Shoji's existing Accessibility access",
		); return 3
	}
	pool := pool_push(); defer pool_pop(pool)
	state: State
	state_init(&state); defer state_destroy(&state)
	state.validation_pid = pid
	if state.connection == 0 {
		fmt.eprintln("size validation requires the logged-in GUI session")
		return 3
	}
	app := AXUIElementCreateApplication(pid)
	if app == nil {
		return 3
	}
	state.applications[pid] = {
		element = app,
		name    = strings.clone("Shoji size fixture"),
	}
	array := attribute(app, "AXWindows")
	if array == nil {
		fmt.eprintln("size fixture has no accessible windows"); return 3
	}
	defer CFRelease(array)
	bounds := CGDisplayBounds(CGMainDisplayID())
	area := Rect{80, 80, min(1280, bounds.w - 160), min(800, bounds.h - 160)}
	if area.w < 1000 || area.h < 600 {
		fmt.eprintln("display is too small for this size fixture"); return 3
	}
	append(
		&state.manager.displays,
		Display {
			id = 1,
			index = 1,
			active_space = 1,
			frame = area,
			usable = area,
		},
	)
	s := add_space(&state.manager, 1, 1, 1, area)
	s.visible = true; s.view.gap = 16; state.manager.active_space = 1
	a, b := u32(0), u32(0)
	count := CFArrayGetCount(array)
	if count != 2 {
		fmt.eprintln("expected exactly two disposable size fixture windows")
		return 3
	}
	for i in 0 ..< count {
		element := CFArrayGetValueAtIndex(array, i)
		title := attribute_text(element, "AXTitle")
		if !strings.has_prefix(title, "Shoji size fixture ") {
			fmt.eprintln("refusing a non-fixture window"); return 3
		}
		id: u32
		if _AXUIElementGetWindow(element, &id) != 0 || id == 0 {
			return 3
		}
		owner, known := animation_recovery_query_owner(state.connection, id)
		actual_pid: i32
		if !known ||
		   SLSConnectionGetPID(owner, &actual_pid) != 0 ||
		   actual_pid != pid {
			return 3
		}
		state.windows[id] = CFRetain(element)
		frame: Rect
		if SLSGetWindowBounds(state.connection, id, &frame) != 0 {
			return 3
		}
		add_window(
			&state.manager,
			{
				id = id,
				pid = pid,
				app = "Shoji size fixture",
				title = title,
				frame = frame,
				space = 1,
				display = 1,
				role = "AXWindow",
				subrole = "AXStandardWindow",
				opacity = 1,
			},
		)
		if strings.has_prefix(title, "Shoji size fixture A") {
			a = id
		}
		if strings.has_prefix(title, "Shoji size fixture B") {
			b = id
		}
	}
	if a == 0 || b == 0 {
		return 3
	}
	if swipe { return validate_fixture_swipe(&state, s, a, b) }
	set_layout(&state.manager, s, .Scroll)
	focus_window(&state.manager, b)
	state.manager.scroll_time = size_validation_seconds()
	if response := execute(
		&state.manager,
		{"window", fmt.tprintf("%d", a), "--column-width", "abs:300"},
	); response.failed {
		fmt.eprintln(response.text); return 1
	}
	if !size_validation_settle(&state, 1.2) {
		return 1
	}
	actual_a, actual_b: Rect
	if SLSGetWindowBounds(state.connection, a, &actual_a) != 0 ||
	   SLSGetWindowBounds(state.connection, b, &actual_b) != 0 {
		return 1
	}
	aw := state.manager.windows[a]
	if !aw.size_feedback.width_valid ||
	   actual_a.w < 699 ||
	   math.abs(aw.frame.w - actual_a.w) > 1 ||
	   actual_b.x - actual_a.x - actual_a.w < 14 {
		size_validation_print("clamped-width-failed", &state, a, b)
		return 1
	}
	size_validation_print("clamped-width-adapted", &state, a, b)
	if find(s.view.root, a).column_size.value != 300 {
		return 1
	}
	state.manager.animation_duration = 0.5
	state.manager.scroll_time = size_validation_seconds()
	if response := execute(
		&state.manager,
		{"window", fmt.tprintf("%d", a), "--column-width", "abs:1000"},
	); response.failed {
		fmt.eprintln(response.text); return 1
	}
	intermediate := false
	focused_x := actual_b.x
	deadline := time.time_add(time.now(), time.Second)
	for time.diff(time.now(), deadline) > 0 {
		state.manager.scroll_time = size_validation_seconds()
		scroll_native_tick(&state, time.now())
		CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false)
		if SLSGetWindowBounds(state.connection, a, &actual_a) != 0 ||
		   SLSGetWindowBounds(state.connection, b, &actual_b) != 0 {
			return 1
		}
		if actual_a.w > 702 && actual_a.w < 998 {
			intermediate = true
		}
		size_validation_print("resize-sample", &state, a, b)
		if math.abs(actual_b.x - focused_x) > 2 {
			size_validation_print("focused-neighbor-moved", &state, a, b)
			return 1
		}
		frame_size_feedback_tick(&state, time.now())
		if !s.view.scroll.geometry_active && !s.view.scroll.motion.active {
			break
		}
	}
	if !intermediate || !size_validation_settle(&state, 0.4) {
		return 1
	}
	if SLSGetWindowBounds(state.connection, a, &actual_a) != 0 ||
	   math.abs(actual_a.w - 1000) > 2 {
		return 1
	}
	size_validation_print("coordinated-width-settled", &state, a, b)
	state.manager.animation_duration = 0
	if response := execute(
		&state.manager,
		{"window", fmt.tprintf("%d", a), "--column-width", "abs:1600"},
	); response.failed {
		return 1
	}
	if !size_validation_settle(&state, 0.6) {
		return 1
	}
	if SLSGetWindowBounds(state.connection, a, &actual_a) != 0 ||
	   math.abs(actual_a.w - 1200) > 1 ||
	   !aw.size_feedback.width_valid {
		return 1
	}
	if find(s.view.root, a).column_size.value != 1600 ||
	   math.abs(find(s.view.root, a).column_width - 1200) > 1 {
		return 1
	}
	size_validation_print("maximum-width-adapted", &state, a, b)
	if response := execute(
		&state.manager,
		{"window", fmt.tprintf("%d", a), "--stack", fmt.tprintf("%d", b)},
	); response.failed {
		return 1
	}
	if response := execute(
		&state.manager,
		{"window", fmt.tprintf("%d", a), "--row-height", "abs:200"},
	); response.failed {
		return 1
	}
	if !size_validation_settle(&state, 0.8) {
		return 1
	}
	if SLSGetWindowBounds(state.connection, a, &actual_a) != 0 ||
	   SLSGetWindowBounds(state.connection, b, &actual_b) != 0 {
		return 1
	}
	if !aw.size_feedback.height_valid ||
	   math.abs(actual_a.h - 280) > 1 ||
	   actual_b.y - actual_a.y - actual_a.h < 14 ||
	   aw.row_fixed != 200 {
		size_validation_print("row-height-adaptation-failed", &state, a, b)
		return 1
	}
	size_validation_print("row-height-adapted", &state, a, b)
	fmt.println(
		"PASS: foreign AX minimum/maximum width and row-height adaptation, retained requests and coordinated resize with stationary focused neighbor",
	)
	return 0
}
validate_fixture_swipe :: proc(state: ^State, s: ^Space, a, b: u32) -> int {
	m := &state.manager
	m.resize_fade = false
	set_layout(m, s, .Scroll)
	focus_window(m, a)
	m.animation_duration, m.scroll_animate = 0, true
	if flush(m, s) != "" || !size_validation_settle(state, .5) { return 1 }
	if execute(m, {"window", fmt.tprintf("%d", a), "--column-width", "abs:1000"}).failed || !size_validation_settle(state, .5) { return 1 }
	frame_a, frame_b: Rect
	if SLSGetWindowBounds(state.connection, a, &frame_a) != 0 || SLSGetWindowBounds(state.connection, b, &frame_b) != 0 { return 1 }
	base_gap := frame_b.x - frame_a.x - frame_a.w
	start_x := frame_a.x
	maximum_error: f64
	scroll_begin_pan(m, s)
	for i in 0 ..< 30 {
		m.scroll_time = size_validation_seconds()
		if err := scroll_gesture_pan(m, s.id, i < 5 ? 60 : 0); err != "" { fmt.eprintln(err); return 1 }
		if SLSGetWindowBounds(state.connection, a, &frame_a) != 0 || SLSGetWindowBounds(state.connection, b, &frame_b) != 0 { return 1 }
		gap := frame_b.x - frame_a.x - frame_a.w
		maximum_error = max(maximum_error, math.abs(gap - base_gap))
		fmt.printf("sample=%d a_x=%.1f gap=%.1f baseline=%.1f\n", i, frame_a.x, gap, base_gap)
		CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.016, false)
	}
	s.view.scroll.dragging = false
	fmt.printf("maximum transient native-bounds gap error: %.1f points\n", maximum_error)
	return maximum_error <= 16 && math.abs(frame_a.x - start_x) >= 100 ? 0 : 1
}
size_validation_seconds :: proc() -> f64 {
	return time.duration_seconds(time.diff(time.Time{}, time.now()))
}
size_validation_settle :: proc(state: ^State, seconds: f64) -> bool {
	deadline := time.time_add(time.now(), time.Duration(seconds * 1e9))
	for time.diff(time.now(), deadline) > 0 {
		CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false)
		state.manager.scroll_time = size_validation_seconds()
		scroll_native_tick(state, time.now())
		frame_size_feedback_tick(state, time.now())
		for s in state.manager.spaces {
			if flush(&state.manager, s) != "" {
				return false
			}
		}
	}
	return true
}
size_validation_print :: proc(step: string, state: ^State, a, b: u32) {
	for id in ([2]u32{a, b}) {
		actual: Rect
		code := SLSGetWindowBounds(state.connection, id, &actual)
		w := state.manager.windows[id]
		data, err := json.marshal(struct {
			at: f64,
			readback_status: i32,
			step: string,
			window: u32,
			actual, expected: Rect,
			requested_width: f64,
			adjusted: bool,
		} {
			size_validation_seconds(),
			code,
			step,
			id,
			actual,
			w.frame,
			w.size_intent.w,
			w.size_feedback.width_valid,
		})
		if err == nil {
			fmt.println(string(data)); delete(data)
		}
	}
}
