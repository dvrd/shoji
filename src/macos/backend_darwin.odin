package macos

import e "../engine"
import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import objc "core:sys/darwin/Foundation"

Application :: struct {
	element, observer: Ref,
	name:              string,
	hidden:            bool,
	policy:            int,
}

State :: struct {
	opening_tracking: bool,
	opening_collecting: bool,
	structural_dirty: bool,
	opening_backend: e.Opening_Backend,
	opening_guards: map[u32]Opening_Guard,
	opening_notice: Owned_Surface,
	resize_covers: map[u32]Resize_Cover,
	resize_cover_backend: Resize_Cover_Backend,
	resize_snapshots: map[u32]Resize_Snapshots,
	resize_cover_retry: f64,
	resize_cover_cancel: bool,
	display_clock: Display_Clock,
	opening_windows: map[u32]bool,
	frame_updates:         Frame_Updates,
	validation_pid:        i32,
	display_probe:         Display_Probe,
	window_probe:          Window_Probe,
	animation_journal:     Animation_Journal,
	observed:              Snapshot,
	display_focus_backend: Display_Focus_Backend,
	feedback:              map[u32]Feedback_Window,
	feedback_backend:      Feedback_Backend,
	read_only:             bool,
	animations:            map[u32]Animation_Job,
	animation_backend:     Animation_Backend,
	event_sink:            proc(user: rawptr, event: Event),
	event_user:            rawptr,
	workspace_events:      Workspace_State,
	mouse:                 Mouse_State,
	manager:               e.Manager,
	windows:               map[u32]Ref,
	applications:          map[i32]Application,
	connection:            i32,
	dirty:                 bool,
}

observer_callback :: proc "c" (observer, element, notification: Ref, user: rawptr) {
	context = runtime.default_context()
	state := (^State)(user)
	state.dirty = true
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch);defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	name := text(notification)
	if name == "AXUIElementDestroyed" {state.structural_dirty = true;opening_destroyed(state, element);return}
	// AXCreated can precede AXWindowCreated for AppKit, but also announces
	// controls. Only independent windows require a structural refresh.
	if name == "AXWindowCreated" || (name == "AXCreated" && attribute_text(element, "AXRole") == "AXWindow") {
		state.structural_dirty = true;opening_created(state, observer, element)
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
	e.manager_init(&state.manager, perform, state)
	state.manager.resize_fade = true
	state.manager.scroll_animate = true
	state.manager.scroll_frame_pacing = true
}

state_destroy :: proc(state: ^State) {
	resize_cover_stop(state)
	display_clock_stop(&state.display_clock)
	opening_stop(state)
	snapshot_destroy(&state.observed)
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
	e.manager_destroy(&state.manager)
}

perform :: proc(user: rawptr, action: e.Action) -> string {
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
		}; return err
	}
	if element == nil {
		return "window no longer has an Accessibility reference"
	}
	#partial switch action.kind {
	case .Expose:
		if err := perform(state, {kind = .Focus, window = action.window});
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
		if code := AXUIElementPerformAction(element, raise); code != 0 {
			return fmt.tprintf("Accessibility raise failed (%d)", code)
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
	return ""
}

Display_Probe :: struct {
	list: proc(state: ^State, ids: []u32, count: ^u32) -> i32,
	spaces: proc(state: ^State) -> Ref,
}
native_display_list :: proc(_: ^State, ids: []u32, count: ^u32) -> i32 {
	return CGGetActiveDisplayList(u32(len(ids)), raw_data(ids), count)
}
native_display_spaces :: proc(state: ^State) -> Ref {return SLSCopyManagedDisplaySpaces(state.connection)}

