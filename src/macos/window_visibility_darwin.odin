package macos

import e "../engine"

Window_Presence :: enum {
	Unknown,
	Present,
	Missing,
	Reused,
}
Window_Observation :: struct {
	presence:   Window_Presence,
	ordered_in: Maybe(bool),
}
Window_Probe :: struct {
	probe: proc(user: rawptr, state: ^State, window: ^e.Window) -> Window_Observation,
	user:  rawptr,
}
foreign import window_sls "system:SkyLight.framework"
foreign window_sls {
	SLSConnectionGetPID :: proc "c" (connection: i32, pid: ^i32) -> i32 ---
}
window_ordered_in :: proc(state: ^State, id: u32) -> Maybe(bool) {
	ordered: u8
	if SLSWindowIsOrderedIn(state.connection, id, &ordered) != 0 {return nil}
	return ordered != 0
}
native_window_probe :: proc(user: rawptr, state: ^State, window: ^e.Window) -> Window_Observation {
	id := window.id
	number := CFNumberCreate(nil, 3, &id);defer CFRelease(number)
	array := CFArrayCreate(nil, &number, 1, nil);defer CFRelease(array)
	query := SLSWindowQueryWindows(state.connection, array, 1)
	if query == nil {return {}}
	defer CFRelease(query)
	iterator := SLSWindowQueryResultCopyWindows(query)
	if iterator == nil {return {}}
	defer CFRelease(iterator)
	count := SLSWindowIteratorGetCount(iterator)
	if count == 0 {return {presence = .Missing}}
	if count != 1 || !SLSWindowIteratorAdvance(iterator) {return {}}
	owner, ok := animation_recovery_query_owner(state.connection, id)
	pid: i32
	if !ok || SLSConnectionGetPID(owner, &pid) != 0 {return {}}
	if pid != window.pid {return {presence = .Reused}}
	return {presence = .Present, ordered_in = window_ordered_in(state, id)}
}
retain_unlisted_windows :: proc(state: ^State, seen: ^map[u32]bool, seen_apps: map[i32]bool) {
	probe := state.window_probe.probe
	if probe == nil {probe = native_window_probe}
	for id, window in state.manager.windows {
		if seen[id] || !seen_apps[window.pid] || state.windows[id] == nil {continue}
		// Native inactive tabs can disappear from AXWindows without destruction.
		// A failed WindowServer query is inconclusive; retain the last observation.
		observation := probe(state.window_probe.user, state, window)
		if observation.presence == .Missing || observation.presence == .Reused {continue}
		seen[id] = true
		if app, exists := state.applications[window.pid]; exists {window.hidden = app.hidden}
		if observation.presence == .Present && observation.ordered_in != nil {
			window.ordered_in = observation.ordered_in
		}
	}
}
WINDOW_NOTIFICATIONS :: []string {
	"AXUIElementDestroyed",
	"AXMoved",
	"AXResized",
	"AXTitleChanged",
	"AXWindowMiniaturized",
	"AXWindowDeminiaturized",
}
window_reference_remove :: proc(state: ^State, id: u32, observer: Ref) {
	previous := state.windows[id]
	if previous == nil {return}
	if observer != nil {
		for name in WINDOW_NOTIFICATIONS {
			key := cf_string(name)
			AXObserverRemoveNotification(observer, previous, key)
			CFRelease(key)
		}
	}
	CFRelease(previous)
	delete_key(&state.windows, id)
}
window_reference_update :: proc(state: ^State, id: u32, element, observer: Ref) {
	previous := state.windows[id]
	if previous != nil && CFEqual(previous, element) {return}
	window_reference_remove(state, id, observer)
	state.windows[id] = CFRetain(element)
	if observer != nil {for name in WINDOW_NOTIFICATIONS {observe(state, observer, element, name)}}
}
