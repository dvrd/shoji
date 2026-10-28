package macos

import e "../engine"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:time"
import "core:sync"

foreign import touch_dl "system:c"
@(default_calling_convention = "c")
foreign touch_dl {
	dlopen :: proc(path: cstring, mode: i32) -> rawptr ---
	dlsym :: proc(handle: rawptr, name: cstring) -> rawptr ---
	dlclose :: proc(handle: rawptr) -> i32 ---
	sysctlbyname :: proc(name: cstring, old: rawptr, oldlen: ^uintptr, new_value: rawptr, newlen: uintptr) -> i32 ---
}

// The private contact record was checked against a read-only macOS 15.6
// trackpad probe. It is not an Apple-supported ABI.
Touch_Point :: struct { x, y: f32 }
Touch_Vector :: struct { position, velocity: Touch_Point }
Touch_Contact :: struct {
	frame: i32, timestamp: f64,
	id, stage, finger, hand: i32,
	normalized: Touch_Vector,
	size: f32, reserved: i32, angle, major, minor: f32,
	absolute: Touch_Vector,
	reserved2, reserved3: i32, density: f32,
}
Stack_Swipe_Tracker :: struct {
	sequence: u64,
	active, blocked, fired: bool,
	ids: [3]i32,
	x, y: f64,
	began: f64,
	pending: i32,
	axis: i32,
	last_x, last_time, horizontal_delta, horizontal_velocity: f64,
	horizontal_samples: e.Scroll_Velocity,
	horizontal_end: bool,
}

// Counts/positions stay in memory only; the callback does no I/O or AX work.
stack_swipe_sample :: proc(t: ^Stack_Swipe_Tracker, contacts: []Touch_Contact, now: f64) {
	if len(contacts) == 0 {
		if t.active && t.axis == 1 {
			e.scroll_velocity_add(&t.horizontal_samples, 0, now)
			t.horizontal_velocity = e.scroll_velocity_get(&t.horizontal_samples)
			t.horizontal_end = true
		}
		t.active, t.blocked, t.fired = false, false, false; return
	}
	if len(contacts) != 3 {
		if t.active {
			if t.axis == 1 {
				e.scroll_velocity_add(&t.horizontal_samples, 0, now)
				t.horizontal_velocity = e.scroll_velocity_get(&t.horizontal_samples)
				t.horizontal_end = true
			}
			t.active, t.blocked = false, true
		}
		return
	}
	if t.blocked || t.fired { return }
	ids: [3]i32; x, y: f64
	for c, i in contacts {
		if (c.stage != 3 && c.stage != 4) || math.is_nan(f64(c.normalized.position.x)) || math.is_nan(f64(c.normalized.position.y)) ||
		   c.normalized.position.x < 0 || c.normalized.position.x > 1 || c.normalized.position.y < 0 || c.normalized.position.y > 1 {
			if t.active {
				if t.axis == 1 { t.horizontal_end = true; t.horizontal_velocity = 0 }
				t.active, t.blocked = false, true
			}; return
		}
		ids[i] = c.id; x += f64(c.normalized.position.x) / 3; y += f64(c.normalized.position.y) / 3
	}
	for i in 1 ..< 3 { for j := i; j > 0 && ids[j] < ids[j-1]; j -= 1 { ids[j], ids[j-1] = ids[j-1], ids[j] } }
	if !t.active {
		t.active = true; t.ids = ids; t.x, t.y, t.began = x, y, now; t.sequence += 1
		t.axis = 0; t.last_x, t.last_time = x, now
		t.horizontal_delta, t.horizontal_velocity = 0, 0; t.horizontal_end = false
		t.horizontal_samples = {}; e.scroll_velocity_add(&t.horizontal_samples, 0, now)
		return
	}
	if ids != t.ids || now < t.began || now - t.began > 4 {
		if t.axis == 1 { t.horizontal_end = true }
		t.active, t.blocked = false, true; return
	}
	dx, dy := x - t.x, y - t.y
	if t.axis == 0 && math.abs(dx) >= .025 && math.abs(dx) > math.abs(dy) * 1.5 {
		t.axis = 1; t.last_x = t.x
	}
	if t.axis == 1 {
		delta := x - t.last_x
		e.scroll_velocity_add(&t.horizontal_samples, delta, now)
		t.horizontal_velocity = e.scroll_velocity_get(&t.horizontal_samples)
		t.horizontal_delta += delta; t.last_x, t.last_time = x, now
		return
	}
	if t.axis == 0 && math.abs(dy) >= .06 && math.abs(dy) > math.abs(dx) * 1.5 {
		t.axis = 2
		t.pending = dy > 0 ? -1 : 1
		t.fired = true
	}
}

Touch_Callback :: proc "c" (device: Ref, contacts: [^]Touch_Contact, count: uint, timestamp: f64, frame: uint)
Touch_Register :: proc "c" (device: Ref, callback: Touch_Callback)
Touch_Start :: proc "c" (device: Ref, mode: i32) -> i32
Touch_Stop :: proc "c" (device: Ref) -> i32
Touch_List :: proc "c" () -> Ref
Stack_Touch_Shared :: struct { mutex: sync.Mutex, tracker: Stack_Swipe_Tracker, enabled: bool }
stack_touch_shared: Stack_Touch_Shared
stack_touch_has_pending :: proc() -> bool {
	sync.mutex_lock(&stack_touch_shared.mutex)
	defer sync.mutex_unlock(&stack_touch_shared.mutex)
	t := &stack_touch_shared.tracker
	return stack_touch_shared.enabled && (t.horizontal_delta != 0 || t.horizontal_end || t.pending != 0)
}
Stack_Touch_State :: struct {
	library, devices, device: Ref,
	unregister: Touch_Register,
	stop: Touch_Stop,
	attempted: bool,
	sequence: u64,
	focus: u32,
	generation: u64,
	horizontal_space: u64,
	horizontal_layout: e.Layout,
	horizontal_active, horizontal_switched: bool,
	horizontal_travel: f64,
	horizontal_direction: i32,
}

