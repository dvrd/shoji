package shoji

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:sync"
import "core:time"
import layout "layout"

// Pointer interaction
// ------------------------------------------------------------------------

foreign import mouse_cg "system:CoreGraphics.framework"
foreign import mouse_cf "system:CoreFoundation.framework"
foreign import mouse_sls "system:SkyLight.framework"
foreign mouse_sls {
	SLSFindWindowAndOwner :: proc "c" (connection: i32, relative: u32, mode, options: i32, point, local: ^Point, window: ^u32, owner: ^i32) -> i32 ---
}
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
	edge:                                                         Drag_Edge,
	scroll:                                                       Scroll_Gesture,
	scroll_delta:                                                 f64,
	scroll_velocity:                                              Scroll_Velocity,
	scroll_tracking, scroll_begin, scroll_end, scroll_phase_less: bool,
	scroll_last:                                                  f64,
	space_origin:                                                 u64,
	space_direction:                                              int,
	mode:                                                         Drag_Mode,
	phase:                                                        Drag_Phase,
	resize_frame:                                                 proc(
		state: ^State,
		window: u32,
	) -> (
		Rect,
		bool,
	),
	hit_test:                                                     proc(
		state: ^State,
		point: Mouse_Point,
	) -> u32,
	gesture:                                                      bool,
	gesture_ended:                                                time.Time,
	tap, source, down:                                            Ref,
	drag:                                                         Mouse_Drag,
	point:                                                        Mouse_Point,
	target, hover, last_hover, last_focused, hover_focused:       u32,
	buttons:                                                      u8,
	button:                                                       u32,
	pending, failed, hover_pending:                               bool,
	hover_point:                                                  Mouse_Point,
	tab_pressed, tab_pending:                                     u32,
	tab_generation, tab_pending_generation:                       u64,
	edge_double_button, edge_double_pending:                      u32,
	edge_double_generation:                                       u64,
	edge_double_horizontal:                                       bool,
	view:                                                         View_Drag,
	view_point:                                                   Mouse_Point,
	view_sample, view_release, suppress_right, float_toggle:      bool,
	hold_window:                                                  u32,
	hold_since:                                                   f64,
	hold_fired:                                                   bool,
	// Left button sampled for the overview. mouse_tick turns it into
	// overview_pointer; it is not a managed window drag.
	overview_down, overview_up:                                   bool,
}

