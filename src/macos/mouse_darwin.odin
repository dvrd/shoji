package macos

import e "../engine"
import "base:runtime"
import "core:fmt"
import "core:math"

foreign import mouse_cg "system:CoreGraphics.framework"
foreign import mouse_cf "system:CoreFoundation.framework"
Mouse_Callback :: proc "c" (proxy: Ref, type: u32, event: Ref, user: rawptr) -> Ref
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
Mouse_State :: struct {
	tap, source, down: Ref,
	drag: e.Mouse_Drag,
	point: e.Mouse_Point,
	target, hover, last_hover, last_focused, hover_focused: u32,
	buttons: u8,
	button: u32,
	moved, finished, pending, failed, hover_pending: bool,
	hover_point: e.Mouse_Point,
}
mouse_start :: proc(state: ^State) {
	mask: u64 = (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5) | (1 << 6) | (1 << 7)
	mouse := &state.mouse
	mouse.tap = CGEventTapCreate(1, 0, 0, mask, mouse_callback, state)
	if mouse.tap ==
	   nil { fmt.eprintln("shoji: mouse event tap unavailable; mouse controls are disabled"); return }
	mouse.source = CFMachPortCreateRunLoopSource(nil, mouse.tap, 0)
	if mouse.source ==
	   nil { CFMachPortInvalidate(mouse.tap); CFRelease(mouse.tap); mouse.tap = nil; return }
	CFRunLoopAddSource(CFRunLoopGetMain(), mouse.source, kCFRunLoopDefaultMode)
	CGEventTapEnable(mouse.tap, true)
}
mouse_stop :: proc(state: ^State) {
	mouse := &state.mouse
	if mouse.down != nil { CFRelease(mouse.down) }
	if mouse.tap != nil { CGEventTapEnable(mouse.tap, false); CFMachPortInvalidate(mouse.tap) }
	if mouse.source !=
	   nil { CFRunLoopRemoveSource(CFRunLoopGetMain(), mouse.source, kCFRunLoopDefaultMode); CFRelease(mouse.source) }
	if mouse.tap != nil { CFRelease(mouse.tap) }
	mouse^ = {}
}
mouse_callback :: proc "c" (proxy: Ref, type: u32, event: Ref, user: rawptr) -> Ref {
	context = runtime.default_context()
	state := (^State)(user); mouse := &state.mouse
	if type == 0xfffffffe || type == 0xffffffff {
		if mouse.down !=
		   nil { CGEventTapPostEvent(proxy, mouse.down); CFRelease(mouse.down); mouse.down = nil }
		mouse.finished = true; mouse.failed = true; mouse.buttons = 0
		CGEventTapEnable(mouse.tap, true); return event
	}
	location := CGEventGetLocation(event); point := e.Mouse_Point{location.x, location.y}
	target := u32(CGEventGetIntegerValueField(event, 91))
	switch type {
	case 1, 3:
		mouse.buttons |= type == 1 ? u8(1) : u8(2)
		if mouse.drag.window != 0 { return event }
		if CGEventGetFlags(event) & e.MOUSE_MODIFIERS !=
		   state.manager.mouse.modifier { return event }
		action := type == 1 ? state.manager.mouse.action1 : state.manager.mouse.action2
		drag := e.mouse_begin(&state.manager, target, action, point)
		if drag.window == 0 { return event }
		mouse.hover_pending = false
		mouse.drag = drag; mouse.point = point; mouse.target = target; mouse.button = type
		mouse.moved = false; mouse.finished = false; mouse.failed = false; mouse.pending = false
		mouse.down = CFRetain(event)
		return nil
	case 2, 4:
		mouse.buttons &= ~(type == 2 ? u8(1) : u8(2))
		if mouse.down == nil || type != mouse.button + 1 { return event }
		mouse.point = point; mouse.target = target; mouse.finished = true; mouse.pending = true
		if !mouse.moved { CGEventTapPostEvent(proxy, mouse.down); CGEventTapPostEvent(proxy, event) }
		CFRelease(mouse.down); mouse.down = nil
		return nil
	case 6, 7:
		if mouse.down == nil || (type == 6 ? u32(1) : u32(3)) != mouse.button { return event }
		mouse.point = point; mouse.target = target
		if math.abs(point.x - mouse.drag.origin.x) + math.abs(point.y - mouse.drag.origin.y) >=
		   3 { mouse.moved = true }
		mouse.pending = mouse.moved
		return nil
	case 5:
		if mouse.buttons != 0 || mouse.drag.window != 0 { return event }
		if CGEventGetFlags(event) & e.MOUSE_MODIFIERS ==
		   state.manager.mouse.modifier { return event }
		mouse.hover = target; mouse.hover_point = point; mouse.hover_pending = true
	}
	return event
}
mouse_tick :: proc(state: ^State) {
	mouse := &state.mouse; m := &state.manager
	if mouse.drag.window != 0 {
		if mouse.pending && mouse.moved && !mouse.failed {
			err := e.mouse_update(m, &mouse.drag, mouse.point)
			if err == "" &&
			   mouse.finished { err = e.mouse_drop(m, mouse.drag, mouse.target, mouse.point) }
			if err != "" { fmt.eprintln("shoji: mouse:", err); mouse.failed = true }
			mouse.pending = false
		}
		if mouse.finished { mouse.drag = {}; mouse.finished = false; mouse.pending = false }
		return
	}
	if !mouse.hover_pending { return }
	mouse.hover_pending = false
	if m.mouse.focus == .Off { mouse.last_hover = 0; return }
	if mouse.hover == mouse.last_hover { return }
	mouse.last_hover = mouse.hover
	w := m.windows[mouse.hover]
	if w == nil || w.id == m.focused || w.hidden || w.minimized || w.fullscreen { return }
	s := e.space_by_id(m, w.space)
	if s == nil || !s.visible { return }
	kind := m.mouse.focus == .Autofocus ? e.Action_Kind.Focus_Without_Raise : e.Action_Kind.Focus
	if err := perform(state, {kind = kind, window = w.id});
	   err != "" { fmt.eprintln("shoji: focus follows mouse:", err); return }
	mouse.hover_focused = w.id
}
mouse_follow_focus :: proc(state: ^State) {
	mouse := &state.mouse; m := &state.manager
	if m.focused == mouse.last_focused { return }
	mouse.last_focused = m.focused
	if mouse.hover_focused == m.focused { mouse.hover_focused = 0; return }
	mouse.hover_focused = 0
	if !m.mouse.follows_focus || mouse.buttons != 0 || mouse.drag.window != 0 { return }
	w := m.windows[m.focused]
	if w == nil || w.hidden || w.minimized { return }
	current := CGEventCreate(nil)
	if current == nil { return }; defer CFRelease(current)
	point := CGEventGetLocation(current)
	if point.x >= w.frame.x &&
	   point.x < w.frame.x + w.frame.w &&
	   point.y >= w.frame.y &&
	   point.y < w.frame.y + w.frame.h { return }
	CGWarpMouseCursorPosition({w.frame.x + w.frame.w / 2, w.frame.y + w.frame.h / 2})
}