stack_touch_callback :: proc "c" (_: Ref, contacts: [^]Touch_Contact, count: uint, timestamp: f64, _: uint) {
	context = runtime.default_context()
	if count > 32 || (count > 0 && contacts == nil) { return }
	sync.mutex_lock(&stack_touch_shared.mutex)
	defer sync.mutex_unlock(&stack_touch_shared.mutex)
	if stack_touch_shared.enabled { stack_swipe_sample(&stack_touch_shared.tracker, contacts[:int(count)], timestamp) }
}

stack_touch_start :: proc(state: ^State) -> bool {
	t := &state.stack_touch
	// Contact structure offsets are validated only on this host build.
	build: [32]u8; length := uintptr(len(build))
	if sysctlbyname("kern.osversion", &build[0], &length, nil, 0) != 0 ||
	   length == 0 || length > uintptr(len(build)) || string(cstring(&build[0])) != "24G84" {
		return false
	}
	t.library = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", 2)
	if t.library == nil { return false }
	list := cast(Touch_List)dlsym(t.library, "MTDeviceCreateList")
	register := cast(Touch_Register)dlsym(t.library, "MTRegisterContactFrameCallback")
	t.unregister = cast(Touch_Register)dlsym(t.library, "MTUnregisterContactFrameCallback")
	start := cast(Touch_Start)dlsym(t.library, "MTDeviceStart")
	t.stop = cast(Touch_Stop)dlsym(t.library, "MTDeviceStop")
	if list == nil || register == nil || t.unregister == nil || start == nil || t.stop == nil { stack_touch_stop(state); return false }
	t.devices = list()
	// Only the one-device configuration tested on the host is enabled.
	if t.devices == nil || CFArrayGetCount(t.devices) != 1 { stack_touch_stop(state); return false }
	t.device = CFArrayGetValueAtIndex(t.devices, 0)
	if t.device == nil { stack_touch_stop(state); return false }
	sync.mutex_lock(&stack_touch_shared.mutex)
	stack_touch_shared.tracker = {}; stack_touch_shared.enabled = true
	sync.mutex_unlock(&stack_touch_shared.mutex)
	register(t.device, stack_touch_callback)
	if start(t.device, 0) != 0 { stack_touch_stop(state); return false }
	return true
}

stack_touch_stop :: proc(state: ^State) {
	t := &state.stack_touch
	if t.horizontal_active {
		if s := e.space_by_id(&state.manager, t.horizontal_space); s != nil { s.view.scroll.dragging = false }
	}
	sync.mutex_lock(&stack_touch_shared.mutex)
	stack_touch_shared.enabled = false; stack_touch_shared.tracker = {}
	sync.mutex_unlock(&stack_touch_shared.mutex)
	if t.device != nil && t.unregister != nil { t.unregister(t.device, stack_touch_callback) }
	if t.device != nil && t.stop != nil { _ = t.stop(t.device) }
	if t.devices != nil { CFRelease(t.devices) }
	if t.library != nil { _ = dlclose(t.library) }
	t^ = {}
}

stack_touch_tick :: proc(state: ^State) {
	t := &state.stack_touch; m := &state.manager
	if !m.mouse.stack_swipe && !m.mouse.three_finger_horizontal {
		if t.library != nil || t.attempted { stack_touch_stop(state) }
		return
	}
	if !t.attempted {
		t.attempted = true
		if !stack_touch_start(state) { t.attempted = true; fmt.eprintln("shoji: three-finger stack gesture unavailable"); return }
	}
	if t.library == nil { return }
	sync.mutex_lock(&stack_touch_shared.mutex)
	tracker := &stack_touch_shared.tracker
	seq, direction := tracker.sequence, tracker.pending
	delta, velocity, ended := tracker.horizontal_delta, tracker.horizontal_velocity, tracker.horizontal_end
	stack_touch_shared.tracker.pending = 0
	tracker.horizontal_delta, tracker.horizontal_end = 0, false
	sync.mutex_unlock(&stack_touch_shared.mutex)
	if seq != t.sequence {
		if t.horizontal_active {
			if old := e.space_by_id(m, t.horizontal_space); old != nil { old.view.scroll.dragging = false }
		}
		t.sequence = seq; t.focus = m.focused
		w := m.windows[t.focus]; t.generation = w != nil ? w.generation : 0
		t.horizontal_space = m.active_space
		s := e.space_by_id(m, t.horizontal_space)
		t.horizontal_layout = s != nil ? s.view.layout : .Float
		t.horizontal_active, t.horizontal_switched, t.horizontal_travel, t.horizontal_direction = false, false, 0, 0
		// Require a main-loop observation of the beginning before accepting.
		if direction != 0 { return }
	}
	if m.mouse.stack_swipe { stack_swipe_apply(state, t.focus, t.generation, direction) }
	if m.mouse.three_finger_horizontal {
		stack_touch_horizontal(state, delta, velocity, ended)
	} else if t.horizontal_active {
		if s := e.space_by_id(m, t.horizontal_space); s != nil { s.view.scroll.dragging = false }
		t.horizontal_active = false
	}
}

