package shoji

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
	horizontal_samples: Scroll_Velocity,
	horizontal_end: bool,
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
		t.horizontal_samples = {}; scroll_velocity_add(&t.horizontal_samples, 0, now)
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
	wake_retries: int,
	retry_at: time.Time,
	sequence: u64,
	focus: u32,
	generation: u64,
	horizontal_space: u64,
	horizontal_layout: Layout,
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
		if s := space_by_id(&state.manager, t.horizontal_space); s != nil { s.view.scroll.dragging = false }
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

stack_touch_wake :: proc(state: ^State, now: time.Time = {}) {
	now := now
	if (now == time.Time{}) { now = time.now() }
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
	if (now == time.Time{}) { now = time.now() }
	t := &state.stack_touch; m := &state.manager
	if !m.mouse.stack_swipe && !m.mouse.three_finger_horizontal {
		if t.library != nil || t.attempted || t.wake_retries != 0 { stack_touch_stop(state) }
		return
	}
	if !t.attempted || (t.library == nil && t.wake_retries > 0) {
		if (t.retry_at != time.Time{}) && time.diff(now, t.retry_at) > 0 { return }
		retries := t.wake_retries
		t.attempted = true
		if !start(state) {
			t.attempted = true
			t.wake_retries = max(0, retries - 1)
			t.retry_at = time.time_add(now, time.Second)
			if t.wake_retries == 0 { fmt.eprintln("shoji: three-finger stack gesture unavailable") }
			return
		}
		t.wake_retries = 0; t.retry_at = {}
		if retries > 0 { fmt.eprintln("shoji: trackpad subscription restored after wake") }
	}
	if t.library == nil { return }
	sync.mutex_lock(&stack_touch_shared.mutex)
	tracker := &stack_touch_shared.tracker
	seq, direction := tracker.sequence, tracker.pending
	delta, velocity, ended := tracker.horizontal_delta, tracker.horizontal_velocity, tracker.horizontal_end
	stack_touch_shared.tracker.pending = 0
	tracker.horizontal_delta, tracker.horizontal_end = 0, false
	sync.mutex_unlock(&stack_touch_shared.mutex)
	if delta != 0 || ended {
		motion_trace_record(
			&m.motion_trace,
			{kind = ended ? "three-finger-end" : "three-finger-pan", space = m.active_space, value = delta},
		)
	}
	if seq != t.sequence {
		if t.horizontal_active {
			if old := space_by_id(m, t.horizontal_space); old != nil { old.view.scroll.dragging = false }
		}
		t.sequence = seq; t.focus = m.focused
		w := m.windows[t.focus]; t.generation = w != nil ? w.generation : 0
		t.horizontal_space = m.active_space
		s := space_by_id(m, t.horizontal_space)
		t.horizontal_layout = s != nil ? s.view.layout : .Float
		t.horizontal_active, t.horizontal_switched, t.horizontal_travel, t.horizontal_direction = false, false, 0, 0
		// Require a main-loop observation of the beginning before accepting.
		if direction != 0 { return }
	}
	if m.mouse.stack_swipe { stack_swipe_apply(state, t.focus, t.generation, direction) }
	if m.mouse.three_finger_horizontal {
		stack_touch_horizontal(state, delta, velocity, ended)
	} else if t.horizontal_active {
		if s := space_by_id(m, t.horizontal_space); s != nil { s.view.scroll.dragging = false }
		t.horizontal_active = false
	}
}

stack_touch_horizontal :: proc(state: ^State, delta, velocity: f64, ended: bool) {
	t := &state.stack_touch; m := &state.manager
	s := space_by_id(m, t.horizontal_space)
	if s == nil || !s.visible || s.view.layout != t.horizontal_layout || m.suspended || m.gesture_active || state.mouse.drag.window != 0 {
		if s != nil && t.horizontal_active { s.view.scroll.dragging = false }
		t.horizontal_active = false; return
	}
	if s.view.layout == .BSP {
		t.horizontal_travel -= delta
		if !t.horizontal_switched && math.abs(t.horizontal_travel) >= .08 {
			t.horizontal_switched = true
			if err := space_gesture_switch(m, s.id, t.horizontal_travel > 0 ? 1 : -1); err != "" { fmt.eprintln("shoji: three-finger Space swipe:", err) }
		}
		return
	}
	if s.view.layout != .Scroll { return }
	if delta != 0 {
		t.horizontal_travel -= delta
		if math.abs(delta) >= .001 { t.horizontal_direction = delta > 0 ? -1 : 1 }
		if !t.horizontal_active { scroll_begin_pan(m, s); t.horizontal_active = true }
		if err := scroll_gesture_pan(m, s.id, -delta * s.view.scroll.viewport.w * 1.2); err != "" {
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
		if err := scroll_finish_pan(m, s, release_velocity, true, step); err != "" { fmt.eprintln("shoji: three-finger scroll release:", err) }
	}
}

stack_swipe_apply :: proc(state: ^State, focus: u32, generation: u64, direction: i32) {
	m := &state.manager
	if direction == 0 || m.suspended || m.gesture_active || state.mouse.drag.window != 0 || focus != m.focused { return }
	w := m.windows[focus]
	if w == nil || w.generation != generation { return }
	s := space_by_id(m, w.space)
	if s == nil || !s.visible || s.view.layout != .BSP { return }
	n := find(s.view.root, w.id)
	if n == nil || n.count < 2 { return }
	selector := direction > 0 ? "stack.next" : "stack.prev"
	if target := select_window(m, selector); target != nil {
		response := execute(m, {"window", "--focus", selector})
		if response.failed { fmt.eprintln("shoji: stack swipe:", response.text) }
	}
}
