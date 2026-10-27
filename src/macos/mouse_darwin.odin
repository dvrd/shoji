package macos

import e "../engine"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:time"

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
	if owner == state.connection {
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
	}
	return window
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
	if type == 1 || type == 3 || type == 25 {state.resize_cover_cancel = true}
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
		mouse.buttons = 0
		CGEventTapEnable(mouse.tap, true); return event
	}
	if (state.manager.suspended || state.manager.gesture_active) &&
	   mouse.drag.window == 0 && !(type == 22 && mouse.scroll.owned && !state.manager.suspended) {
		return event
	}
	location := CGEventGetLocation(event)
	point := e.Mouse_Point{location.x, location.y}
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
		mouse.buttons |= type == 1 ? u8(1) : u8(2)
		if mouse.drag.window != 0 {
			return event
		}
		job, animating := state.animations[target]
		w := state.manager.windows[target]
		if animating && animation_is_live(job) && w != nil {
			w.frame = job.presentation.(Live_Resize).current
		}
		modifiers := CGEventGetFlags(event) & e.MOUSE_MODIFIERS
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
		if animating && animation_is_live(job) && w != nil {
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
mouse_tick :: proc(state: ^State, present_scroll: bool = true, scroll_now: time.Time = {}) {
	mouse := &state.mouse; m := &state.manager
	mouse_gesture_tick(state, time.now())
	if !m.mouse.scroll {
		mouse.scroll_delta = 0; mouse.scroll.owned = false
		mouse.space_direction = 0
		if s := e.space_by_id(m, mouse.scroll.space); s != nil {s.view.scroll.dragging = false}
		mouse.scroll_tracking, mouse.scroll_begin, mouse.scroll_end = false, false, false
	}
	if mouse.space_direction != 0 {
		direction := mouse.space_direction
		mouse.space_direction = 0
		if err := e.space_gesture_switch(m, mouse.space_origin, direction); err != "" {fmt.eprintln("shoji: Space gesture:", err)}
	}
	if present_scroll {
		scroll_now := scroll_now
		if scroll_now == (time.Time{}) {scroll_now = time.now()}
		scroll_input_tick(state, scroll_now)
	}
	if m.suspended || m.gesture_active {
		mouse.failed = true; return
	}
	if !present_scroll && mouse.drag.window != 0 && !mouse_drag_finished(mouse) {return}
	if mouse.drag.window != 0 {
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
					resize_cover_frame(state, mouse.drag.window, observed, mouse.drag.frame, CACurrentMediaTime())
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
	if s.view.layout == .Scroll && (s.view.scroll.motion.active || s.view.scroll.dragging) {return}
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