stack_touch_horizontal :: proc(state: ^State, delta, velocity: f64, ended: bool) {
	t := &state.stack_touch; m := &state.manager
	s := e.space_by_id(m, t.horizontal_space)
	if s == nil || !s.visible || s.view.layout != t.horizontal_layout || m.suspended || m.gesture_active || state.mouse.drag.window != 0 {
		if s != nil && t.horizontal_active { s.view.scroll.dragging = false }
		t.horizontal_active = false; return
	}
	if s.view.layout == .BSP {
		t.horizontal_travel -= delta
		if !t.horizontal_switched && math.abs(t.horizontal_travel) >= .08 {
			t.horizontal_switched = true
			if err := e.space_gesture_switch(m, s.id, t.horizontal_travel > 0 ? 1 : -1); err != "" { fmt.eprintln("shoji: three-finger Space swipe:", err) }
		}
		return
	}
	if s.view.layout != .Scroll { return }
	if delta != 0 {
		t.horizontal_travel -= delta
		if math.abs(delta) >= .001 { t.horizontal_direction = delta > 0 ? -1 : 1 }
		if !t.horizontal_active { e.scroll_begin_pan(m, s); t.horizontal_active = true }
		if err := e.scroll_gesture_pan(m, s.id, -delta * s.view.scroll.viewport.w * 1.2); err != "" {
			fmt.eprintln("shoji: three-finger scroll:", err); s.view.scroll.dragging = false; t.horizontal_active = false; return
		}
	}
	if ended && t.horizontal_active {
		t.horizontal_active = false
		release_velocity := clamp(-velocity * s.view.scroll.viewport.w * 1.2, -s.view.scroll.viewport.w * .75, s.view.scroll.viewport.w * .75)
		// A slow lift can report zero velocity after reaching the viewport
		// boundary. Preserve travel direction when choosing the visible focus.
		if math.abs(release_velocity) < 120 && t.horizontal_direction != 0 {
			release_velocity = f64(t.horizontal_direction) * max(.01, math.abs(release_velocity))
		}
		step: i32
		if math.abs(t.horizontal_travel) >= .025 { step = t.horizontal_travel > 0 ? 1 : -1 }
		if err := e.scroll_finish_pan(m, s, release_velocity, true, step); err != "" { fmt.eprintln("shoji: three-finger scroll release:", err) }
	}
}

stack_swipe_apply :: proc(state: ^State, focus: u32, generation: u64, direction: i32) {
	m := &state.manager
	if direction == 0 || m.suspended || m.gesture_active || state.mouse.drag.window != 0 || focus != m.focused { return }
	w := m.windows[focus]
	if w == nil || w.generation != generation { return }
	s := e.space_by_id(m, w.space)
	if s == nil || !s.visible || s.view.layout != .BSP { return }
	n := e.find(s.view.root, w.id)
	if n == nil || n.count < 2 { return }
	selector := direction > 0 ? "stack.next" : "stack.prev"
	if target := e.select_window(m, selector); target != nil {
		response := e.execute(m, {"window", "--focus", selector})
		if response.failed { fmt.eprintln("shoji: stack swipe:", response.text) }
	}
}

// Pointer interaction
// ------------------------------------------------------------------------

foreign import mouse_cg "system:CoreGraphics.framework"
foreign import mouse_cf "system:CoreFoundation.framework"
foreign import mouse_sls "system:SkyLight.framework"
foreign mouse_sls {
	SLSFindWindowAndOwner :: proc "c" (connection: i32, relative: u32, mode, options: i32, point, local: ^Point, window: ^u32, owner: ^i32) -> i32 ---
}
Mouse_Callback :: proc "c" (
	proxy: Ref,
	type: u32,
	event: Ref,
	user: rawptr,
) -> Ref
@(default_calling_convention = "c")
foreign mouse_cg {
	CGEventTapCreate :: proc(location, placement, options: u32, mask: u64, callback: Mouse_Callback, user: rawptr) -> Ref ---
	CGEventTapEnable :: proc(tap: Ref, enabled: bool) ---
	CGEventTapPostEvent :: proc(proxy, event: Ref) ---
	CGEventGetLocation :: proc(event: Ref) -> Point ---
	CGEventGetFlags :: proc(event: Ref) -> u64 ---
	CGEventGetIntegerValueField :: proc(event: Ref, field: u32) -> i64 ---
	CGWarpMouseCursorPosition :: proc(point: Point) -> i32 ---
	CGEventCreate :: proc(source: Ref) -> Ref ---
}
@(default_calling_convention = "c")
foreign mouse_cf {
	CFMachPortCreateRunLoopSource :: proc(allocator, port: Ref, order: int) -> Ref ---
	CFMachPortInvalidate :: proc(port: Ref) ---
}
Drag_Phase :: enum {
	Idle,
	Pressed,
	Dragging,
	Released_Click,
	Released_Drag,
}
Drag_Mode :: enum {
	Managed,
	Native_Resize,
}

Mouse_State :: struct {
	edge: e.Drag_Edge,
	scroll: e.Scroll_Gesture,
	scroll_delta: f64,
	scroll_velocity: e.Scroll_Velocity,
	scroll_tracking, scroll_begin, scroll_end, scroll_phase_less: bool,
	scroll_last: f64,
	space_origin: u64,
	space_direction: int,
	mode: Drag_Mode,
	phase: Drag_Phase,
	resize_frame: proc(state: ^State, window: u32) -> (e.Rect, bool),
	hit_test: proc(state: ^State, point: e.Mouse_Point) -> u32,
	gesture: bool,
	gesture_ended: time.Time,
	tap, source, down: Ref,
	drag: e.Mouse_Drag,
	point: e.Mouse_Point,
	target, hover, last_hover, last_focused, hover_focused: u32,
	buttons: u8,
	button: u32,
	pending, failed, hover_pending: bool,
	hover_point: e.Mouse_Point,
	tab_pressed, tab_pending: u32,
	tab_generation, tab_pending_generation: u64,
	edge_double_button, edge_double_pending: u32,
	edge_double_generation: u64,
	edge_double_horizontal: bool,
}

