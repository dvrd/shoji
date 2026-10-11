package macos

import "base:intrinsics"
import "base:runtime"
import "core:sync"
import objc "core:sys/darwin/Foundation"
import "core:time"

foreign import notification_objc "system:objc"
@(default_calling_convention = "c")
foreign notification_objc {
	objc_getClass :: proc(name: cstring) -> rawptr ---
	objc_allocateClassPair :: proc(superclass: rawptr, name: cstring, extra: uint) -> rawptr ---
	objc_registerClassPair :: proc(class: rawptr) ---
	class_addMethod :: proc(class, selector, implementation: rawptr, encoding: cstring) -> bool ---
	sel_registerName :: proc(name: cstring) -> rawptr ---
}

Workspace_Event :: enum {
	Wake,
	Dock_Restart,
	Dock_Pref,
	Menu_Bar,
	Display,
	Refresh,
}
Workspace_Events :: bit_set[Workspace_Event]
Workspace_State :: struct {
	listener:                        ^objc.Object,
	centers:                         [3]^objc.Object,
	mutex:                           sync.Mutex,
	pending:                         Workspace_Events,
	dock_pid:                        i32,
	last_poll:                       time.Time,
	dock_element, dock_observer:     Ref,
	mission_active, desired_mission: bool,
}
workspace_listener_class: rawptr
workspace_listener_states: map[rawptr]^State
workspace_registry_mutex: sync.Mutex

workspace_notification :: proc "c" (object, selector, notification: ^objc.Object) {
	context = runtime.default_context()
	sync.mutex_lock(&workspace_registry_mutex)
	defer sync.mutex_unlock(&workspace_registry_mutex)
	state := workspace_listener_states[rawptr(object)]
	if state == nil {return}
	name := objc_text(intrinsics.objc_send(^objc.Object, notification, "name"))
	workspace_record(state, name)
}

workspace_record :: proc(state: ^State, name: string) {
	w := &state.workspace_events
	sync.mutex_lock(&w.mutex);defer sync.mutex_unlock(&w.mutex)
	switch name {
	case "NSWorkspaceDidWakeNotification":
		w.pending += {.Wake}
	case "NSApplicationDockDidRestartNotification":
		w.pending += {.Dock_Restart}
	case "com.apple.dock.prefchanged":
		w.pending += {.Dock_Pref}
	case "AppleInterfaceMenuBarHidingChangedNotification":
		w.pending += {.Menu_Bar}
	case "NSWorkspaceActiveDisplayDidChangeNotification":
		w.pending += {.Display}
	case "NSWorkspaceActiveSpaceDidChangeNotification",
	     "NSWorkspaceDidHideApplicationNotification",
	     "NSWorkspaceDidUnhideApplicationNotification":
		w.pending += {.Refresh}
	case "AXExposeShowAllWindows", "AXExposeShowFrontWindows", "AXExposeShowDesktop":
		w.desired_mission = true
	case "AXExposeExit":
		w.desired_mission = false
	case:
	}
}

workspace_start :: proc(state: ^State) -> bool {
	sync.mutex_lock(&workspace_registry_mutex)
	defer sync.mutex_unlock(&workspace_registry_mutex)
	if workspace_listener_class == nil {
		workspace_listener_class = objc_allocateClassPair(
			objc_getClass("NSObject"),
			"ShojiWorkspaceObserver",
			0,
		)
		if workspace_listener_class == nil {return false}
		if !class_addMethod(
			workspace_listener_class,
			sel_registerName("notification:"),
			rawptr(workspace_notification),
			"v@:@",
		) {return false}
		objc_registerClassPair(workspace_listener_class)
	}
	if workspace_listener_states == nil {workspace_listener_states = make(map[rawptr]^State)}
	w := &state.workspace_events
	w.listener = intrinsics.objc_send(
		^objc.Object,
		(^objc.Object)(workspace_listener_class),
		"new",
	)
	workspace_listener_states[rawptr(w.listener)] = state
	w.centers[0] = intrinsics.objc_send(^objc.Object, workspace(), "notificationCenter")
	w.centers[1] = intrinsics.objc_send(
		^objc.Object,
		(^objc.Object)(objc_getClass("NSNotificationCenter")),
		"defaultCenter",
	)
	w.centers[2] = intrinsics.objc_send(
		^objc.Object,
		(^objc.Object)(objc_getClass("NSDistributedNotificationCenter")),
		"defaultCenter",
	)
	names := [][]string {
		{
			"NSWorkspaceDidWakeNotification",
			"NSWorkspaceActiveDisplayDidChangeNotification",
			"NSWorkspaceActiveSpaceDidChangeNotification",
			"NSWorkspaceDidHideApplicationNotification",
			"NSWorkspaceDidUnhideApplicationNotification",
		},
		{"NSApplicationDockDidRestartNotification"},
		{"com.apple.dock.prefchanged", "AppleInterfaceMenuBarHidingChangedNotification"},
	}
	for group, i in names {
		for name in group {
			value := cf_string(name)
			intrinsics.objc_send(
				nil,
				w.centers[i],
				"addObserver:selector:name:object:",
				w.listener,
				sel_registerName("notification:"),
				(^objc.Object)(value),
				(^objc.Object)(nil),
			)
			CFRelease(value)
		}
	}
	return true
}

