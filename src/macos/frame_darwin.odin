package macos

import e "../engine"
import "core:fmt"
import "core:math"
import "core:time"

Frame_Attributes :: struct {
	user: rawptr,
	enhanced: proc(user: rawptr, application: Ref) -> bool,
	set: proc(user: rawptr, element: Ref, name: string, value: Ref) -> i32,
}

native_frame_enhanced :: proc(_: rawptr, application: Ref) -> bool {
	return attribute_bool(application, "AXEnhancedUserInterface")
}
native_frame_set :: proc(
	_: rawptr,
	element: Ref,
	name: string,
	value: Ref,
) -> i32 {
	return set_attribute(element, name, value)
}

apply_accessibility_frame :: proc(
	application, element: Ref,
	frame: e.Rect,
	attributes := Frame_Attributes {
		nil,
		native_frame_enhanced,
		native_frame_set,
	},
	previous: Maybe(e.Rect) = nil,
	size_tolerance: f64 = 0,
) -> string {
	// Enhanced accessibility can cause applications to animate or clamp frame
	// writes. Restore the application's original setting on every return path.
	enhanced := attributes.enhanced(attributes.user, application)
	if enhanced {
		if code := attributes.set(
			attributes.user,
			application,
			"AXEnhancedUserInterface",
			kCFBooleanFalse,
		); code != 0 {
			return fmt.tprintf(
				"Accessibility could not suspend enhanced UI (%d)",
				code,
			)
		}
	}
	err := write_accessibility_frame(element, frame, attributes, previous, size_tolerance)
	if enhanced {
		if code := attributes.set(
			attributes.user,
			application,
			"AXEnhancedUserInterface",
			kCFBooleanTrue,
		); code != 0 {
			err = fmt.tprintf(
				"%sAccessibility could not restore enhanced UI (%d)",
				err == "" ? "" : fmt.tprintf("%s; ", err),
				code,
			)
		}
	}
	return err
}

write_accessibility_frame :: proc(
	element: Ref,
	frame: e.Rect,
	attributes: Frame_Attributes,
	previous: Maybe(e.Rect) = nil,
	size_tolerance: f64 = 0,
) -> string {
	p := Point{frame.x, frame.y}
	size := Size{frame.w, frame.h}
	position := AXValueCreate(1, &p)
	if position == nil {
		return "Accessibility could not allocate window position"
	}
	defer CFRelease(position)
	dimensions := AXValueCreate(2, &size)
	if dimensions == nil {
		return "Accessibility could not allocate window size"
	}
	defer CFRelease(dimensions)
	if old, known := previous.?; known {
		moved := old.x != frame.x || old.y != frame.y
		resized := old.w != frame.w || old.h != frame.h
		// A settled fractional layout size can differ slightly from native
		// readback. Scroll movement must not relayout content for that rounding.
		// Equality at the half-point boundary still requests a real resize.
		if size_tolerance > 0 {resized = math.abs(old.w-frame.w) >= size_tolerance || math.abs(old.h-frame.h) >= size_tolerance}
		// A pure resize needs one size write. Repeating the old position and
		// size can make applications lay out and repaint intermediate frames.
		if !moved {
			if !resized {
				return ""
			}
			if code := attributes.set(
				attributes.user,
				element,
				"AXSize",
				dimensions,
			); code != 0 {
				return fmt.tprintf(
					"Accessibility could not set window size (%d)",
					code,
				)
			}
			return ""
		}
		if !resized {
			if code := attributes.set(
				attributes.user,
				element,
				"AXPosition",
				position,
			); code != 0 {
				return fmt.tprintf(
					"Accessibility could not set window position (%d)",
					code,
				)
			}
			return ""
		}
	}
	// Some applications clamp a size change at the old position; repeat after moving.
	attributes.set(attributes.user, element, "AXSize", dimensions)
	a := attributes.set(attributes.user, element, "AXPosition", position)
	b := attributes.set(attributes.user, element, "AXSize", dimensions)
	if a != 0 || b != 0 {
		return fmt.tprintf(
			"Accessibility could not set window frame (%d, %d)",
			a,
			b,
		)
	}
	return ""
}
apply_frame_now :: proc(state: ^State, window: u32, frame: e.Rect) -> string {
	if state.read_only {
		return "window operations are disabled in read-only inspection"
	}
	w := state.manager.windows[window]
	if w == nil {
		return "window no longer exists"
	}
	if state.validation_pid != 0 && w.pid != state.validation_pid {
		return "window is outside the validation fixture"
	}
	element := state.windows[window]
	if element == nil {
		return "window no longer has an Accessibility reference"
	}
	app := state.applications[w.pid]
	observed: e.Rect; previous: Maybe(e.Rect)
	if SLSGetWindowBounds(state.connection, window, &observed) == 0 && observed.w > 0 && observed.h > 0 && !math.is_nan(observed.w) && !math.is_nan(observed.h) && !math.is_inf(observed.w) && !math.is_inf(observed.h) {
		previous = observed
	}
	scroll := false
	if s := e.space_by_id(&state.manager, w.space); s != nil {scroll = s.view.layout == .Scroll && e.managed(w)}
	effective := frame
	if scroll && previous != nil && e.size_feedback_duplicate(w, frame) {
		// Position updates remain live, but an outstanding identical size request
		// is not resent while its settled native result is still being observed.
		effective.w, effective.h = observed.w, observed.h
	}
	resize_cover_frame(state, window, frame, previous, CACurrentMediaTime())
	started: time.Tick
	if state.manager.motion_trace.active {started = time.tick_now()}
	if state.manager.motion_trace.active {
		e.motion_trace_record(&state.manager.motion_trace, {kind = "native-frame-begin", window = window, requested = frame, observed = observed, value = f64(int(w.opening.phase))})
	}
	if err := frame_updates_begin(state); err != "" {
		return err
	}
	err := apply_accessibility_frame(
		app.element,
		element,
		effective,
		previous = previous,
		size_tolerance = scroll ? .5 : 0,
	)
	present := frame_updates_end(state)
	if state.manager.motion_trace.active {
		actual: e.Rect
		code := SLSGetWindowBounds(state.connection, window, &actual)
		if err != "" || present != "" {code = -1}
		e.motion_trace_record(&state.manager.motion_trace, {kind = "native-frame", window = window, space = w.space, requested = frame, observed = actual, status = code, duration_ms = f64(time.tick_since(started)) / 1e6})
	}
	if err != "" {
		resize_cover_remove(state, window)
		w.size_feedback.pending = false
		return err
	}
	if present != "" {
		return present
	}
	if scroll && previous != nil {e.size_feedback_request(w, frame, observed, time.duration_seconds(time.diff(time.Time{}, time.now())))}
	state.dirty = true
	return ""
}