tab_indicator_hit :: proc(state: ^State, point: e.Mouse_Point) -> e.Tab_Indicator {
	indicator := &state.tab_indicator
	for i in 0 ..< indicator.count {
		tab := indicator.tabs[i]; r := tab.frame
		if indicator.bars[i].surface.id != 0 && point.x >= r.x && point.x < r.x + r.w && point.y >= r.y && point.y < r.y + r.h {
			return tab
		}
	}
	return {}
}
mouse_drag_moved :: proc(mouse: ^Mouse_State) -> bool {
	return mouse.phase == .Dragging || mouse.phase == .Released_Drag
}
mouse_drag_finished :: proc(mouse: ^Mouse_State) -> bool {
	return mouse.phase == .Released_Click || mouse.phase == .Released_Drag
}
// Mouse-up relinquishes the retained event and grab, but native resize
// ownership lasts through the final geometry update in mouse_tick.
mouse_drag_release :: proc(state: ^State) {
	mouse := &state.mouse
	if w := state.manager.windows[mouse.drag.window]; w != nil {
		w.grabbed = false
	}
	if mouse.down != nil {
		CFRelease(mouse.down); mouse.down = nil
	}
}
mouse_drag_reset :: proc(state: ^State) {
	mouse := &state.mouse
	mouse_drag_release(state)
	state.manager.native_resize_window = 0
	mouse.drag = {}; mouse.phase = .Idle; mouse.mode = .Managed
	mouse.edge = {}
	mouse.pending = false; mouse.failed = false
}