refresh_displays :: proc(state: ^State) {
	m := &state.manager
	probe := state.display_probe
	if probe.list == nil {probe = {native_display_list, native_display_spaces}}
	ids: [64]u32
	count: u32
	// A failed observation must not destroy labels, display membership or trees.
	if probe.list(state, ids[:], &count) != 0 || count == 0 || count > len(ids) {return}
	data := probe.spaces(state)
	if data == nil {return}
	defer CFRelease(data)
	if CFArrayGetCount(data) == 0 {return}
	for i in 0 ..< CFArrayGetCount(data) {
		entry := CFArrayGetValueAtIndex(data, i)
		spaces := dictionary(entry, "Spaces")
		if spaces == nil || CFArrayGetCount(spaces) == 0 {return}
		for j in 0 ..< CFArrayGetCount(spaces) {
			if number(dictionary(CFArrayGetValueAtIndex(spaces, j), "id64")) == 0 {return}
		}
	}
	labels := make(map[u32]string, context.temp_allocator)
	for &d in m.displays {
		labels[d.id] = d.label
		delete(d.uuid)
		delete(d.spaces)
	}
	clear(&m.displays)
	defer {
		for _, label in labels {
			delete(label)
		}
	}
	primary_height := CGDisplayBounds(CGMainDisplayID()).h
	m.main_display = CGMainDisplayID()
	screens := intrinsics.objc_send(^objc.Object, objc.Screen, "screens")
	for id, i in ids[:count] {
		d := e.Display {
			id           = id,
			index        = u32(i + 1),
			native_index = u32(i + 1),
			frame        = CGDisplayBounds(id),
		}
		d.usable = d.frame
		d.label = labels[id]
		delete_key(&labels, id)
		uuid := CGDisplayCreateUUIDFromDisplayID(id)
		if uuid != nil {
			string := CFUUIDCreateString(nil, uuid)
			CFRelease(uuid)
			if string != nil {
				d.uuid = strings.clone(text(string))
				d.active_space = SLSManagedDisplayGetCurrentSpace(state.connection, string)
				CFRelease(string)
			}
		}
		for j in 0 ..< intrinsics.objc_send(uint, screens, "count") {
			screen := intrinsics.objc_send(^objc.Object, screens, "objectAtIndex:", j)
			description := intrinsics.objc_send(^objc.Object, screen, "deviceDescription")
			key := cf_string("NSScreenNumber")
			number := intrinsics.objc_send(
				^objc.Object,
				description,
				"objectForKey:",
				(^objc.Object)(key),
			)
			CFRelease(key)
			if intrinsics.objc_send(u32, number, "unsignedIntValue") == id {
				r := intrinsics.objc_send(e.Rect, screen, "visibleFrame")
				d.usable = {r.x, primary_height - r.y - r.h, r.w, r.h}
				break
			}
		}
		append(&m.displays, d)
	}
	e.order_displays(m)
	seen := make(map[u64]bool, context.temp_allocator)
	index: u32 = 0
	for i in 0 ..< CFArrayGetCount(data) {
		entry := CFArrayGetValueAtIndex(data, i)
		identifier := dictionary(entry, "Display Identifier")
		d: ^e.Display
		for &display in m.displays {
			if display.uuid == text(identifier) {
				d = &display
				break
			}
		}
		if d == nil {
			continue
		}
		spaces := dictionary(entry, "Spaces")
		if spaces == nil {
			continue
		}
		for j in 0 ..< CFArrayGetCount(spaces) {
			item := CFArrayGetValueAtIndex(spaces, j)
			id := number(dictionary(item, "id64"))
			if id == 0 {
				continue
			}
			index += 1
			seen[id] = true
			s := e.space_by_id(m, id)
			if s == nil {
				s = e.add_space(m, id, d.id, index, e.usable_frame(m, d))
			}
			s.index = index
			s.display = d.id
			s.view.frame = e.usable_frame(m, d)
			s.visible = d.active_space == id
			s.fullscreen = number(dictionary(item, "type")) == 4
			if s.uuid == "" {
				s.uuid = strings.clone(text(dictionary(item, "uuid")))
			}
			append(&d.spaces, id)
		}
	}
	for i := len(m.spaces) - 1; i >= 0; i -= 1 {
		s := m.spaces[i]
		if !seen[s.id] {
			e.view_destroy(&s.view)
			delete(s.overrides)
			delete(s.uuid)
			delete(s.label)
			free(s)
			ordered_remove(&m.spaces, i)
		}
	}
	for i in 1 ..< len(m.spaces) {
		for j := i; j > 0 && m.spaces[j - 1].index > m.spaces[j].index; j -= 1 {
			m.spaces[j - 1], m.spaces[j] = m.spaces[j], m.spaces[j - 1]
		}
	}
	active := SLSCopyActiveMenuBarDisplayIdentifier(state.connection)
	if active != nil {
		sid := SLSManagedDisplayGetCurrentSpace(state.connection, active)
		CFRelease(active)
		if sid != m.active_space {
			m.last_space = m.active_space
			m.active_space = sid
		}
	}
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

window_is_root :: proc(state: ^State, id: u32, element, application: Ref) -> bool {
	id := id
	number := CFNumberCreate(nil, 3, &id);defer CFRelease(number)
	array := CFArrayCreate(nil, &number, 1, nil);defer CFRelease(array)
	query := SLSWindowQueryWindows(state.connection, array, 1)
	parent_id: u32
	if query != nil {
		defer CFRelease(query)
		iterator := SLSWindowQueryResultCopyWindows(query)
		if iterator != nil {
			defer CFRelease(iterator)
			if SLSWindowIteratorGetCount(iterator) == 1 && SLSWindowIteratorAdvance(iterator) {
				parent_id = SLSWindowIteratorGetParentID(iterator)
			}
		}
	}
	if parent_id == 0 {return true}
	parent := attribute(element, "AXParent")
	if parent == nil {return false};defer CFRelease(parent)
	return CFEqual(parent, application)
}
window_frame :: proc(element: Ref) -> e.Rect {
	p: Point
	size: Size
	position := attribute(element, "AXPosition")
	if position != nil {
		AXValueGetValue(position, 1, &p)
		CFRelease(position)
	}
	dimensions := attribute(element, "AXSize")
	if dimensions != nil {
		AXValueGetValue(dimensions, 2, &size)
		CFRelease(dimensions)
	}
	return {p.x, p.y, size.w, size.h}
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
