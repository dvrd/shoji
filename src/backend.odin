package shoji

import n "native"
import "base:intrinsics"
import "base:runtime"
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

Rect :: n.Rect
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
	// Hides focus feedback until startup configuration applies its style.
	focus_ring_held: bool,
	animations: map[u32]Animation_Job,
	animation_backend: Animation_Backend,
	event_sink: proc(user: rawptr, event: Event),
	event_user: rawptr,
	workspace_events: Workspace_State,
	close_focus: Close_Focus_Recovery,
	// WindowServer gate (C4). Opt-in; never required by native paths.
	ws: Ws_Adapter,
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
	return native_focus_owner(state, pid, focused) == window
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
	if action.kind == .Space && action.frame.w > 0 && state.ws.state == .Serving {
		// C4: land at the destination tile inside the move's own commit.
		// Unhandled → today's managed-space move below.
		move := ws_space_move(
			&state.ws, action.window, action.space, window_space(state, action.window),
			i32(math.round(action.frame.x)), i32(math.round(action.frame.y)),
			addition_space_transaction, nil,
		)
		if move.moved {
			state.dirty = true
			if w := state.manager.windows[action.window]; w != nil && move.placed {
				w.server_placed = true
			}
			motion_trace_record(&state.manager.motion_trace, {kind = move.placed ? "ws-space-placed" : "ws-space-moved", window = action.window, space = action.space})
			focus_ring_note_action(state, action)
			return ""
		}
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
		// C2: arm a once-only ordering receipt before activation, which can
		// itself bring the window forward (adapter only). One watch at a time.
		if superseded := ws_focus_cancel(&state.ws); superseded != 0 {
			motion_trace_record(&state.manager.motion_trace, {kind = "ws-focus-receipt-superseded", window = superseded})
		}
		receipt_generation, watching := ws_watch(&state.ws, w.id)
		if app == nil ||
		   !intrinsics.objc_send(bool, app, "activateWithOptions:", uint(2)) {
			if watching {ws_watch(&state.ws, 0)}
			return "could not activate application"
		}
		set_attribute(element, "AXMain", kCFBooleanTrue)
		raise := cf_string("AXRaise")
		defer CFRelease(raise)
		code := AXUIElementPerformAction(element, raise)
		ordered := false
		if watching {
			receipt, _ := ws_receipt(&state.ws, receipt_generation)
			ordered = receipt == .Fired
			if !ordered && code != 0 {
				// AXRaise reported an error: the receipt decides, briefly.
				ordered = ws_receipt_wait(&state.ws, receipt_generation, 50 * time.Millisecond)
			}
			if ordered || code != 0 {
				ws_watch(&state.ws, 0)
				motion_trace_record(&state.manager.motion_trace, {kind = ordered ? "ws-focus-receipt-fired" : "ws-focus-receipt-timeout", window = w.id, value = f64(code)})
			} else {
				// The app orders the window in after AXRaise returns; resolve
				// the receipt on later loop ticks instead of blocking here.
				ws_focus_pending(&state.ws, receipt_generation, w.id, time.now())
			}
		}
		if !ordered {
			if err := focus_raise_result(code, w.pid, w.id, state, native_focus_verified); err != "" {return err}
		}
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
// After a gated move WindowServer already shows the target position, so its
// bounds would make the write a no-op and leave the app's frame stale
// (c1c2-foreign-20261105). Keep the size, forget the position.
frame_write_previous :: proc(previous: Maybe(Rect), server_placed: bool) -> Maybe(Rect) {
	p, known := previous.?
	if !known || !server_placed {return previous}
	return Rect{math.INF_F64, math.INF_F64, p.w, p.h}
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
		previous = frame_write_previous(previous, w.server_placed),
		size_tolerance = scroll ? .5 : 0,
	)
	w.server_placed = false
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