mouse_native_resize_frame :: proc(
	state: ^State,
	window: u32,
) -> (
	frame: e.Rect,
	known: bool,
) {
	if state.mouse.resize_frame != nil {
		return state.mouse.resize_frame(state, window)
	}
	known = SLSGetWindowBounds(state.connection, window, &frame) == 0
	return
}
mouse_window_at_point :: proc(state: ^State, point: e.Mouse_Point) -> u32 {
	if state.mouse.hit_test != nil {
		return state.mouse.hit_test(state, point)
	}
	if state.connection == 0 {
		return 0
	}
	location := Point{point.x, point.y}
	local: Point; window: u32; owner: i32
	if SLSFindWindowAndOwner(
		   state.connection,
		   0,
		   1,
		   0,
		   &location,
		   &local,
		   &window,
		   &owner,
	   ) !=
	   0 {
		return 0
	}
	// Feedback and animation surfaces belong to our connection; look beneath
	// them rather than mistaking a proxy for the application window.
	for _ in 0 ..< 64 {
		if owner != state.connection {
			return window
		}
		previous := window
		if SLSFindWindowAndOwner(
			   state.connection,
			   window,
			   -1,
			   0,
			   &location,
			   &local,
			   &window,
			   &owner,
		   ) !=
		   0 {
			return 0
		}
		if window == 0 || window == previous {
			return 0
		}
	}
	return 0
}
mouse_start :: proc(state: ^State) {
	mask: u64 =
		(1 << 1) |
		(1 << 2) |
		(1 << 3) |
		(1 << 4) |
		(1 << 5) |
		(1 << 6) |
		(1 << 7) |
		(1 << 22) |
		(1 << 30)
	mouse := &state.mouse
	mouse.tap = CGEventTapCreate(1, 0, 0, mask, mouse_callback, state)
	if mouse.tap == nil {
		fmt.eprintln(
			"shoji: mouse event tap unavailable; mouse controls are disabled",
		); return
	}
	mouse.source = CFMachPortCreateRunLoopSource(nil, mouse.tap, 0)
	if mouse.source == nil {
		CFMachPortInvalidate(mouse.tap); CFRelease(mouse.tap); mouse.tap = nil
		return
	}
	CFRunLoopAddSource(CFRunLoopGetMain(), mouse.source, kCFRunLoopDefaultMode)
	CGEventTapEnable(mouse.tap, true)
}
mouse_stop :: proc(state: ^State) {
	mouse := &state.mouse
	stack_touch_stop(state)
	mouse_drag_reset(state)
	if mouse.tap != nil {
		CGEventTapEnable(mouse.tap, false); CFMachPortInvalidate(mouse.tap)
	}
	if mouse.source != nil {
		CFRunLoopRemoveSource(
			CFRunLoopGetMain(),
			mouse.source,
			kCFRunLoopDefaultMode,
		); CFRelease(mouse.source)
	}
	if mouse.tap != nil {
		CFRelease(mouse.tap)
	}
	mouse^ = {}
}
mouse_callback :: proc "c" (
	proxy: Ref,
	type: u32,
	event: Ref,
	user: rawptr,
) -> Ref {
	context = runtime.default_context()
	state := (^State)(user); mouse := &state.mouse
	if type == 1 || type == 3 || type == 25 {
		state.resize_cover_cancel = true
	}
	if type == 30 {
		mouse_gesture_record(
			state,
			CGEventGetIntegerValueField(event, 110),
			CGEventGetIntegerValueField(event, 123),
			CGEventGetIntegerValueField(event, 132),
			time.now(),
		)
		return event
	}
	if type == 0xfffffffe || type == 0xffffffff {
		if mouse.down != nil && mouse.mode != .Native_Resize {
			CGEventTapPostEvent(proxy, mouse.down)
		}
		mouse_drag_reset(state)
		mouse.buttons = 0; mouse.tab_pressed = 0; mouse.edge_double_button = 0
		CGEventTapEnable(mouse.tap, true); return event
	}
	if mouse.tab_pressed != 0 && (type == 2 || type == 6) {
		if type == 2 {
			location := CGEventGetLocation(event)
			tab := tab_indicator_hit(state, {location.x, location.y})
			if tab.window == mouse.tab_pressed && tab.generation == mouse.tab_generation {
				mouse.tab_pending, mouse.tab_pending_generation = tab.window, tab.generation
			}
			mouse.tab_pressed = 0
		}
		return nil
	}
	if mouse.edge_double_button != 0 &&
	   (type == mouse.edge_double_button + 1 ||
		   (mouse.edge_double_button == 1 && type == 6) ||
		   (mouse.edge_double_button == 3 && type == 7)) {
		if type == mouse.edge_double_button + 1 { mouse.edge_double_button = 0 }
		return nil
	}
	if (state.manager.suspended || state.manager.gesture_active) &&
	   mouse.drag.window == 0 &&
	   !(type == 22 && mouse.scroll.owned && !state.manager.suspended) {
		return event
	}
	location := CGEventGetLocation(event)
	point := e.Mouse_Point{location.x, location.y}
	if type == 1 && mouse.drag.window == 0 && mouse.buttons == 0 && CGEventGetFlags(event) & e.MOUSE_MODIFIERS == 0 {
		if tab := tab_indicator_hit(state, point); tab.window != 0 {
			mouse.tab_pressed, mouse.tab_generation = tab.window, tab.generation
			return nil
		}
	}
	target := u32(CGEventGetIntegerValueField(event, 91))
	// Session event taps can receive zero in the private window-ID fields.
	// Resolve the real hit at click time instead of forwarding a tiled resize
	// to the app and later fighting it in the periodic layout pass.
	if target == 0 &&
	   (type == 1 ||
			   type == 3 ||
			   (type == 5 && state.manager.mouse.focus != .Off) ||
			   ((type == 2 || type == 4) && mouse.drag.action == .Move)) {
		target = mouse_window_at_point(state, point)
	}
	state.manager.mouse_window = target
	state.manager.mouse_display = 0
	for display in state.manager.displays {
		if point.x >= display.frame.x &&
		   point.x < display.frame.x + display.frame.w &&
		   point.y >= display.frame.y &&
		   point.y < display.frame.y + display.frame.h {
			state.manager.mouse_display = display.id; break
		}
	}
	switch type {
	case 22:
		if mouse_scroll_event(state, event, time.now()) {
			return nil
		}
	case 1, 3:
		e.opening_note_focus(&state.manager, target, true)
		modifiers := CGEventGetFlags(event) & e.MOUSE_MODIFIERS
		if CGEventGetIntegerValueField(event, 1) == 2 &&
		   mouse.drag.window == 0 && mouse.buttons == 0 &&
		   ((type == 1 && modifiers == 0) ||
			   (type == 3 && modifiers == state.manager.mouse.modifier && state.manager.mouse.action2 == .Resize)) {
			w := state.manager.windows[target]
			if w != nil {
				s := e.space_by_id(&state.manager, w.space)
				edge := e.mouse_border_resize(&state.manager, target, point)
				if s != nil && s.view.layout == .Scroll && edge.window != 0 && edge.lock_x != edge.lock_y {
					mouse.edge_double_button, mouse.edge_double_pending = type, target
					mouse.edge_double_generation = w.generation
					mouse.edge_double_horizontal = !edge.lock_x
					return nil
				}
			}
		}
		mouse.buttons |= type == 1 ? u8(1) : u8(2)
		if mouse.drag.window != 0 {
			return event
		}
		job, animating := state.animations[target]
		w := state.manager.windows[target]
		if animating &&
		   animation_is_live(job) &&
		   animation_matches(state, target, job) {
			w.frame = job.presentation.(Live_Resize).current
		}
		drag: e.Mouse_Drag
		native_resize := false
		if type == 1 && modifiers == 0 {
			drag = e.mouse_border_resize(&state.manager, target, point)
			native_resize = drag.window != 0
		}
		if drag.window == 0 && modifiers == state.manager.mouse.modifier {
			action :=
				type == 1 \
					? state.manager.mouse.action1 \
					: state.manager.mouse.action2
			drag = e.mouse_begin(&state.manager, target, action, point)
		}
		if animating &&
		   animation_is_live(job) &&
		   animation_matches(state, target, job) {
			if drag.window != 0 {
				// A new drag starts from the last real frame, without jumping
				// to the old animation's destination first.
				delete_key(&state.animations, target)
			} else {
				w.frame = job.target
			}
		}
		when #config(SHOJI_MOUSE_TRACE, false) {
			fmt.eprintf(
				"shoji: mouse-down target=%d alternate=%d point=(%g,%g) modifiers=%d captured=%d\n",
				target,
				CGEventGetIntegerValueField(event, 92),
				point.x,
				point.y,
				modifiers,
				drag.window,
			)
			if w := state.manager.windows[target]; w != nil {
				fmt.eprintf(
					"shoji: mouse-target frame=(%g,%g,%g,%g) space=%d floating=%v\n",
					w.frame.x,
					w.frame.y,
					w.frame.w,
					w.frame.h,
					w.space,
					w.floating,
				)
			}
		}
		if drag.window == 0 {
			return event
		}
		mouse.hover_pending = false
		mouse.drag = drag; mouse.point = point; mouse.target = target
		mouse.mode = native_resize ? .Native_Resize : .Managed
		state.manager.native_resize_window = native_resize ? drag.window : 0
		mouse.button = type
		if w := state.manager.windows[drag.window]; w != nil {
			w.grabbed = true
		}
		mouse.phase = .Pressed; mouse.failed = false
		mouse.pending = false
		mouse.down = CFRetain(event)
		return native_resize ? event : nil
	case 2, 4:
		mouse.buttons &= ~(type == 2 ? u8(1) : u8(2))
		if mouse.down == nil || type != mouse.button + 1 {
			return event
		}
		mouse.point = point; mouse.target = target
		mouse.phase =
			mouse_drag_moved(mouse) ? .Released_Drag : .Released_Click
		mouse.pending = true

		if !mouse_drag_moved(mouse) && mouse.mode != .Native_Resize {
			CGEventTapPostEvent(proxy, mouse.down)
			CGEventTapPostEvent(proxy, event)
		}
		mouse_drag_release(state)
		return mouse.mode == .Native_Resize ? event : nil
	case 6, 7:
		if mouse.down == nil || (type == 6 ? u32(1) : u32(3)) != mouse.button {
			return event
		}
		mouse.point = point; mouse.target = target
		if math.abs(point.x - mouse.drag.origin.x) +
			   math.abs(point.y - mouse.drag.origin.y) >=
		   3 {
			mouse.phase = .Dragging
		}
		mouse.pending = mouse_drag_moved(mouse)
		return mouse.mode == .Native_Resize ? event : nil
	case 5:
		if mouse.buttons != 0 || mouse.drag.window != 0 {
			return event
		}
		if CGEventGetFlags(event) & e.MOUSE_MODIFIERS ==
		   state.manager.mouse.modifier {
			return event
		}
		mouse.hover = target; mouse.hover_point = point
		mouse.hover_pending = true
	}
	return event
}
mouse_tick :: proc(
	state: ^State,
	present_scroll: bool = true,
	scroll_now: time.Time = {},
) {
	mouse := &state.mouse; m := &state.manager
	if present_scroll { stack_touch_tick(state) }
	if mouse.edge_double_pending != 0 {
		id, generation, horizontal := mouse.edge_double_pending, mouse.edge_double_generation, mouse.edge_double_horizontal
		mouse.edge_double_pending = 0
		if w := m.windows[id]; w != nil && w.generation == generation && !m.suspended && !m.gesture_active {
			s := e.space_by_id(m, w.space)
			if s != nil && s.visible && s.view.layout == .Scroll && e.find(s.view.root, id) != nil {
				operation := horizontal ? "--toggle" : "--row-height"
				operand := horizontal ? "column-full-width" : "auto"
				if response := e.execute(m, {"window", fmt.tprintf("%d", id), operation, operand}); response.failed {
					fmt.eprintln("shoji: resize edge double-click:", response.text)
				}
			}
		}
	}
	if mouse.tab_pending != 0 {
		id, generation := mouse.tab_pending, mouse.tab_pending_generation
		mouse.tab_pending = 0
		current := false
		for i in 0 ..< state.tab_indicator.count {
			tab := state.tab_indicator.tabs[i]
			if tab.window == id && tab.generation == generation && state.tab_indicator.bars[i].surface.id != 0 {
				current = true; break
			}
		}
		focused := m.windows[m.focused]
		if focused == nil {
			current = false
		} else if s := e.space_by_id(m, focused.space); s == nil || !s.visible || s.view.layout != .Scroll {
			current = false
		} else {
			n := e.find(s.view.root, focused.id)
			current = current && n != nil && n.column_tabbed && e.find(s.view.root, id) == n
		}
		if w := m.windows[id]; current && w != nil && w.generation == generation && !m.suspended && !m.gesture_active {
			if response := e.execute(m, {"window", fmt.tprintf("%d", id), "--focus"}); response.failed {
				fmt.eprintln("shoji: tab focus:", response.text)
			}
		}
	}
	mouse_gesture_tick(state, time.now())
	if !m.mouse.scroll {
		mouse.scroll_delta = 0; mouse.scroll.owned = false
		mouse.space_direction = 0
		if s := e.space_by_id(m, mouse.scroll.space); s != nil {
			s.view.scroll.dragging = false
		}
		mouse.scroll_tracking, mouse.scroll_begin, mouse.scroll_end =
			false, false, false
	}
	if mouse.space_direction != 0 {
		direction := mouse.space_direction
		mouse.space_direction = 0
		if err := e.space_gesture_switch(m, mouse.space_origin, direction);
		   err != "" {
			fmt.eprintln("shoji: Space gesture:", err)
		}
	}
	if present_scroll {
		scroll_now := scroll_now
		if scroll_now == (time.Time{}) {
			scroll_now = time.now()
		}
		scroll_input_tick(state, scroll_now)
	}
	if m.suspended || m.gesture_active {
		mouse.edge = {}; mouse.failed = true; return
	}
	if !present_scroll &&
	   mouse.drag.window != 0 &&
	   !mouse_drag_finished(mouse) {
		return
	}
	if mouse.drag.window != 0 {
		if mouse.drag.action == .Move &&
		   mouse_drag_moved(mouse) &&
		   !mouse.failed {
			mouse.target = e.drag_target_at(m, mouse.drag, mouse.point)
		}
		if mouse_drag_moved(mouse) &&
		   !mouse_drag_finished(mouse) &&
		   !mouse.failed {
			now := scroll_now
			if now == (time.Time{}) {
				now = time.now()
			}
			moved, err := e.drag_edge_scroll(
				m,
				&mouse.edge,
				mouse.drag,
				mouse.point,
				time.duration_seconds(time.diff(time.Time{}, now)),
			)
			if err != "" {
				fmt.eprintln("shoji: edge scroll:", err); mouse.failed = true
			}
			if moved {
				mouse.target = e.drag_target_at(m, mouse.drag, mouse.point)
			}
		} else {
			mouse.edge = {}
		}
		if mouse.mode == .Native_Resize &&
		   mouse_drag_moved(mouse) &&
		   !mouse.failed {
			mouse.pending = true
		}
		if mouse.pending && mouse_drag_moved(mouse) && !mouse.failed {
			point := mouse.point
			err: string
			if mouse.mode == .Native_Resize {
				if observed, known := mouse_native_resize_frame(
					state,
					mouse.drag.window,
				); known {
					resize_cover_frame(
						state,
						mouse.drag.window,
						observed,
						mouse.drag.frame,
						CACurrentMediaTime(),
					)
					// AppKit owns the live drag. Follow accepted geometry, including
					// app minimum sizes, instead of sending competing AX writes.
					d := mouse.drag
					point = {
						d.origin.x +
						(d.left \
									? observed.x - d.frame.x \
									: observed.w - d.frame.w),
						d.origin.y +
						(d.top \
									? observed.y - d.frame.y \
									: observed.h - d.frame.h),
					}
				} else {
					err = "could not observe native resize frame"
				}
			}
			if err == "" {
				err = frame_updates_begin(state)
			}
			if err == "" {
				err = e.mouse_update(m, &mouse.drag, point)
				present := frame_updates_end(state)
				if err == "" {
					err = present
				}
			}
			if err == "" && mouse_drag_finished(mouse) {
				m.native_resize_window = 0
				err = e.mouse_drop(m, mouse.drag, mouse.target, mouse.point)
			}
			if err != "" {
				fmt.eprintln("shoji: mouse:", err); mouse.failed = true
			}
			mouse.pending = false
		}
		if mouse_drag_finished(mouse) {
			mouse_drag_reset(state)
		}
		return
	}
	if !mouse.hover_pending {
		return
	}
	mouse.hover_pending = false
	if m.mouse.focus == .Off {
		mouse.last_hover = 0; return
	}
	if mouse.hover == mouse.last_hover {
		return
	}
	mouse.last_hover = mouse.hover
	w := m.windows[mouse.hover]
	if w == nil ||
	   w.id == m.focused ||
	   w.hidden ||
	   w.minimized ||
	   w.fullscreen {
		return
	}
	s := e.space_by_id(m, w.space)
	if s == nil || !s.visible {
		return
	}
	if s.view.layout == .Scroll &&
	   (s.view.scroll.motion.active || s.view.scroll.dragging) {
		return
	}
	kind :=
		m.mouse.focus == .Autofocus \
			? e.Action_Kind.Focus_Without_Raise \
			: e.Action_Kind.Focus
	if err := perform(state, {kind = kind, window = w.id}); err != "" {
		fmt.eprintln("shoji: focus follows mouse:", err); return
	}
	mouse.hover_focused = w.id
}
mouse_follow_focus :: proc(state: ^State) {
	mouse := &state.mouse; m := &state.manager
	if m.suspended || m.gesture_active {
		return
	}
	if m.focused == mouse.last_focused {
		return
	}
	mouse.last_focused = m.focused
	if mouse.hover_focused == m.focused {
		mouse.hover_focused = 0; return
	}
	mouse.hover_focused = 0
	w := m.windows[m.focused]
	if w == nil || w.hidden || w.minimized {
		return
	}
	if !e.pointer_follows_focus(m, w) ||
	   mouse.buttons != 0 ||
	   mouse.drag.window != 0 {
		return
	}
	current := CGEventCreate(nil)
	if current == nil {
		return
	}; defer CFRelease(current)
	point := CGEventGetLocation(current)
	if point.x >= w.frame.x &&
	   point.x < w.frame.x + w.frame.w &&
	   point.y >= w.frame.y &&
	   point.y < w.frame.y + w.frame.h {
		return
	}
	CGWarpMouseCursorPosition(
		{w.frame.x + w.frame.w / 2, w.frame.y + w.frame.h / 2},
	)
}

