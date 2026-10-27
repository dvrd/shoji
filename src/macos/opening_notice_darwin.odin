package macos

import e "../engine"
import "base:intrinsics"
import objc "core:sys/darwin/Foundation"

// A space-blocked newcomer remains managed. The notice explains why no new
// tile has appeared, without changing another window's position or focus.
opening_notice_tick :: proc(state: ^State) {
	blocked: ^e.Space
	for _, w in state.manager.windows {
		if w.opening.phase == .Pending && w.opening.wait == .Space {
			if s := e.space_by_id(&state.manager, w.space); s != nil && s.visible {blocked = s;break}
		}
	}
	if blocked == nil {
		if state.opening_notice.id != 0 {surface_destroy(state, state.opening_notice);state.opening_notice = {}}
		return
	}
	if state.connection == 0 {return}
	frame := e.Rect{blocked.view.frame.x + max(0, blocked.view.frame.w - 330), blocked.view.frame.y + 12, 316, 48}
	if state.opening_notice.id != 0 {
		if state.opening_notice.frame != frame && surface_update(state, state.opening_notice, frame) == "" {state.opening_notice.frame = frame}
		return
	}
	surface, err := surface_create(state, frame, 0, (1 << 1) | (1 << 3) | (1 << 9), 13, 1)
	if err != "" {return}
	CGContextSetRGBFillColor(surface.ctx, .98, .95, .86, 1)
	CGContextFillRect(surface.ctx, {0, 0, 316, 48})
	graphics := (^objc.Object)(objc.objc_lookUpClass("NSGraphicsContext"))
	native := intrinsics.objc_send(^objc.Object, graphics, "graphicsContextWithCGContext:flipped:", surface.ctx, bool(false))
	intrinsics.objc_send(nil, graphics, "saveGraphicsState")
	intrinsics.objc_send(nil, graphics, "setCurrentContext:", native)
	label := cf_string("Needs more room for a new window")
	intrinsics.objc_send(nil, (^objc.Object)(label), "drawInRect:withAttributes:", e.Rect{12, 12, 292, 24}, (^objc.Object)(nil))
	CFRelease(label)
	intrinsics.objc_send(nil, graphics, "restoreGraphicsState")
	CGContextFlush(surface.ctx)
	if surface_update(state, surface, frame) != "" || SLSSetWindowLevel(state.connection, surface.id, 20) != 0 || SLSOrderWindow(state.connection, surface.id, 1, 0) != 0 {
		surface_destroy(state, surface);return
	}
	state.opening_notice = surface
}