tab_indicator_hit :: proc(state: ^State, point: Mouse_Point) -> Tab_Indicator {
	indicator := &state.tab_indicator
	for i in 0 ..< indicator.count {
		tab := indicator.tabs[i]; r := tab.frame
		if indicator.bars[i].surface.id != 0 &&
		   point.x >= r.x &&
		   point.x < r.x + r.w &&
		   point.y >= r.y &&
		   point.y < r.y + r.h {
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
	mouse.hold_window = 0; mouse.hold_fired = false; mouse.hold_since = 0
	mouse.overview_down = false; mouse.overview_up = false
}

mouse_wake :: proc(state: ^State, now: time.Time = {}) {
	stack_touch_wake(state, now)
	mouse := &state.mouse
	// Release events can be lost while asleep. Do not replay a pre-sleep drag,
	// scroll, Space switch or click when the desktop becomes available again.
	if s := space_by_id(&state.manager, mouse.scroll.space); s != nil {
		s.view.scroll.dragging = false
	}
	view_drag_cancel(state)
	mouse_drag_reset(state)
	tap, source := mouse.tap, mouse.source
	resize_frame, hit_test := mouse.resize_frame, mouse.hit_test
	mouse^ = {
		tap          = tap,
		source       = source,
		resize_frame = resize_frame,
		hit_test     = hit_test,
	}
	state.manager.gesture_active = false
	state.resize_cover_cancel = true
}

mouse_native_resize_frame :: proc(state: ^State, window: u32) -> (frame: Rect, known: bool) {
	if state.mouse.resize_frame != nil {
		return state.mouse.resize_frame(state, window)
	}
	known = SLSGetWindowBounds(state.connection, window, &frame) == 0
	return
}
mouse_window_at_point :: proc(state: ^State, point: Mouse_Point) -> u32 {
	if state.mouse.hit_test != nil {
		return state.mouse.hit_test(state, point)
	}
	if state.connection == 0 {
		return 0
	}
	location := Point{point.x, point.y}
	local: Point; window: u32; owner: i32
	if SLSFindWindowAndOwner(state.connection, 0, 1, 0, &location, &local, &window, &owner) != 0 {
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
		(1 << 25) |
		(1 << 26) |
		(1 << 27) |
		(1 << 30)
	mouse := &state.mouse
	mouse.tap = CGEventTapCreate(1, 0, 0, mask, mouse_callback, state)
	if mouse.tap == nil {
		fmt.eprintln("shoji: mouse event tap unavailable; mouse controls are disabled"); return
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
		CFRunLoopRemoveSource(CFRunLoopGetMain(), mouse.source, kCFRunLoopDefaultMode)
		CFRelease(mouse.source)
	}
	if mouse.tap != nil {
		CFRelease(mouse.tap)
	}
	mouse^ = {}
}
mouse_callback :: proc "c" (proxy: Ref, type: u32, event: Ref, user: rawptr) -> Ref {
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
		view_drag_cancel(state)
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
		if type == mouse.edge_double_button + 1 {
			mouse.edge_double_button = 0
		}
		return nil
	}
	if (state.manager.suspended || state.manager.gesture_active) &&
	   mouse.drag.window == 0 &&
	   !(type == 22 && mouse.scroll.owned && !state.manager.suspended) &&
	   !(mouse.view.active && (type == 26 || type == 27)) {
		return event
	}
	location := CGEventGetLocation(event)
	point := Mouse_Point{location.x, location.y}
	// The overview consumes the left button. mouse_tick applies the sample,
	// including a release, and this path must not start a window drag.
	if state.manager.overview.active && (type == 1 || type == 2 || type == 6) {
		mouse.point = point
		if type == 1 {
			mouse.buttons |= 1
			mouse.overview_down = true
		} else if type == 2 {
			mouse.buttons &~= 1
			mouse.overview_down = false
			mouse.overview_up = true
		}
		return nil
	}
	if type == 1 &&
	   mouse.drag.window == 0 &&
	   mouse.buttons == 0 &&
	   CGEventGetFlags(event) & MOUSE_MODIFIERS == 0 {
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
		opening_note_focus(&state.manager, target, true)
		modifiers := CGEventGetFlags(event) & MOUSE_MODIFIERS
		if CGEventGetIntegerValueField(event, 1) == 2 &&
		   mouse.drag.window == 0 &&
		   mouse.buttons == 0 &&
		   ((type == 1 && modifiers == 0) ||
				   (type == 3 &&
						   modifiers == state.manager.mouse.modifier &&
						   state.manager.mouse.action2 == .Resize)) {
			w := state.manager.windows[target]
			if w != nil {
				s := space_by_id(&state.manager, w.space)
				edge := mouse_border_resize(&state.manager, target, point)
				if s != nil &&
				   s.view.layout == .Scroll &&
				   edge.window != 0 &&
				   edge.lock_x != edge.lock_y {
					mouse.edge_double_button, mouse.edge_double_pending = type, target
					mouse.edge_double_generation = w.generation
					mouse.edge_double_horizontal = !edge.lock_x
					return nil
				}
			}
		}
		// Right click during a move toggles float and tiling. The click is not
		// delivered, matching Niri's interactive-move transition.
		if type == 3 &&
		   mouse.drag.window != 0 &&
		   mouse.drag.action == .Move &&
		   !mouse_drag_finished(mouse) {
			mouse.float_toggle = true
			mouse.suppress_right = true
			return nil
		}
		mouse.buttons |= type == 1 ? u8(1) : u8(2)
		if mouse.drag.window != 0 {
			return event
		}
		job, animating := state.animations[target]
		w := state.manager.windows[target]
		if animating && animation_is_live(job) && animation_matches(state, target, job) {
			w.frame = job.presentation.(Live_Resize).current
		}
		drag: Mouse_Drag
		native_resize := false
		if type == 1 && modifiers == 0 {
			drag = mouse_border_resize(&state.manager, target, point)
			native_resize = drag.window != 0
		}
		if drag.window == 0 && modifiers == state.manager.mouse.modifier {
			action := type == 1 ? state.manager.mouse.action1 : state.manager.mouse.action2
			drag = mouse_begin(&state.manager, target, action, point)
		}
		if animating && animation_is_live(job) && animation_matches(state, target, job) {
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
		if type == 4 && mouse.suppress_right {
			mouse.suppress_right = false
			return nil
		}
		mouse.buttons &= ~(type == 2 ? u8(1) : u8(2))
		if mouse.down == nil || type != mouse.button + 1 {
			return event
		}
		mouse.point = point; mouse.target = target
		mouse.phase = mouse_drag_moved(mouse) ? .Released_Drag : .Released_Click
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
		if math.abs(point.x - mouse.drag.origin.x) + math.abs(point.y - mouse.drag.origin.y) >= 3 {
			mouse.phase = .Dragging
		}
		mouse.pending = mouse_drag_moved(mouse)
		return mouse.mode == .Native_Resize ? event : nil
	case 25:
		// Button 2 is the middle button. Other extra buttons keep their
		// application behavior. The gesture is the same switch as two-finger pan.
		if CGEventGetIntegerValueField(event, 3) != 2 ||
		   mouse.view.active ||
		   mouse.drag.window != 0 ||
		   !state.manager.mouse.scroll ||
		   state.manager.suspended ||
		   state.manager.gesture_active ||
		   CGEventGetFlags(event) & MOUSE_MODIFIERS != state.manager.mouse.modifier {
			return event
		}
		space: u64
		if d := display_by_id(&state.manager, state.manager.mouse_display); d != nil {
			if s := space_by_id(&state.manager, d.active_space); s != nil && s.visible {
				space = s.id
			}
		}
		if space == 0 {
			return event
		}
		view_drag_begin(&mouse.view, space, point)
		mouse.view_point = point
		mouse.view_sample, mouse.view_release = false, false
		return nil
	case 26, 27:
		if !mouse.view.active {
			return event
		}
		mouse.view_point = point
		mouse.view_sample = true
		if type == 26 {
			mouse.view_release = true
		}
		return nil
	case 5:
		if mouse.buttons != 0 || mouse.drag.window != 0 {
			return event
		}
		if CGEventGetFlags(event) & MOUSE_MODIFIERS == state.manager.mouse.modifier {
			return event
		}
		mouse.hover = target; mouse.hover_point = point
		mouse.hover_pending = true
	}
	return event
}
view_drag_cancel :: proc(state: ^State) {
	mouse := &state.mouse
	if mouse.view.panning {
		if s := space_by_id(&state.manager, mouse.view.space); s != nil {
			s.view.scroll.dragging = false
		}
	}
	mouse.view = {}
	mouse.view_sample, mouse.view_release = false, false
}

view_drag_tick :: proc(state: ^State) {
	mouse := &state.mouse
	m := &state.manager
	if !mouse.view.active || (!mouse.view_sample && !mouse.view_release) {
		return
	}
	dx := view_drag_sample(&mouse.view, mouse.view_point)
	mouse.view_sample = false
	s := space_by_id(m, mouse.view.space)
	if s != nil && s.visible && s.view.layout == .Scroll && dx != 0 {
		if !mouse.view.panning {
			scroll_begin_pan(m, s)
			mouse.view.panning = true
		}
		if err := scroll_gesture_pan(m, s.id, -dx); err != "" {
			fmt.eprintln("shoji: view drag:", err)
		}
	}
	if !mouse.view_release {
		return
	}
	direction := view_drag_direction(mouse.view)
	space := mouse.view.space
	panning := mouse.view.panning
	mouse.view_release = false
	mouse.view = {}
	if panning && s != nil {
		if err := scroll_finish_pan(m, s, 0); err != "" {
			fmt.eprintln("shoji: view drag release:", err)
		}
	}
	if direction != 0 {
		if err := space_gesture_switch(m, space, direction, true); err != "" {
			fmt.eprintln("shoji: view drag:", err)
		}
	}
}

mouse_tick :: proc(state: ^State, present_scroll: bool = true, scroll_now: time.Time = {}) {
	mouse := &state.mouse; m := &state.manager
	if present_scroll {
		stack_touch_tick(state)
	}
	if mouse.edge_double_pending != 0 {
		id, generation, horizontal :=
			mouse.edge_double_pending, mouse.edge_double_generation, mouse.edge_double_horizontal
		mouse.edge_double_pending = 0
		if w := m.windows[id];
		   w != nil && w.generation == generation && !m.suspended && !m.gesture_active {
			s := space_by_id(m, w.space)
			if s != nil &&
			   s.visible &&
			   s.view.layout == .Scroll &&
			   layout.find(s.view.root, id) != nil {
				operation := horizontal ? "--toggle" : "--row-height"
				operand := horizontal ? "column-full-width" : "auto"
				if response := execute(m, {"window", fmt.tprintf("%d", id), operation, operand});
				   response.failed {
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
			if tab.window == id &&
			   tab.generation == generation &&
			   state.tab_indicator.bars[i].surface.id != 0 {
				current = true; break
			}
		}
		focused := m.windows[m.focused]
		if focused == nil {
			current = false
		} else if s := space_by_id(m, focused.space);
		   s == nil || !s.visible || s.view.layout != .Scroll {
			current = false
		} else {
			n := layout.find(s.view.root, id)
			current = current && n != nil && n.column_tabbed && n.count >= 2
		}
		if w := m.windows[id];
		   current && w != nil && w.generation == generation && !m.suspended && !m.gesture_active {
			if response := execute(m, {"window", fmt.tprintf("%d", id), "--focus"});
			   response.failed {
				fmt.eprintln("shoji: tab focus:", response.text)
			}
		}
	}
	mouse_gesture_tick(state, time.now())
	if !m.mouse.scroll {
		mouse.scroll_delta = 0; mouse.scroll.owned = false
		mouse.space_direction = 0
		if s := space_by_id(m, mouse.scroll.space); s != nil {
			s.view.scroll.dragging = false
		}
		mouse.scroll_tracking, mouse.scroll_begin, mouse.scroll_end = false, false, false
	}
	if mouse.space_direction != 0 {
		direction := mouse.space_direction
		mouse.space_direction = 0
		if err := space_gesture_switch(m, mouse.space_origin, direction); err != "" {
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
		view_drag_cancel(state)
		mouse.edge = {}; mouse.hold_window = 0; mouse.hold_fired = false
		mouse.overview_down = false; mouse.overview_up = false
		mouse.failed = true; return
	}
	if m.overview.active {
		now := scroll_now
		if now == (time.Time{}) {
			now = time.now()
		}
		seconds := time.duration_seconds(time.diff(time.Time{}, now))
		if err := overview_edge(m, mouse.point, seconds); err != "" {
			fmt.eprintln("shoji: overview edge:", err)
		}
		if mouse.overview_down || mouse.overview_up {
			if err := overview_pointer(m, mouse.point, mouse.overview_down, seconds); err != "" {
				fmt.eprintln("shoji: overview pointer:", err)
			}
			mouse.overview_up = false
		}
	} else if mouse.overview_down || mouse.overview_up {
		mouse.buttons &~= 1
		mouse.overview_down = false
		mouse.overview_up = false
	}
	if mouse.view.active {
		view_drag_tick(state)
	}
	if !present_scroll && mouse.drag.window != 0 && !mouse_drag_finished(mouse) {
		return
	}
	if mouse.drag.window != 0 {
		if mouse.float_toggle {
			mouse.float_toggle = false
			if w := m.windows[mouse.drag.window]; w != nil && mouse.drag.action == .Move {
				if err := window_toggle_float(m, w); err != "" {
					fmt.eprintln("shoji: float transition:", err)
					mouse.failed = true
				} else if mouse_drag_moved(mouse) {
					mouse.pending = true
				}
			}
		}
		if mouse.drag.action == .Move && mouse_drag_moved(mouse) && !mouse.failed {
			mouse.target = drag_target_at(m, mouse.drag, mouse.point)
		}
		if mouse_drag_moved(mouse) && !mouse_drag_finished(mouse) && !mouse.failed {
			now := scroll_now
			if now == (time.Time{}) {
				now = time.now()
			}
			moved, err := drag_edge_scroll(
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
				mouse.target = drag_target_at(m, mouse.drag, mouse.point)
			}
			drag_hold_activate(
				m,
				mouse,
				mouse.target,
				time.duration_seconds(time.diff(time.Time{}, now)),
			)
		} else {
			mouse.edge = {}
			mouse.hold_window = 0
			mouse.hold_fired = false
		}
		if mouse.mode == .Native_Resize && mouse_drag_moved(mouse) && !mouse.failed {
			mouse.pending = true
		}
		if mouse.pending && mouse_drag_moved(mouse) && !mouse.failed {
			point := mouse.point
			err: string
			if mouse.mode == .Native_Resize {
				if observed, known := mouse_native_resize_frame(state, mouse.drag.window); known {
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
						d.origin.x + (d.left ? observed.x - d.frame.x : observed.w - d.frame.w),
						d.origin.y + (d.top ? observed.y - d.frame.y : observed.h - d.frame.h),
					}
				} else {
					err = "could not observe native resize frame"
				}
			}
			if err == "" {
				err = frame_updates_begin(state)
			}
			if err == "" {
				err = mouse_update(m, &mouse.drag, point)
				present := frame_updates_end(state)
				if err == "" {
					err = present
				}
			}
			if err == "" && mouse_drag_finished(mouse) {
				m.native_resize_window = 0
				err = mouse_drop(m, mouse.drag, mouse.target, mouse.point)
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
	if w == nil || w.id == m.focused || w.hidden || w.minimized || w.fullscreen {
		return
	}
	s := space_by_id(m, w.space)
	if s == nil || !s.visible {
		return
	}
	if s.view.layout == .Scroll && (s.view.scroll.motion.active || s.view.scroll.dragging) {
		return
	}
	kind := m.mouse.focus == .Autofocus ? Action_Kind.Focus_Without_Raise : Action_Kind.Focus
	if err := perform_native(state, {kind = kind, window = w.id}); err != "" {
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
	if !pointer_follows_focus(m, w) || mouse.buttons != 0 || mouse.drag.window != 0 {
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
	CGWarpMouseCursorPosition({w.frame.x + w.frame.w / 2, w.frame.y + w.frame.h / 2})
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

mouse_gesture_record :: proc(state: ^State, kind, motion, phase: i64, now: time.Time) {
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

// Pointer interaction
// ------------------------------------------------------------------------

Mouse_Action :: enum {
	None,
	Move,
	Resize,
}
Focus_Follows_Mouse :: enum {
	Off,
	Autofocus,
	Autoraise,
}
Mouse_Config :: struct {
	scroll:                    bool,
	stack_swipe:               bool,
	three_finger_horizontal:   bool,
	edge:                      Drag_Edge_Config,
	modifier:                  u64,
	action1, action2:          Mouse_Action,
	focus:                     Focus_Follows_Mouse,
	follows_focus, drop_stack: bool,
}
MOUSE_MODIFIERS :: u64((1 << 17) | (1 << 18) | (1 << 19) | (1 << 20) | (1 << 23))
mouse_defaults :: proc() -> Mouse_Config {
	return {
		modifier = 1 << 23,
		action1 = .Move,
		action2 = .Resize,
		edge = {enabled = true, width = 30, delay = .1, speed = 1500},
	}
}
mouse_config :: proc(m: ^Manager, s: ^Space, name, value: string, setting: bool) -> Response {
	if s != nil {
		return failure("mouse settings are global")
	}
	c := &m.mouse
	switch name {
	case "three_finger_horizontal":
		if !setting {
			return success(c.three_finger_horizontal ? "on" : "off")
		}
		if value != "on" && value != "off" {
			return failure("three_finger_horizontal expects on or off")
		}
		c.three_finger_horizontal = value == "on"
		return success()
	case "stack_swipe":
		if !setting {
			return success(c.stack_swipe ? "on" : "off")
		}
		if value != "on" && value != "off" {
			return failure("stack_swipe expects on or off")
		}
		c.stack_swipe = value == "on"
		return success()
	case "scroll_drag_edge_scroll":
		if !setting {
			return success(c.edge.enabled ? "on" : "off")
		}
		if value != "on" && value != "off" {
			return failure("scroll_drag_edge_scroll expects on or off")
		}
		c.edge.enabled = value == "on"
		return success()
	case "scroll_drag_edge_width", "scroll_drag_edge_delay", "scroll_drag_edge_speed":
		target :=
			name == "scroll_drag_edge_width" \
				? &c.edge.width \
				: (name == "scroll_drag_edge_delay" ? &c.edge.delay : &c.edge.speed)
		if !setting {
			return success(fmt.tprintf("%g", target^))
		}
		values: [1]f64
		maximum :=
			name == "scroll_drag_edge_width" \
				? f64(500) \
				: (name == "scroll_drag_edge_delay" ? f64(5) : f64(10000))
		if !parse_numbers(value, values[:]) ||
		   values[0] < 0 ||
		   (name != "scroll_drag_edge_delay" && values[0] == 0) ||
		   values[0] > maximum {
			return failure(
				"invalid edge-scroll setting (width in pixels, delay in seconds, speed in pixels/second)",
			)
		}
		target^ = values[0]
		return success()
	case "scroll_gestures":
		if !setting {
			return success(c.scroll ? "on" : "off")
		}
		if value != "on" && value != "off" {
			return failure("scroll_gestures expects on or off")
		}
		c.scroll = value == "on"
		return success()
	case "mouse_modifier":
		names := []string{"alt", "shift", "cmd", "ctrl", "fn"}
		bits := []u64{1 << 19, 1 << 17, 1 << 20, 1 << 18, 1 << 23}
		for name, i in names {
			if !setting && c.modifier == bits[i] {
				return success(name)
			}
			if setting && value == name {
				c.modifier = bits[i]; return success()
			}
		}
		return failure("mouse_modifier expects alt, shift, cmd, ctrl, or fn")
	case "mouse_action1", "mouse_action2":
		action := name == "mouse_action1" ? &c.action1 : &c.action2
		names := [Mouse_Action]string {
			.None   = "none",
			.Move   = "move",
			.Resize = "resize",
		}
		if !setting {
			return success(names[action^])
		}
		for name, kind in names {
			if name == value {
				action^ = kind; return success()
			}
		}
		return failure("mouse action expects none, move, or resize")
	case "focus_follows_mouse":
		names := [Focus_Follows_Mouse]string {
			.Off       = "off",
			.Autofocus = "autofocus",
			.Autoraise = "autoraise",
		}
		if !setting {
			return success(names[c.focus])
		}
		for name, kind in names {
			if name == value {
				c.focus = kind; return success()
			}
		}
		return failure("focus_follows_mouse expects off, autofocus, or autoraise")
	case "mouse_follows_focus":
		if !setting {
			return success(c.follows_focus ? "on" : "off")
		}
		if value != "on" && value != "off" {
			return failure("mouse_follows_focus expects on or off")
		}
		c.follows_focus = value == "on"
	case "mouse_drop_action":
		if !setting {
			return success(c.drop_stack ? "stack" : "swap")
		}
		if value != "stack" && value != "swap" {
			return failure("mouse_drop_action expects swap or stack")
		}
		c.drop_stack = value == "stack"
	case:
		return failure("unknown mouse setting")
	}
	return success()
}
Mouse_Point :: struct {
	x, y: f64,
}
Mouse_Drag :: struct {
	window:           u32,
	action:           Mouse_Action,
	origin, previous: Mouse_Point,
	frame:            Rect,
	left, top:        bool,
	lock_x, lock_y:   bool,
}
// Capture native border drags before the app can resize independently of its
// tile. Interior clicks and floating windows keep their native behavior.
mouse_border_resize :: proc(m: ^Manager, id: u32, point: Mouse_Point) -> Mouse_Drag {
	w := m.windows[id]
	if w == nil || !managed(w) || !(w.can_resize.? or_else true) {
		return {}
	}
	s := space_by_id(m, w.space)
	if s == nil ||
	   !s.visible ||
	   s.view.layout == .Float ||
	   layout.find(s.view.root, id) == nil ||
	   w.windowed_frame != nil {
		return {}
	}
	r := w.frame
	margin :: 5.0
	if r.w <= 0 ||
	   r.h <= 0 ||
	   point.x < r.x - margin ||
	   point.x > r.x + r.w + margin ||
	   point.y < r.y - margin ||
	   point.y > r.y + r.h + margin {
		return {}
	}
	x_edge := math.abs(point.x - r.x) <= margin || math.abs(point.x - r.x - r.w) <= margin
	y_edge := math.abs(point.y - r.y) <= margin || math.abs(point.y - r.y - r.h) <= margin
	if !x_edge && !y_edge {
		return {}
	}
	drag := mouse_begin(m, id, .Resize, point)
	drag.lock_x, drag.lock_y = !x_edge, !y_edge
	return drag
}
mouse_begin :: proc(m: ^Manager, id: u32, action: Mouse_Action, point: Mouse_Point) -> Mouse_Drag {
	w := m.windows[id]
	if w == nil ||
	   w.fullscreen ||
	   w.minimized ||
	   w.hidden ||
	   !(w.ordered_in.? or_else true) ||
	   action == .None {
		return {}
	}
	return {
		window = id,
		action = action,
		origin = point,
		previous = point,
		frame = w.frame,
		left = point.x < w.frame.x + w.frame.w / 2,
		top = point.y < w.frame.y + w.frame.h / 2,
	}
}
mouse_drag_frame :: proc(d: Mouse_Drag, point: Mouse_Point) -> Rect {
	r := d.frame; dx := point.x - d.origin.x; dy := point.y - d.origin.y
	if d.action == .Move {
		r.x += dx; r.y += dy; return r
	}
	if d.left {
		r.w = max(1, r.w - dx); r.x = d.frame.x + d.frame.w - r.w
	} else {
		r.w = max(1, r.w + dx)
	}
	if d.top {
		r.h = max(1, r.h - dy); r.y = d.frame.y + d.frame.h - r.h
	} else {
		r.h = max(1, r.h + dy)
	}
	return r
}
mouse_fence :: proc(n: ^layout.Node, split: layout.Split, leading: bool) -> ^layout.Node {
	for child := n; child != nil && child.parent != nil; child = child.parent {
		parent := child.parent
		if parent.split == split && (leading ? parent.right == child : parent.left == child) {
			return parent
		}
	}
	return nil
}
mouse_update :: proc(m: ^Manager, d: ^Mouse_Drag, point: Mouse_Point) -> string {
	point := point
	if d.lock_x {
		point.x = d.origin.x
	}
	if d.lock_y {
		point.y = d.origin.y
	}
	// Pointer motion already supplies the timing. Animating each frame would
	// make the layout trail the pointer and repeatedly create proxy windows.
	duration := m.animation_duration
	m.animation_duration = 0
	defer m.animation_duration = duration
	w := m.windows[d.window]
	if w == nil {
		return "dragged window no longer exists"
	}
	if w.fullscreen || w.minimized || w.hidden || !(w.ordered_in.? or_else true) {
		return "dragged window is no longer available"
	}
	s := space_by_id(m, w.space)
	n: ^layout.Node
	if s != nil && s.view.layout != .Float {
		n = layout.find(s.view.root, w.id)
	}
	if n == nil {
		r := mouse_drag_frame(d^, point)
		if err := perform(m, {kind = .Frame, window = w.id, frame = r}); err != "" {
			return err
		}
		w.frame = r
	} else if d.action == .Resize {
		if s.view.layout == .Scroll {
			delta := (point.x - d.previous.x) * (d.left ? f64(-1) : f64(1))
			if delta != 0 {
				if err := layout.scroll_set_width(&s.view, w.id, fmt.tprintf("rel:%g", delta));
				   err != "" {
					return err
				}
				if err := flush(m, s, true); err != "" {
					return err
				}
			}
			d.previous = point
			return ""
		}
		if n == s.view.root && n.count == 1 && n.zoom == nil {
			area := n.frame
			if area.w <= 0 || area.h <= 0 {
				return "single tile requires positive usable dimensions"
			}
			r := mouse_drag_frame(d^, point)
			minimum_w, minimum_h := min(120, area.w), min(80, area.h)
			if d.left {
				right := clamp(d.frame.x + d.frame.w, area.x + minimum_w, area.x + area.w)
				r.x = clamp(r.x, area.x, right - minimum_w); r.w = right - r.x
			} else {
				r.x = clamp(r.x, area.x, area.x + area.w - minimum_w)
				r.w = clamp(r.w, minimum_w, area.x + area.w - r.x)
			}
			if d.top {
				bottom := clamp(d.frame.y + d.frame.h, area.y + minimum_h, area.y + area.h)
				r.y = clamp(r.y, area.y, bottom - minimum_h)
				r.h = bottom - r.y
			} else {
				r.y = clamp(r.y, area.y, area.y + area.h - minimum_h)
				r.h = clamp(r.h, minimum_h, area.y + area.h - r.y)
			}
			if m.native_resize_window != w.id {
				if err := perform(m, {kind = .Frame, window = w.id, frame = r}); err != "" {
					return err
				}
			}
			w.frame = r
			w.solo_tile_frame = Rect {
				(r.x - area.x) / area.w,
				(r.y - area.y) / area.h,
				r.w / area.w,
				r.h / area.h,
			}
			d.previous = point
			return ""
		}
		if fence := mouse_fence(n, .Vertical, d.left); fence != nil && fence.frame.w > 0 {
			fence.ratio = clamp(fence.ratio + (point.x - d.previous.x) / fence.frame.w, 0.1, 0.9)
		}
		if fence := mouse_fence(n, .Horizontal, d.top); fence != nil && fence.frame.h > 0 {
			fence.ratio = clamp(fence.ratio + (point.y - d.previous.y) / fence.frame.h, 0.1, 0.9)
		}
		if err := flush(m, s); err != "" {
			return err
		}
	}
	d.previous = point
	return ""
}
Mouse_Drop :: enum {
	None,
	Swap,
	Stack,
	North,
	East,
	South,
	West,
}
mouse_drop_region :: proc(
	frame: Rect,
	point: Mouse_Point,
	stack: bool,
	source_count: int,
) -> Mouse_Drop {
	if frame.w <= 0 || frame.h <= 0 {
		return .None
	}
	x := (point.x - frame.x) / frame.w; y := (point.y - frame.y) / frame.h
	if math.is_nan(x) || math.is_nan(y) || x < 0 || y < 0 || x > 1 || y > 1 {
		return .None
	}
	if source_count == 1 && x >= 0.25 && x <= 0.75 && y >= 0.25 && y <= 0.75 {
		return stack ? .Stack : .Swap
	}
	if y <= x && y <= 1 - x {
		return .North
	}
	if x >= y && x >= 1 - y {
		return .East
	}
	if y >= x && y >= 1 - x {
		return .South
	}
	return .West
}

layout_drop_region :: proc(
	v: ^layout.View,
	frame: Rect,
	point: Mouse_Point,
	stack: bool,
	source_count: int,
) -> Mouse_Drop {
	point := point
	if v.layout == .Scroll {
		r := v.scroll.viewport
		if math.is_nan(point.x) ||
		   math.is_nan(point.y) ||
		   point.x < r.x ||
		   point.x > r.x + r.w ||
		   point.y < r.y ||
		   point.y > r.y + r.h {
			return .None
		}
		point.x, point.y =
			clamp(point.x, frame.x, frame.x + frame.w), clamp(point.y, frame.y, frame.y + frame.h)
	}
	action := mouse_drop_region(frame, point, stack, source_count)
	if v.layout != .Scroll ||
	   action == .None ||
	   action == .Stack ||
	   action == .North ||
	   action == .South {
		return action
	}
	// A center drop inserts a column. It does not swap the way a BSP drop does.
	return point.x < frame.x + frame.w / 2 ? .West : .East
}
scroll_drop_row :: proc(
	m: ^Manager,
	source, destination: ^Window,
	s, t: ^Space,
	action: Mouse_Drop,
) -> string {
	b := layout.find(t.view.root, destination.id)
	if b == nil {
		return "target column is gone"
	}
	same := layout.find(s.view.root, source.id) == b
	if !same && b.count >= layout.MAX_STACK {
		return "target column is full"
	}
	index := 0
	for i in 0 ..< b.count {
		if b.windows[i] == destination.id {
			index = i; break
		}
	}
	if action == .South {
		index += 1
	}
	if same {
		source_index := 0
		for i in 0 ..< b.count {
			if b.windows[i] == source.id {
				source_index = i; break
			}
		}
		if source_index < index {
			index -= 1
		}
	}
	if s != t {
		if err := perform(m, {kind = .Space, window = source.id, space = t.id}); err != "" {
			return err
		}
		source.space, source.display = t.id, t.display
	}
	layout.remove(&s.view, source.id)
	b = layout.find(t.view.root, destination.id)
	if b == nil {
		return "target column is gone"
	}
	// A row drop shows every window in the column. A tabbed column becomes rows.
	b.column_tabbed = false
	if !layout.scroll_insert_row(b, source.id, index) {
		return "target column is full"
	}
	if s != t {
		if err := flush(m, s); err != "" {
			return err
		}
	}
	return flush(m, t)
}

mouse_drop :: proc(m: ^Manager, d: Mouse_Drag, target: u32, point: Mouse_Point) -> string {
	if d.action == .Resize {
		w := m.windows[d.window]
		if w == nil || !managed(w) {
			return ""
		}
		s := space_by_id(m, w.space)
		if s == nil || s.view.layout == .Float {
			return ""
		}
		n := layout.find(s.view.root, w.id)
		if n == nil || n != s.view.root || n.count != 1 {
			return ""
		}
		// A lone tile may track the pointer, but fills its workspace again
		// after release. Multi-window drags retain their adjusted split ratios.
		w.solo_tile_frame = nil
		if s.view.layout == .Scroll {
			s.view.scroll.reveal = true
		}
		// Pointer tracking is immediate; the post-release fill uses the
		// configured layout animation so it does not appear as a sudden jump.
		return flush(m, s, true)
	}
	if d.action != .Move {
		return ""
	}
	source := m.windows[d.window]; destination := m.windows[target]
	if source == nil || destination == nil || source == destination {
		return ""
	}
	s := space_by_id(m, source.space)
	if s == nil || s.view.layout == .Float {
		return ""
	}
	t := space_by_id(m, destination.space)
	if t == nil || t.view.layout == .Float {
		return ""
	}
	a := layout.find(s.view.root, source.id); b := layout.find(t.view.root, target)
	if a == nil || b == nil {
		return ""
	}
	action := layout_drop_region(&t.view, destination.frame, point, m.mouse.drop_stack, a.count)
	if action == .None {
		return ""
	}
	// Top and bottom of a scrolling window insert a row. Left and right still
	// insert a column. Focus is left where it was.
	if t.view.layout == .Scroll && (action == .North || action == .South) {
		if a == b && a.count < 2 {
			return ""
		}
		return scroll_drop_row(m, source, destination, s, t, action)
	}
	if a == b {
		return ""
	}
	source_width := s.view.layout == .Scroll ? a.column_width : f64(0)
	source_size, source_preset, source_full := a.column_size, a.column_preset, a.column_full
	if s != t {
		if action == .Swap {
			return(
				window_command(m, []string{fmt.tprintf("%d", source.id), "--swap", fmt.tprintf("%d", target)}).text \
			)
		}
		if (action == .Stack || t.view.layout == .Stack) && b.count == layout.MAX_STACK {
			return "target stack is full"
		}
		if err := perform(m, {kind = .Space, window = source.id, space = t.id}); err != "" {
			return err
		}
		layout.remove(&s.view, source.id)
		source.space, source.display = t.id, t.display
		if action == .Stack {
			layout.stack_push(b, source.id)
		} else {
			b.split = (action == .East || action == .West) ? .Vertical : .Horizontal
			b.insert_stack = false
			b.insert_first = action == .North || action == .West
			layout.add(&t.view, source.id, target)
			if t.view.layout == .Scroll && source_width > 0 {
				if placed := layout.find(t.view.root, source.id); placed != nil {
					placed.column_width = source_width
					placed.column_resolved = source_width
					placed.column_size, placed.column_preset, placed.column_full =
						source_size, source_preset, source_full
				}
			}
		}
		if err := flush(m, s); err != "" {
			return err
		}
		return flush(m, t)
	}
	switch action {
	case .None:
		return ""
	case .Swap:
		layout.swap(a, b)
	case .Stack:
		if b.count == layout.MAX_STACK {
			return "target stack is full"
		}
		layout.remove(&s.view, source.id); b = layout.find(s.view.root, target)
		layout.stack_push(b, source.id)
	case .North, .East, .South, .West:
		layout.remove(&s.view, source.id); b = layout.find(s.view.root, target)
		b.split = (action == .East || action == .West) ? .Vertical : .Horizontal
		b.insert_stack = false
		b.insert_first = action == .North || action == .West
		layout.add(&s.view, source.id, target)
		if s.view.layout == .Scroll && source_width > 0 {
			if placed := layout.find(s.view.root, source.id); placed != nil {
				placed.column_width = source_width
				placed.column_resolved = source_width
				placed.column_size, placed.column_preset, placed.column_full =
					source_size, source_preset, source_full
			}
		}
	}
	return flush(m, s)
}

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
Touch_Point :: struct {
	x, y: f32,
}
Touch_Vector :: struct {
	position, velocity: Touch_Point,
}
Touch_Contact :: struct {
	frame:                   i32,
	timestamp:               f64,
	id, stage, finger, hand: i32,
	normalized:              Touch_Vector,
	size:                    f32,
	reserved:                i32,
	angle, major, minor:     f32,
	absolute:                Touch_Vector,
	reserved2, reserved3:    i32,
	density:                 f32,
}
Stack_Swipe_Tracker :: struct {
	sequence:                                                 u64,
	active, blocked, fired:                                   bool,
	ids:                                                      [3]i32,
	x, y:                                                     f64,
	began:                                                    f64,
	pending:                                                  i32,
	axis:                                                     i32,
	last_x, last_time, horizontal_delta, horizontal_velocity: f64,
	horizontal_samples:                                       Scroll_Velocity,
	horizontal_end:                                           bool,
}

// Counts/positions stay in memory only; the callback does no I/O or AX work.
stack_swipe_sample :: proc(t: ^Stack_Swipe_Tracker, contacts: []Touch_Contact, now: f64) {
	if len(contacts) == 0 {
		if t.active && t.axis == 1 {
			scroll_velocity_add(&t.horizontal_samples, 0, now)
			t.horizontal_velocity = scroll_velocity_get(&t.horizontal_samples)
			t.horizontal_end = true
		}
		t.active, t.blocked, t.fired = false, false, false; return
	}
	if len(contacts) != 3 {
		if t.active {
			if t.axis == 1 {
				scroll_velocity_add(&t.horizontal_samples, 0, now)
				t.horizontal_velocity = scroll_velocity_get(&t.horizontal_samples)
				t.horizontal_end = true
			}
			t.active, t.blocked = false, true
		}
		return
	}
	if t.blocked || t.fired {
		return
	}
	ids: [3]i32; x, y: f64
	for c, i in contacts {
		if (c.stage != 3 && c.stage != 4) ||
		   math.is_nan(f64(c.normalized.position.x)) ||
		   math.is_nan(f64(c.normalized.position.y)) ||
		   c.normalized.position.x < 0 ||
		   c.normalized.position.x > 1 ||
		   c.normalized.position.y < 0 ||
		   c.normalized.position.y > 1 {
			if t.active {
				if t.axis == 1 {
					t.horizontal_end = true; t.horizontal_velocity = 0
				}
				t.active, t.blocked = false, true
			}; return
		}
		ids[i] = c.id; x += f64(c.normalized.position.x) / 3; y += f64(c.normalized.position.y) / 3
	}
	for i in 1 ..< 3 {for j := i; j > 0 && ids[j] < ids[j - 1]; j -= 1 {ids[j], ids[j - 1] = ids[j - 1], ids[j]}}
	if !t.active {
		t.active = true; t.ids = ids; t.x, t.y, t.began = x, y, now; t.sequence += 1
		t.axis = 0; t.last_x, t.last_time = x, now
		t.horizontal_delta, t.horizontal_velocity = 0, 0; t.horizontal_end = false
		t.horizontal_samples = {}; scroll_velocity_add(&t.horizontal_samples, 0, now)
		return
	}
	if ids != t.ids || now < t.began || now - t.began > 4 {
		if t.axis == 1 {
			t.horizontal_end = true
		}
		t.active, t.blocked = false, true; return
	}
	dx, dy := x - t.x, y - t.y
	if t.axis == 0 && math.abs(dx) >= .025 && math.abs(dx) > math.abs(dy) * 1.5 {
		t.axis = 1; t.last_x = t.x
	}
	if t.axis == 1 {
		delta := x - t.last_x
		scroll_velocity_add(&t.horizontal_samples, delta, now)
		t.horizontal_velocity = scroll_velocity_get(&t.horizontal_samples)
		t.horizontal_delta += delta; t.last_x, t.last_time = x, now
		return
	}
	if t.axis == 0 && math.abs(dy) >= .06 && math.abs(dy) > math.abs(dx) * 1.5 {
		t.axis = 2
		t.pending = dy > 0 ? -1 : 1
		t.fired = true
	}
}

Touch_Callback :: proc "c" (
	device: Ref,
	contacts: [^]Touch_Contact,
	count: uint,
	timestamp: f64,
	frame: uint,
)
Touch_Register :: proc "c" (device: Ref, callback: Touch_Callback)
Touch_Start :: proc "c" (device: Ref, mode: i32) -> i32
Touch_Stop :: proc "c" (device: Ref) -> i32
Touch_List :: proc "c" () -> Ref
Stack_Touch_Shared :: struct {
	mutex:   sync.Mutex,
	tracker: Stack_Swipe_Tracker,
	enabled: bool,
}
stack_touch_shared: Stack_Touch_Shared
stack_touch_has_pending :: proc() -> bool {
	sync.mutex_lock(&stack_touch_shared.mutex)
	defer sync.mutex_unlock(&stack_touch_shared.mutex)
	t := &stack_touch_shared.tracker
	return(
		stack_touch_shared.enabled &&
		(t.horizontal_delta != 0 || t.horizontal_end || t.pending != 0) \
	)
}
Stack_Touch_State :: struct {
	library, devices, device:               Ref,
	unregister:                             Touch_Register,
	stop:                                   Touch_Stop,
	attempted:                              bool,
	wake_retries:                           int,
	retry_at:                               time.Time,
	sequence:                               u64,
	focus:                                  u32,
	generation:                             u64,
	horizontal_space:                       u64,
	horizontal_layout:                      layout.Layout,
	horizontal_active, horizontal_switched: bool,
	// The swipe began on a tabbed column: it steps tabs, not the camera.
	horizontal_tabs:                        bool,
	horizontal_travel:                      f64,
	horizontal_direction:                   i32,
}

stack_touch_callback :: proc "c" (
	_: Ref,
	contacts: [^]Touch_Contact,
	count: uint,
	timestamp: f64,
	_: uint,
) {
	context = runtime.default_context()
	if count > 32 || (count > 0 && contacts == nil) {
		return
	}
	sync.mutex_lock(&stack_touch_shared.mutex)
	defer sync.mutex_unlock(&stack_touch_shared.mutex)
	if stack_touch_shared.enabled {
		stack_swipe_sample(&stack_touch_shared.tracker, contacts[:int(count)], timestamp)
	}
}

// Builds where the 96-byte contact layout was checked against a live
// three-finger capture (26B123: probe 2026-11-07, stable ids and stages,
// positions in 0..1, velocities matching the swipe direction).
TOUCH_VALIDATED_BUILDS :: [?]string{"24G84", "26B123"}

touch_build_validated :: proc(build: string) -> bool {
	for validated in TOUCH_VALIDATED_BUILDS {
		if build == validated {
			return true
		}
	}
	return false
}

stack_touch_start :: proc(state: ^State) -> bool {
	t := &state.stack_touch
	// Contact structure offsets are validated only on the listed builds.
	build: [32]u8; length := uintptr(len(build))
	if sysctlbyname("kern.osversion", &build[0], &length, nil, 0) != 0 ||
	   length == 0 ||
	   length > uintptr(len(build)) ||
	   !touch_build_validated(string(cstring(&build[0]))) {
		return false
	}
	t.library = dlopen(
		"/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
		2,
	)
	if t.library == nil {
		return false
	}
	list := cast(Touch_List)dlsym(t.library, "MTDeviceCreateList")
	register := cast(Touch_Register)dlsym(t.library, "MTRegisterContactFrameCallback")
	t.unregister = cast(Touch_Register)dlsym(t.library, "MTUnregisterContactFrameCallback")
	start := cast(Touch_Start)dlsym(t.library, "MTDeviceStart")
	t.stop = cast(Touch_Stop)dlsym(t.library, "MTDeviceStop")
	if list == nil || register == nil || t.unregister == nil || start == nil || t.stop == nil {
		stack_touch_stop(state); return false
	}
	t.devices = list()
	// Only the one-device configuration tested on the host is enabled.
	if t.devices == nil || CFArrayGetCount(t.devices) != 1 {
		stack_touch_stop(state); return false
	}
	t.device = CFArrayGetValueAtIndex(t.devices, 0)
	if t.device == nil {
		stack_touch_stop(state); return false
	}
	sync.mutex_lock(&stack_touch_shared.mutex)
	stack_touch_shared.tracker = {}; stack_touch_shared.enabled = true
	sync.mutex_unlock(&stack_touch_shared.mutex)
	register(t.device, stack_touch_callback)
	if start(t.device, 0) != 0 {
		stack_touch_stop(state); return false
	}
	return true
}

stack_touch_stop :: proc(state: ^State) {
	t := &state.stack_touch
	if t.horizontal_active {
		if s := space_by_id(&state.manager, t.horizontal_space); s != nil {
			s.view.scroll.dragging = false
		}
	}
	sync.mutex_lock(&stack_touch_shared.mutex)
	stack_touch_shared.enabled = false; stack_touch_shared.tracker = {}
	sync.mutex_unlock(&stack_touch_shared.mutex)
	if t.device != nil && t.unregister != nil {
		t.unregister(t.device, stack_touch_callback)
	}
	if t.device != nil && t.stop != nil {
		_ = t.stop(t.device)
	}
	if t.devices != nil {
		CFRelease(t.devices)
	}
	if t.library != nil {
		_ = dlclose(t.library)
	}
	t^ = {}
}

stack_touch_wake :: proc(state: ^State, now: time.Time = {}) {
	now := now
	if (now == time.Time{}) {
		now = time.now()
	}
	// Sleep can leave a registered device silent. Recreate the subscription
	// after wake, allowing the device a bounded interval to become available.
	stack_touch_stop(state)
	if state.manager.mouse.stack_swipe || state.manager.mouse.three_finger_horizontal {
		state.stack_touch.wake_retries = 10
		state.stack_touch.retry_at = time.time_add(now, time.Second)
	}
}

stack_touch_tick :: proc(
	state: ^State,
	now: time.Time = {},
	start: proc(state: ^State) -> bool = stack_touch_start,
) {
	now := now
	if (now == time.Time{}) {
		now = time.now()
	}
	t := &state.stack_touch; m := &state.manager
	if !m.mouse.stack_swipe && !m.mouse.three_finger_horizontal {
		if t.library != nil || t.attempted || t.wake_retries != 0 {
			stack_touch_stop(state)
		}
		return
	}
	if !t.attempted || (t.library == nil && t.wake_retries > 0) {
		if (t.retry_at != time.Time{}) && time.diff(now, t.retry_at) > 0 {
			return
		}
		retries := t.wake_retries
		t.attempted = true
		if !start(state) {
			t.attempted = true
			t.wake_retries = max(0, retries - 1)
			t.retry_at = time.time_add(now, time.Second)
			if t.wake_retries == 0 {
				fmt.eprintln("shoji: three-finger stack gesture unavailable")
			}
			return
		}
		t.wake_retries = 0; t.retry_at = {}
		if retries > 0 {
			fmt.eprintln("shoji: trackpad subscription restored after wake")
		}
	}
	if t.library == nil {
		return
	}
	sync.mutex_lock(&stack_touch_shared.mutex)
	tracker := &stack_touch_shared.tracker
	seq, direction := tracker.sequence, tracker.pending
	delta, velocity, ended :=
		tracker.horizontal_delta, tracker.horizontal_velocity, tracker.horizontal_end
	stack_touch_shared.tracker.pending = 0
	tracker.horizontal_delta, tracker.horizontal_end = 0, false
	sync.mutex_unlock(&stack_touch_shared.mutex)
	if delta != 0 || ended {
		motion_trace_record(
			&m.motion_trace,
			{
				kind = ended ? "three-finger-end" : "three-finger-pan",
				space = m.active_space,
				value = delta,
			},
		)
	}
	if seq != t.sequence {
		if t.horizontal_active {
			if old := space_by_id(m, t.horizontal_space); old != nil {
				old.view.scroll.dragging = false
			}
		}
		t.sequence = seq; t.focus = m.focused
		w := m.windows[t.focus]; t.generation = w != nil ? w.generation : 0
		t.horizontal_space = m.active_space
		s := space_by_id(m, t.horizontal_space)
		t.horizontal_layout = s != nil ? s.view.layout : .Float
		t.horizontal_active, t.horizontal_switched, t.horizontal_travel, t.horizontal_direction =
			false, false, 0, 0
		t.horizontal_tabs = s != nil && touch_focus_tabbed(m, s)
		// Require a main-loop observation of the beginning before accepting.
		if direction != 0 {
			return
		}
	}
	if m.mouse.stack_swipe {
		stack_swipe_apply(state, t.focus, t.generation, direction)
	}
	if m.mouse.three_finger_horizontal {
		stack_touch_horizontal(state, delta, velocity, ended)
	} else if t.horizontal_active {
		if s := space_by_id(m, t.horizontal_space); s != nil {
			s.view.scroll.dragging = false
		}
		t.horizontal_active = false
	}
}

stack_touch_horizontal :: proc(state: ^State, delta, velocity: f64, ended: bool) {
	t := &state.stack_touch; m := &state.manager
	s := space_by_id(m, t.horizontal_space)
	if s == nil ||
	   !s.visible ||
	   s.view.layout != t.horizontal_layout ||
	   m.suspended ||
	   m.gesture_active ||
	   state.mouse.drag.window != 0 {
		if s != nil && t.horizontal_active {
			s.view.scroll.dragging = false
		}
		t.horizontal_active = false; return
	}
	if s.view.layout == .BSP {
		t.horizontal_travel -= delta
		if !t.horizontal_switched && math.abs(t.horizontal_travel) >= .08 {
			t.horizontal_switched = true
			if err := space_gesture_switch(m, s.id, t.horizontal_travel > 0 ? 1 : -1); err != "" {
				fmt.eprintln("shoji: three-finger Space swipe:", err)
			}
		}
		return
	}
	if s.view.layout != .Scroll {
		return
	}
	if t.horizontal_tabs {
		// One step per swipe, like the BSP Space switch. Directional focus
		// walks the tabs (top bar) and continues into the adjacent column.
		t.horizontal_travel -= delta
		if !t.horizontal_switched && math.abs(t.horizontal_travel) >= TOUCH_TAB_STEP_TRAVEL {
			t.horizontal_switched = true
			direction := t.horizontal_travel > 0 ? "east" : "west"
			// Past the last tab of the edge column there is nothing to focus;
			// that is the end of the strip, not an error.
			if response := execute(m, {"window", "--focus", direction});
			   response.failed && !strings.contains(response.text, "could not locate window") {
				fmt.eprintln("shoji: three-finger tab swipe:", response.text)
			}
		}
		return
	}
	if delta != 0 {
		t.horizontal_travel -= delta
		if math.abs(delta) >= .001 {
			t.horizontal_direction = delta > 0 ? -1 : 1
		}
		if !t.horizontal_active {
			scroll_begin_pan(m, s); t.horizontal_active = true
		}
		if err := scroll_gesture_pan(m, s.id, -delta * s.view.scroll.viewport.w * 1.2); err != "" {
			fmt.eprintln("shoji: three-finger scroll:", err); s.view.scroll.dragging = false
			t.horizontal_active = false; return
		}
	}
	if ended && t.horizontal_active {
		t.horizontal_active = false
		release_velocity := clamp(
			-velocity * s.view.scroll.viewport.w * 1.2,
			-s.view.scroll.viewport.w * .75,
			s.view.scroll.viewport.w * .75,
		)
		// A slow lift can report zero velocity after reaching the viewport
		// boundary. Preserve travel direction when choosing the visible focus.
		if math.abs(release_velocity) < 120 && t.horizontal_direction != 0 {
			release_velocity = f64(t.horizontal_direction) * max(.01, math.abs(release_velocity))
		}
		step: i32
		if math.abs(t.horizontal_travel) >= .025 {
			step = t.horizontal_travel > 0 ? 1 : -1
		}
		if err := scroll_finish_pan(m, s, release_velocity, true, step); err != "" {
			fmt.eprintln("shoji: three-finger scroll release:", err)
		}
	}
}

// Normalized trackpad travel that commits one tab step.
TOUCH_TAB_STEP_TRAVEL :: .08

touch_focus_tabbed :: proc(m: ^Manager, s: ^Space) -> bool {
	if s.view.layout != .Scroll {
		return false
	}
	n := layout.find(s.view.root, m.focused)
	return n != nil && n.column_tabbed && n.count > 1
}

stack_swipe_apply :: proc(state: ^State, focus: u32, generation: u64, direction: i32) {
	m := &state.manager
	if direction == 0 ||
	   m.suspended ||
	   m.gesture_active ||
	   state.mouse.drag.window != 0 ||
	   focus != m.focused {
		return
	}
	w := m.windows[focus]
	if w == nil || w.generation != generation {
		return
	}
	s := space_by_id(m, w.space)
	if s == nil || !s.visible || s.view.layout != .BSP {
		return
	}
	n := layout.find(s.view.root, w.id)
	if n == nil || n.count < 2 {
		return
	}
	selector := direction > 0 ? "stack.next" : "stack.prev"
	if target := select_window(m, selector); target != nil {
		response := execute(m, {"window", "--focus", selector})
		if response.failed {
			fmt.eprintln("shoji: stack swipe:", response.text)
		}
	}
}

// Gesture routing
// ------------------------------------------------------------------------

Scroll_Sample :: struct {
	x, y:      f64,
	modifiers: u64,
	phase:     u64,
	momentum:  i64,
}
Scroll_Gesture :: struct {
	owned:    bool,
	space:    u64,
	last:     f64,
	layout:   layout.Layout,
	travel:   f64,
	switched: bool,
}

// Latch the operation as well as the originating Space. Crossing to a scroll
// Space must not turn the tail of a BSP swipe into column movement.
layout_gesture_route :: proc(
	g: ^Scroll_Gesture,
	sample: Scroll_Sample,
	space: u64,
	layout: layout.Layout,
	modifier: u64,
	enabled: bool,
	now: f64,
) -> (
	bool,
	f64,
	int,
) {
	fresh :=
		g.space == 0 ||
		sample.phase & (1 | 128) != 0 ||
		now - g.last > 1 ||
		(sample.phase == 0 && sample.momentum == 0 && now - g.last > 0.25)
	if fresh {
		g.layout, g.travel, g.switched = layout, 0, false
	}
	consume, delta := scroll_gesture_route(g, sample, space, modifier, enabled, now)
	if !consume {
		return false, 0, 0
	}
	if g.layout != .BSP {
		return true, delta, 0
	}
	if sample.momentum == 0 && sample.phase & 8 == 0 && !g.switched {
		g.travel += delta
		if math.abs(g.travel) >= 80 {
			g.switched = true
			return true, 0, g.travel > 0 ? 1 : -1
		}
	}
	return true, 0, 0
}

space_gesture_switch :: proc(
	m: ^Manager,
	origin: u64,
	direction: int,
	any_layout: bool = false,
) -> string {
	s := space_by_id(m, origin)
	if direction == 0 ||
	   s == nil ||
	   !s.visible ||
	   m.suspended ||
	   m.gesture_active ||
	   (s.view.layout != .BSP && !any_layout) {
		return ""
	}
	d := display_by_id(m, s.display)
	if d == nil || d.active_space != origin {
		return ""
	}
	// Native indices are ordered across displays. Filter by the originating
	// display for both adjacency and cyclic wraparound.
	target: ^Space
	wrapped: ^Space
	for candidate in m.spaces {
		if candidate.display != s.display {
			continue
		}
		if wrapped == nil ||
		   (direction > 0 ? candidate.index < wrapped.index : candidate.index > wrapped.index) {
			wrapped = candidate
		}
		if direction > 0 &&
		   candidate.index > s.index &&
		   (target == nil || candidate.index < target.index) {
			target = candidate
		}
		if direction < 0 &&
		   candidate.index < s.index &&
		   (target == nil || candidate.index > target.index) {
			target = candidate
		}
	}
	if target == nil {
		target = wrapped
	}
	if target == nil || target.id == origin {
		return ""
	}
	return perform(m, {kind = .Space_Focus, space = target.id})
}

// Middle-button view movement. Horizontal travel pans immediately. A workspace
// switch commits on release only when vertical travel reaches the same 80-point
// threshold as a Space swipe and is the larger component, so a pan or a
// reversed drag does not switch.
VIEW_DRAG_SWITCH :: 80.0
View_Drag :: struct {
	active, panning:      bool,
	space:                u64,
	origin, last:         Mouse_Point,
	horizontal, vertical: f64,
}

view_drag_begin :: proc(d: ^View_Drag, space: u64, point: Mouse_Point) {
	d^ = {
		active = true,
		space  = space,
		origin = point,
		last   = point,
	}
}

view_drag_sample :: proc(d: ^View_Drag, point: Mouse_Point) -> f64 {
	if !d.active ||
	   math.is_nan(point.x) ||
	   math.is_nan(point.y) ||
	   math.is_inf(point.x) ||
	   math.is_inf(point.y) {
		return 0
	}
	dx := point.x - d.last.x
	dy := point.y - d.last.y
	d.last = point
	d.horizontal += dx
	d.vertical += dy
	return dx
}

view_drag_direction :: proc(d: View_Drag) -> int {
	if !d.active ||
	   math.abs(d.vertical) < VIEW_DRAG_SWITCH ||
	   math.abs(d.vertical) <= math.abs(d.horizontal) {
		return 0
	}
	return d.vertical > 0 ? 1 : -1
}
// Physical scroll phase is a bitmask; CG momentum phase is a separate enum.
// Once captured, the tail stays with its original Space, even if the modifier
// is released. Unclaimed application momentum is never intercepted.
scroll_gesture_route :: proc(
	g: ^Scroll_Gesture,
	sample: Scroll_Sample,
	space, modifier: u64,
	enabled: bool,
	now: f64,
) -> (
	bool,
	f64,
) {
	if !enabled ||
	   math.is_nan(sample.x) ||
	   math.is_inf(sample.x) ||
	   math.is_nan(sample.y) ||
	   math.is_inf(sample.y) {
		g.owned = false; return false, 0
	}
	if now - g.last > 1 || sample.phase & (1 | 128) != 0 {
		g.owned = false
	}
	g.last = now
	if sample.momentum != 0 {
		owned := g.owned
		if sample.momentum == 3 {
			g.owned = false
		}
		return owned, owned ? -sample.x : 0
	}
	if sample.phase == 0 {
		g.owned = false
		if space != 0 && sample.modifiers == modifier && math.abs(sample.x) > math.abs(sample.y) {
			g.space = space; return true, -sample.x
		}
		return false, 0
	}
	if !g.owned &&
	   space != 0 &&
	   sample.modifiers == modifier &&
	   math.abs(sample.x) > math.abs(sample.y) {
		g.owned, g.space = true, space
	}
	owned := g.owned
	if sample.phase & 8 != 0 {
		g.owned = false
	}
	return owned, owned ? -sample.x : 0
}

scroll_gesture_pan :: proc(m: ^Manager, space: u64, delta: f64) -> string {
	s := space_by_id(m, space)
	if s == nil || !s.visible || s.view.layout != .Scroll || m.suspended || m.gesture_active {
		return ""
	}
	if math.is_nan(delta) || math.is_inf(delta) {
		return "invalid scroll delta"
	}
	layout.scroll_pan(&s.view, s.view.scroll.offset + delta)
	if m.scroll_animate {
		return flush(m, s)
	}
	// Input already carries the system's momentum curve. Applying another
	// window animation per sample would lag behind the pointer.
	duration := m.animation_duration
	m.animation_duration = 0
	defer m.animation_duration = duration
	return flush(m, s)
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
	mode := layout.Layout.Float
	if display := display_by_id(m, m.mouse_display); display != nil {
		if s := space_by_id(m, display.active_space);
		   s != nil && (s.view.layout == .Scroll || s.view.layout == .BSP) {
			space = s.id
			mode = s.view.layout
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
	consume, delta, direction := layout_gesture_route(
		&state.mouse.scroll,
		{x, y, CGEventGetFlags(event) & MOUSE_MODIFIERS, phase, momentum},
		space,
		mode,
		m.mouse.modifier,
		m.mouse.scroll && !(m.mouse.three_finger_horizontal && state.stack_touch.library != nil),
		seconds,
	)
	if consume {
		motion_trace_record(
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
			if !mouse.scroll_tracking || old_space != mouse.scroll.space || phase & 1 != 0 {
				mouse.scroll_velocity = {}
				mouse.scroll_delta = 0
				mouse.scroll_tracking, mouse.scroll_begin, mouse.scroll_end = true, true, false
			}
			mouse.scroll_phase_less = phase == 0
			if continuous {
				if s := space_by_id(m, mouse.scroll.space); s != nil {
					delta *= s.view.scroll.viewport.w / 1200
				}
			}
			mouse.scroll_delta += delta
			scroll_velocity_add(&mouse.scroll_velocity, delta, event_seconds)
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
	s := space_by_id(m, mouse.scroll.space)
	if s == nil || !s.visible || s.view.layout != .Scroll || m.suspended || m.gesture_active {
		if s != nil {
			s.view.scroll.dragging = false
		}
		mouse.scroll_tracking, mouse.scroll_begin, mouse.scroll_end = false, false, false
		mouse.scroll_delta = 0
		return
	}
	seconds := time.duration_seconds(time.diff(time.Time{}, now))
	if (mouse.scroll_phase_less && seconds - mouse.scroll_last >= 0.12) ||
	   seconds - mouse.scroll_last > 1 {
		scroll_velocity_add(&mouse.scroll_velocity, 0, seconds)
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
	defer motion_trace_record(
		&m.motion_trace,
		{
			kind = "gesture-sample",
			space = s.id,
			duration_ms = m.motion_trace.active ? f64(time.tick_since(started)) / 1e6 : 0,
		},
	)
	motion_trace_record(
		&m.motion_trace,
		{kind = "input-consume", space = s.id, value = mouse.scroll_delta},
	)
	if mouse.scroll_begin {
		scroll_begin_pan(m, s); mouse.scroll_begin = false
	}
	delta := mouse.scroll_delta; mouse.scroll_delta = 0
	if delta != 0 {
		if err := scroll_gesture_pan(m, s.id, delta); err != "" {
			fmt.eprintln("shoji: scroll:", err); s.view.scroll.dragging = false
			mouse.scroll_tracking = false; return
		}
	}
	if mouse.scroll_end {
		mouse.scroll_end, mouse.scroll_tracking = false, false
		if err := scroll_finish_pan(m, s, scroll_velocity_get(&mouse.scroll_velocity)); err != "" {
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
	defer motion_trace_record(
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
	if err := scroll_motion_tick(
		&state.manager,
		time.duration_seconds(time.diff(time.Time{}, now)),
	); err != "" {
		fmt.eprintln("shoji: scroll motion:", err)
	}
}