mouse_gesture_tick :: proc(state: ^State, now: time.Time) {
	mouse := &state.mouse
	if state.manager.gesture_active &&
	   !mouse.gesture &&
	   time.diff(mouse.gesture_ended, now) >= 250 * time.Millisecond {
		state.manager.gesture_active = false
		state.dirty = true
	}
}

mouse_gesture_record :: proc(
	state: ^State,
	kind, motion, phase: i64,
	now: time.Time,
) {
	if kind != 23 || motion != 1 {
		return
	}
	mouse := &state.mouse
	if phase == 1 {
		mouse.gesture = true; state.manager.gesture_active = true
		mouse.failed = true
	}
	if phase == 4 || phase == 8 {
		mouse.gesture = false; mouse.gesture_ended = now
	}
}

// Scroll layout and viewport
// ------------------------------------------------------------------------

foreign import scroll_cg "system:CoreGraphics.framework"
foreign scroll_cg {
	CGEventGetTimestamp :: proc "c" (event: Ref) -> u64 ---
}

mouse_scroll_event :: proc(state: ^State, event: Ref, now: time.Time) -> bool {
	m := &state.manager
	space := u64(0)
	layout := e.Layout.Float
	if display := e.display_by_id(m, m.mouse_display); display != nil {
		if s := e.space_by_id(m, display.active_space);
		   s != nil && (s.view.layout == .Scroll || s.view.layout == .BSP) {
			space = s.id
			layout = s.view.layout
		}
	}
	// CGEventTypes.h: continuous events report pixel deltas; ordinary wheels
	// report lines. Use exactly one representation, never sum both fields.
	continuous := CGEventGetIntegerValueField(event, 88) != 0
	xfield, yfield := u32(12), u32(11)
	if continuous {
		xfield, yfield = 97, 96
	}
	x := f64(CGEventGetIntegerValueField(event, xfield))
	y := f64(CGEventGetIntegerValueField(event, yfield))
	if !continuous {
		x *= 24; y *= 24
	}
	old_space := state.mouse.scroll.space
	phase := u64(CGEventGetIntegerValueField(event, 99))
	momentum := CGEventGetIntegerValueField(event, 123)
	seconds := time.duration_seconds(time.diff(time.Time{}, now))
	event_seconds := f64(CGEventGetTimestamp(event)) / 1e9
	consume, delta, direction := e.layout_gesture_route(
		&state.mouse.scroll,
		{x, y, CGEventGetFlags(event) & e.MOUSE_MODIFIERS, phase, momentum},
		space,
		layout,
		m.mouse.modifier,
		m.mouse.scroll && !(m.mouse.three_finger_horizontal && state.stack_touch.library != nil),
		seconds,
	)
	if consume {
		e.motion_trace_record(
			&m.motion_trace,
			{
				kind = "input",
				source_time = event_seconds,
				space = state.mouse.scroll.space,
				value = delta,
			},
		)
		if old_space != state.mouse.scroll.space {
			state.mouse.scroll_delta = 0
		}
		if state.mouse.scroll.layout == .Scroll && momentum == 0 {
			mouse := &state.mouse
			if !mouse.scroll_tracking ||
			   old_space != mouse.scroll.space ||
			   phase & 1 != 0 {
				mouse.scroll_velocity = {}
				mouse.scroll_delta = 0
				mouse.scroll_tracking, mouse.scroll_begin, mouse.scroll_end =
					true, true, false
			}
			mouse.scroll_phase_less = phase == 0
			if continuous {
				if s := e.space_by_id(m, mouse.scroll.space); s != nil {
					delta *= s.view.scroll.viewport.w / 1200
				}
			}
			mouse.scroll_delta += delta
			e.scroll_velocity_add(&mouse.scroll_velocity, delta, event_seconds)
			mouse.scroll_last = seconds
			if phase & (4 | 8) != 0 {
				mouse.scroll_end = true
			}
		}
		if direction != 0 && state.mouse.space_direction == 0 {
			state.mouse.space_origin = state.mouse.scroll.space
			state.mouse.space_direction = direction
		}
	}
	return consume
}

