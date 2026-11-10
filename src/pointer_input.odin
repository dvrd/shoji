package shoji

import "base:runtime"
import "core:fmt"
import "core:math"
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