workspace_unobserve_dock :: proc(state: ^State) {
	w := &state.workspace_events
	if w.dock_observer != nil {
		CFRunLoopRemoveSource(
			CFRunLoopGetMain(),
			AXObserverGetRunLoopSource(w.dock_observer),
			kCFRunLoopDefaultMode,
		)
		CFRelease(w.dock_observer);w.dock_observer = nil
	}
	if w.dock_element != nil {CFRelease(w.dock_element);w.dock_element = nil}
}

workspace_stop :: proc(state: ^State) {
	w := &state.workspace_events
	workspace_unobserve_dock(state)
	if w.listener != nil {
		for center in w.centers {intrinsics.objc_send(nil, center, "removeObserver:", w.listener)}
		sync.mutex_lock(&workspace_registry_mutex)
		delete_key(&workspace_listener_states, rawptr(w.listener))
		if len(workspace_listener_states) ==
		   0 {delete(workspace_listener_states);workspace_listener_states = nil}
		sync.mutex_unlock(&workspace_registry_mutex)
		intrinsics.objc_send(nil, w.listener, "release")
		w.listener = nil
	}
}

mission_callback :: proc "c" (observer, element, notification: Ref, user: rawptr) {
	context = runtime.default_context()
	workspace_record((^State)(user), text(notification))
}

workspace_tick :: proc(state: ^State, detect_dock: bool = true) {
	w := &state.workspace_events
	now := time.now()
	if detect_dock && (w.last_poll == time.Time{} || time.diff(w.last_poll, now) >= time.Second) {
		w.last_poll = now
		identifier := cf_string("com.apple.dock")
		apps := intrinsics.objc_send(
			^objc.Object,
			Running_Application,
			"runningApplicationsWithBundleIdentifier:",
			(^objc.Object)(identifier),
		)
		CFRelease(identifier)
		pid: i32
		if intrinsics.objc_send(uint, apps, "count") == 1 {
			app := intrinsics.objc_send(^objc.Object, apps, "objectAtIndex:", uint(0))
			pid = intrinsics.objc_send(i32, app, "processIdentifier")
		}
		if pid != w.dock_pid {
			workspace_unobserve_dock(state)
			if w.dock_pid != 0 &&
			   pid != 0 {workspace_record(state, "NSApplicationDockDidRestartNotification")}
			w.dock_pid = pid
			workspace_record(state, "AXExposeExit")
		}
		if pid != 0 && w.dock_observer == nil {
			w.dock_element = AXUIElementCreateApplication(pid)
			if AXObserverCreate(pid, mission_callback, &w.dock_observer) == 0 {
				for name in ([]string {
						"AXExposeShowAllWindows",
						"AXExposeShowFrontWindows",
						"AXExposeShowDesktop",
						"AXExposeExit",
					}) {observe(state, w.dock_observer, w.dock_element, name)}
				CFRunLoopAddSource(
					CFRunLoopGetMain(),
					AXObserverGetRunLoopSource(w.dock_observer),
					kCFRunLoopDefaultMode,
				)
			} else {CFRelease(w.dock_element);w.dock_element = nil}
		}
	}
	sync.mutex_lock(&w.mutex)
	pending, mission := w.pending, w.desired_mission
	w.pending = {}
	sync.mutex_unlock(&w.mutex)
	if mission != w.mission_active {
		w.mission_active = mission
		state.manager.suspended = mission
		state.dirty = true
		emit(state, Event{name = mission ? "mission_control_enter" : "mission_control_exit"})
	}
	names := [Workspace_Event]string {
		.Wake         = "system_woke",
		.Dock_Restart = "dock_did_restart",
		.Dock_Pref    = "dock_did_change_pref",
		.Menu_Bar     = "menu_bar_hidden_changed",
		.Display      = "display_changed",
		.Refresh      = "",
	}
	for event in pending {
		state.dirty = true
		if event != .Refresh {emit(state, Event{name = names[event]})}
	}
}
