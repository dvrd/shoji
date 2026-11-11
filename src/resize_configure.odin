package shoji

import "core:fmt"
import "core:sync"
import "core:thread"

// Keyboard resize configure
// ------------------------------------------------------------------------
//
// A scaled keyboard resize sends the app its final size while Shoji scales
// the current buffer each frame. The Accessibility write blocks until the app
// has laid out (5-100 ms), which froze the animation on every key repeat. It
// runs here instead, off the main loop. Only the size is written: moving the
// window would shift the presentation transform WindowServer holds for it.
// A hidden tab has no transform, so its slot may carry a position as well.
// A held key keeps the latest size per window; older ones are dropped.

RESIZE_CONFIGURE_SLOTS :: 8

Resize_Configure_Slot :: struct {
	window:  u32,
	element: Ref, // retained while queued
	size:    Size,
	origin:  Maybe(Point),
}

Resize_Configure_Queue :: struct {
	mutex:   sync.Mutex,
	wake:    sync.Sema,
	slots:   [RESIZE_CONFIGURE_SLOTS]Resize_Configure_Slot,
	count:   int,
	key:     Ref, // "AXSize", created on the main thread
	origin_key: Ref, // "AXPosition"
	worker:  ^thread.Thread,
	failed:  bool,
}

resize_configure_queue: Resize_Configure_Queue

// Main thread. A window already queued gets the newer size.
resize_configure_push :: proc(window: u32, element: Ref, size: Size, origin: Maybe(Point) = nil) -> string {
	q := &resize_configure_queue
	if q.worker == nil {
		q.key = cf_string("AXSize")
		q.origin_key = cf_string("AXPosition")
		q.worker = thread.create_and_start(resize_configure_worker)
		if q.worker == nil {
			return "could not start the resize writer"
		}
	}
	sync.mutex_lock(&q.mutex)
	defer sync.mutex_unlock(&q.mutex)
	for i in 0 ..< q.count {
		if q.slots[i].window == window {
			q.slots[i].size, q.slots[i].origin = size, origin
			return ""
		}
	}
	if q.count == RESIZE_CONFIGURE_SLOTS {
		return "resize writer is full"
	}
	q.slots[q.count] = {window, CFRetain(element), size, origin}
	q.count += 1
	sync.sema_post(&q.wake)
	return ""
}

resize_configure_worker :: proc() {
	q := &resize_configure_queue
	for {
		sync.sema_wait(&q.wake)
		for {
			sync.mutex_lock(&q.mutex)
			if q.count == 0 {
				sync.mutex_unlock(&q.mutex)
				break
			}
			slot := q.slots[0]
			q.count -= 1
			copy(q.slots[:q.count], q.slots[1:q.count + 1])
			sync.mutex_unlock(&q.mutex)
			code: i32 = -1
			if origin, moved := slot.origin.?; moved {
				if position := AXValueCreate(1, &origin); position != nil {
					_ = AXUIElementSetAttributeValue(slot.element, q.origin_key, position)
					CFRelease(position)
				}
			}
			size := slot.size
			value := AXValueCreate(2, &size)
			if value != nil {
				code = AXUIElementSetAttributeValue(slot.element, q.key, value)
				CFRelease(value)
			}
			CFRelease(slot.element)
			if code != 0 && !q.failed {
				q.failed = true
				fmt.eprintf("shoji: resize writer: window %d size write failed (%d)\n", slot.window, code)
			}
		}
	}
}

// Manager hook: snapshot for the cross-fade first (old content, main
// thread), then hand the size write to the worker.
resize_configure :: proc(user: rawptr, window: u32, request: Rect) -> string {
	state := (^State)(user)
	w := state.manager.windows[window]
	element := state.windows[window]
	if w == nil || element == nil {
		return "window no longer has an Accessibility reference"
	}
	observed: Rect
	previous: Maybe(Rect)
	if SLSGetWindowBounds(state.connection, window, &observed) == 0 && observed.w > 0 && observed.h > 0 {
		previous = observed
	}
	resize_cover_frame(state, window, request, previous, CACurrentMediaTime())
	return resize_configure_push(window, element, {request.w, request.h})
}

// Manager hook for a hidden tab: no snapshot, position and size off the loop.
resize_configure_hidden :: proc(user: rawptr, window: u32, request: Rect) -> string {
	state := (^State)(user)
	element := state.windows[window]
	if state.manager.windows[window] == nil || element == nil {
		return "window no longer has an Accessibility reference"
	}
	return resize_configure_push(window, element, {request.w, request.h}, Point{request.x, request.y})
}
