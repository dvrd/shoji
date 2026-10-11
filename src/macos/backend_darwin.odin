package macos

import e "../engine"
import "base:intrinsics"
import "core:fmt"
import "core:strings"
import objc "core:sys/darwin/Foundation"

Application :: struct {
	element, observer: Ref,
	name:              string,
	hidden:            bool,
}

State :: struct {
	feedback:          map[u32]Feedback_Window,
	feedback_backend:  Feedback_Backend,
	read_only:         bool,
	animations:        map[u32]Animation_Job,
	animation_backend: Animation_Backend,
	event_sink:        proc(user: rawptr, event: Event),
	event_user:        rawptr,
	workspace_events:  Workspace_State,
	mouse:             Mouse_State,
	manager:           e.Manager,
	windows:           map[u32]Ref,
	applications:      map[i32]Application,
	connection:        i32,
	dirty:             bool,
}

observer_callback :: proc "c" (observer, element, notification: Ref, user: rawptr) {
	state := (^State)(user)
	state.dirty = true
}

observe :: proc(state: ^State, observer, element: Ref, name: string) {
	notification := cf_string(name)
	defer CFRelease(notification)
	AXObserverAddNotification(observer, element, notification, state)
}

state_init :: proc(state: ^State) {
	state.windows = make(map[u32]Ref)
	state.applications = make(map[i32]Application)
	state.connection = SLSMainConnectionID()
	state.dirty = true
	e.manager_init(&state.manager, perform, state)
}

state_destroy :: proc(state: ^State) {
	feedback_stop(state)
	animation_stop(state)
	for _, element in state.windows {
		CFRelease(element)
	}
	delete(state.windows)
	for _, app in state.applications {
		if app.observer != nil {
			CFRunLoopRemoveSource(
				CFRunLoopGetMain(),
				AXObserverGetRunLoopSource(app.observer),
				kCFRunLoopDefaultMode,
			)
			CFRelease(app.observer)
		}
		CFRelease(app.element)
		delete(app.name)
	}
	delete(state.applications)
	e.manager_destroy(&state.manager)
}

