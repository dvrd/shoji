package macos

import e "../engine"

Display_Focus_Backend :: struct {
	windows:  proc(state: ^State) -> []u32,
	focus:    proc(state: ^State, window: u32) -> string,
	activate: proc(state: ^State, display: ^e.Display) -> string,
	warp:     proc(state: ^State, point: Point) -> string,
}

native_display_windows :: proc(state: ^State) -> []u32 {
	// WindowServer order chooses the frontmost visible window, independently of BSP order.
	list := CGWindowListCopyWindowInfo(1 | 16, 0)
	if list == nil {return nil}
	defer CFRelease(list)
	ids := make([dynamic]u32, context.temp_allocator)
	for i in 0 ..< CFArrayGetCount(list) {
		entry := CFArrayGetValueAtIndex(list, i)
		append(&ids, u32(number(dictionary(entry, "kCGWindowNumber"))))
	}
	return ids[:]
}

native_display_focus_window :: proc(state: ^State, window: u32) -> string {
	return perform(state, {kind = .Focus, window = window})
}

native_display_activate :: proc(state: ^State, display: ^e.Display) -> string {
	if display.uuid == "" {return "display has no UUID"}
	uuid := cf_string(display.uuid)
	defer CFRelease(uuid)
	if SLSSetActiveMenuBarDisplayIdentifier(state.connection, uuid, uuid) != 0 {
		return "could not activate display"
	}
	return ""
}

native_display_warp :: proc(state: ^State, point: Point) -> string {
	if CGWarpMouseCursorPosition(point) != 0 {return "could not move cursor to display"}
	return ""
}

focus_display :: proc(state: ^State, id: u32) -> string {
	if state.read_only {return "window operations are disabled in read-only inspection"}
	d := e.display_by_id(&state.manager, id)
	if d == nil {return "could not locate display"}
	backend := state.display_focus_backend
	if backend.windows == nil {
		backend = {
			native_display_windows,
			native_display_focus_window,
			native_display_activate,
			native_display_warp,
		}
	}
	window: u32
	for id in backend.windows(state) {
		w := state.manager.windows[id]
		if w != nil &&
		   (w.ordered_in.? or_else true) &&
		   w.display == d.id &&
		   (w.space == d.active_space || w.sticky) &&
		   !w.hidden &&
		   !w.minimized &&
		   !w.scratchpad_hidden {
			window = id
			break
		}
	}
	if window != 0 {
		if err := backend.focus(state, window); err != "" {return err}
	} else {
		if err := backend.warp(state, {d.frame.x + d.frame.w / 2, d.frame.y + d.frame.h / 2});
		   err != "" {return err}
	}
	if err := backend.activate(state, d); err != "" {return err}
	state.dirty = true
	return ""
}