scroll_input_tick :: proc(state: ^State, now: time.Time) {
	mouse := &state.mouse
	if !mouse.scroll_tracking {
		return
	}
	m := &state.manager
	s := e.space_by_id(m, mouse.scroll.space)
	if s == nil ||
	   !s.visible ||
	   s.view.layout != .Scroll ||
	   m.suspended ||
	   m.gesture_active {
		if s != nil {
			s.view.scroll.dragging = false
		}
		mouse.scroll_tracking, mouse.scroll_begin, mouse.scroll_end =
			false, false, false
		mouse.scroll_delta = 0
		return
	}
	seconds := time.duration_seconds(time.diff(time.Time{}, now))
	if (mouse.scroll_phase_less && seconds - mouse.scroll_last >= 0.12) ||
	   seconds - mouse.scroll_last > 1 {
		e.scroll_velocity_add(&mouse.scroll_velocity, 0, seconds)
		mouse.scroll_end = true
	}
	if !mouse.scroll_begin && mouse.scroll_delta == 0 && !mouse.scroll_end {
		return
	}
	if err := frame_updates_begin(state); err != "" {
		fmt.eprintln("shoji: scroll:", err); return
	}
	defer {
		if err := frame_updates_end(state); err != "" {
			fmt.eprintln("shoji: scroll:", err)
		}
	}
	started: time.Tick
	if m.motion_trace.active {
		started = time.tick_now()
	}
	defer e.motion_trace_record(
		&m.motion_trace,
		{
			kind = "gesture-sample",
			space = s.id,
			duration_ms = m.motion_trace.active \
				? f64(time.tick_since(started)) / 1e6 \
				: 0,
		},
	)
	e.motion_trace_record(
		&m.motion_trace,
		{kind = "input-consume", space = s.id, value = mouse.scroll_delta},
	)
	if mouse.scroll_begin {
		e.scroll_begin_pan(m, s); mouse.scroll_begin = false
	}
	delta := mouse.scroll_delta; mouse.scroll_delta = 0
	if delta != 0 {
		if err := e.scroll_gesture_pan(m, s.id, delta); err != "" {
			fmt.eprintln("shoji: scroll:", err); s.view.scroll.dragging = false
			mouse.scroll_tracking = false; return
		}
	}
	if mouse.scroll_end {
		mouse.scroll_end, mouse.scroll_tracking = false, false
		if err := e.scroll_finish_pan(
			m,
			s,
			e.scroll_velocity_get(&mouse.scroll_velocity),
		); err != "" {
			fmt.eprintln("shoji: scroll release:", err)
		}
	}
}

scroll_native_tick :: proc(state: ^State, now: time.Time) {
	active := false
	for s in state.manager.spaces {
		if s.view.scroll.motion.active || s.view.scroll.geometry_active {
			active = true; break
		}
	}
	if !active {
		return
	}
	started: time.Tick
	if state.manager.motion_trace.active {
		started = time.tick_now()
	}
	defer e.motion_trace_record(
		&state.manager.motion_trace,
		{
			kind = "sample",
			duration_ms = state.manager.motion_trace.active \
				? f64(time.tick_since(started)) / 1e6 \
				: 0,
		},
	)
	if err := frame_updates_begin(state); err != "" {
		fmt.eprintln("shoji: scroll:", err); return
	}
	defer {
		if err := frame_updates_end(state); err != "" {
			fmt.eprintln("shoji: scroll:", err)
		}
	}
	if err := e.scroll_motion_tick(
		&state.manager,
		time.duration_seconds(time.diff(time.Time{}, now)),
	); err != "" {
		fmt.eprintln("shoji: scroll motion:", err)
	}
}