perform :: proc(user: rawptr, action: e.Action) -> string {
	state := (^State)(user)
	if state.read_only {return "window operations are disabled in read-only inspection"}
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
		err := addition_action(action);if err == "" {state.dirty = true};return err
	}
	if element == nil {
		return "window no longer has an Accessibility reference"
	}
	#partial switch action.kind {
	case .Expose:
		if err := perform(state, {kind = .Focus, window = action.window}); err != "" {return err}
		notification := cf_string("com.apple.expose.front.awake")
		defer CFRelease(notification)
		if CoreDockSendNotification(notification, 0) !=
		   0 {return "could not request application Expose"}
	case .Frame:
		if action.duration > 0 {return animation_start(state, action)}
		p := Point{action.frame.x, action.frame.y}
		size := Size{action.frame.w, action.frame.h}
		position := AXValueCreate(1, &p)
		defer CFRelease(position)
		dimensions := AXValueCreate(2, &size)
		defer CFRelease(dimensions)
		// Some applications clamp a size change at the old position; repeat after moving.
		set_attribute(element, "AXSize", dimensions)
		a := set_attribute(element, "AXPosition", position)
		b := set_attribute(element, "AXSize", dimensions)
		if a != 0 || b != 0 {
			return fmt.tprintf("Accessibility could not set window frame (%d, %d)", a, b)
		}
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
		if app == nil || !intrinsics.objc_send(bool, app, "activateWithOptions:", uint(2)) {
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

refresh_displays :: proc(state: ^State) {
	m := &state.manager
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
	ids: [64]u32
	count: u32
	if CGGetActiveDisplayList(len(ids), &ids[0], &count) != 0 {
		return
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
	data := SLSCopyManagedDisplaySpaces(state.connection)
	if data == nil {
		return
	}
	defer CFRelease(data)
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
	number := CFNumberCreate(nil, 3, &id)
	defer CFRelease(number)
	array := CFArrayCreate(nil, &number, 1, nil)
	defer CFRelease(array)
	spaces := SLSCopySpacesForWindows(state.connection, 7, array)
	if spaces == nil {
		return 0
	}
	defer CFRelease(spaces)
	if CFArrayGetCount(spaces) == 0 {
		return 0
	}
	return number_value(CFArrayGetValueAtIndex(spaces, 0))
}

number_value :: number
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

refresh :: proc(state: ^State) {
	defer {if !state.read_only &&
		   state.manager.shadow_configured {if err := e.apply_window_shadows(&state.manager); err != "" {fmt.eprintln("shoji: shadow:", err)}}}
	pool := pool_push()
	defer pool_pop(pool)
	before := snapshot(state)
	refresh_displays(state)
	m := &state.manager
	apps := intrinsics.objc_send(^objc.Object, workspace(), "runningApplications")
	seen := make(map[u32]bool, context.temp_allocator)
	seen_apps := make(map[i32]bool, context.temp_allocator)
	for i in 0 ..< intrinsics.objc_send(uint, apps, "count") {
		running := intrinsics.objc_send(^objc.Object, apps, "objectAtIndex:", i)
		pid := intrinsics.objc_send(i32, running, "processIdentifier")
		if pid == getpid() {
			continue
		}
		policy := intrinsics.objc_send(int, running, "activationPolicy")
		if policy != 0 {
			continue
		}
		seen_apps[pid] = true
		app, exists := state.applications[pid]
		if !exists {
			app.element = AXUIElementCreateApplication(pid)
			AXUIElementSetMessagingTimeout(app.element, 0.25)
			app.name = strings.clone(
				objc_text(intrinsics.objc_send(^objc.Object, running, "localizedName")),
			)
			if AXObserverCreate(pid, observer_callback, &app.observer) == 0 {
				for name in ([]string {
						"AXWindowCreated",
						"AXFocusedWindowChanged",
						"AXApplicationActivated",
						"AXApplicationDeactivated",
						"AXApplicationHidden",
						"AXApplicationShown",
					}) {
					observe(state, app.observer, app.element, name)
				}
				CFRunLoopAddSource(
					CFRunLoopGetMain(),
					AXObserverGetRunLoopSource(app.observer),
					kCFRunLoopDefaultMode,
				)
			}
			state.applications[pid] = app
		}
		hidden := intrinsics.objc_send(bool, running, "isHidden")
		app.hidden = hidden
		state.applications[pid] = app
		list := attribute(app.element, "AXWindows")
		if list == nil {
			// A temporarily unresponsive application is not evidence its windows were destroyed.
			for id, w in m.windows {
				if w.pid == pid {
					seen[id] = true
				}
			}
			continue
		}
		for j in 0 ..< CFArrayGetCount(list) {
			element := CFArrayGetValueAtIndex(list, j)
			id: u32
			if _AXUIElementGetWindow(element, &id) != 0 || id == 0 {
				continue
			}
			seen[id] = true
			sid := window_space(state, id)
			s := e.space_by_id(m, sid)
			did: u32
			if s != nil {
				did = s.display
			}
			w := m.windows[id]
			title := attribute_text(element, "AXTitle")
			if w == nil {
				state.windows[id] = CFRetain(element)
				w = e.add_window(
					m,
					e.Window {
						id = id,
						pid = pid,
						app = app.name,
						title = title,
						role = attribute_text(element, "AXRole"),
						subrole = attribute_text(element, "AXSubrole"),
						frame = window_frame(element),
						space = sid,
						display = did,
						hidden = hidden,
						minimized = attribute_bool(element, "AXMinimized"),
						fullscreen = attribute_bool(element, "AXFullScreen"),
						opacity = 1,
						layer = "normal",
					},
				)
				if app.observer != nil {
					for name in ([]string {
							"AXUIElementDestroyed",
							"AXMoved",
							"AXResized",
							"AXTitleChanged",
							"AXWindowMiniaturized",
							"AXWindowDeminiaturized",
						}) {
						observe(state, app.observer, element, name)
					}
				}
			} else {
				was_managed := e.managed(w)
				old_space := w.space
				w.hidden = hidden
				w.minimized = attribute_bool(element, "AXMinimized")
				w.fullscreen = attribute_bool(element, "AXFullScreen")
				w.frame = window_frame(element)
				if w.title != title {
					delete(w.title)
					w.title = strings.clone(title)
				}
				if sid != 0 {
					w.space = sid
					w.display = did
				}
				if was_managed != e.managed(w) || old_space != w.space {
					if previous := e.space_by_id(m, old_space); previous != nil {
						e.remove(&previous.view, id)
					}
					if current := e.space_by_id(m, w.space); current != nil && e.managed(w) {
						e.add(&current.view, id, m.focused)
					}
				}
			}
			tags: u64
			if SLSGetWindowTags(state.connection, id, &tags, 64) == 0 {
				w.sticky = tags & (1 << 11) != 0;w.shadow = tags & (1 << 3) == 0
			}
			alpha: f32
			SLSGetWindowLevel(state.connection, id, &w.level)
			w.sub_level = SLSGetWindowSubLevel(state.connection, id)
			w.layer = w.sub_level < 0 ? "below" : (w.sub_level > 0 ? "above" : "normal")
			if w.scratchpad != "" {
				ordered: u8
				if SLSWindowIsOrderedIn(state.connection, id, &ordered) ==
				   0 {w.scratchpad_hidden = ordered == 0}
			}
			if SLSGetWindowAlpha(state.connection, id, &alpha) == 0 {w.opacity = f64(alpha)}
			position_key := cf_string("AXPosition");size_key := cf_string("AXSize")
			AXUIElementIsAttributeSettable(element, position_key, &w.can_move)
			AXUIElementIsAttributeSettable(element, size_key, &w.can_resize)
			CFRelease(position_key);CFRelease(size_key)
		}
		CFRelease(list)
	}
	gone := make([dynamic]u32, 0, 8, context.temp_allocator)
	for id in m.windows {
		if !seen[id] {
			append(&gone, id)
		}
	}
	for id in gone {
		CFRelease(state.windows[id])
		delete_key(&state.windows, id)
		e.remove_window(m, id)
	}
	terminated := make([dynamic]i32, 0, 8, context.temp_allocator)
	for pid in state.applications {
		if !seen_apps[pid] {
			append(&terminated, pid)
		}
	}
	for pid in terminated {
		app := state.applications[pid]
		if app.observer != nil {
			CFRunLoopRemoveSource(
				CFRunLoopGetMain(),
				AXObserverGetRunLoopSource(app.observer),
				kCFRunLoopDefaultMode,
			)
			CFRelease(app.observer)
		}
		CFRelease(app.element)
		delete(app.name)
		delete_key(&state.applications, pid)
	}
	front := intrinsics.objc_send(^objc.Object, workspace(), "frontmostApplication")
	pid := intrinsics.objc_send(i32, front, "processIdentifier")
	if app, ok := state.applications[pid]; ok {
		focused := attribute(app.element, "AXFocusedWindow")
		if focused != nil {
			id: u32
			_AXUIElementGetWindow(focused, &id)
			CFRelease(focused)
			e.focus_window(m, id)
		}
	}
	if !state.read_only && m.window_opacity {
		if err := e.apply_window_opacity(m); err != "" {fmt.eprintln("shoji: opacity:", err)}
	}
	if !state.read_only {
		if _, err := addition_check(); err == "" {
			if err := e.apply_window_layers(m); err != "" {fmt.eprintln("shoji: layer:", err)}
		}
		mouse_follow_focus(state)
	}
	emit_changes(state, before)
	state.dirty = false
}
