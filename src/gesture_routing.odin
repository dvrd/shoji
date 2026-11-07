package shoji

import "core:math"
import layout "layout"

// Gesture routing
// ------------------------------------------------------------------------

Scroll_Sample :: struct {
	x, y: f64,
	modifiers: u64,
	phase: u64,
	momentum: i64,
}
Scroll_Gesture :: struct {
	owned: bool,
	space: u64,
	last: f64,
	layout: layout.Layout,
	travel: f64,
	switched: bool,
}

// Latch the operation as well as the originating Space. Crossing to a scroll
// Space must not turn the tail of a BSP swipe into column movement.
layout_gesture_route :: proc(
	g: ^Scroll_Gesture,
	sample: Scroll_Sample,
	space: u64,
	layout: layout.Layout,
	modifier: u64,
	enabled: bool,
	now: f64,
) -> (
	bool,
	f64,
	int,
) {
	fresh :=
		g.space == 0 ||
		sample.phase & (1 | 128) != 0 ||
		now - g.last > 1 ||
		(sample.phase == 0 && sample.momentum == 0 && now - g.last > 0.25)
	if fresh {
		g.layout, g.travel, g.switched = layout, 0, false
	}
	consume, delta := scroll_gesture_route(
		g,
		sample,
		space,
		modifier,
		enabled,
		now,
	)
	if !consume {
		return false, 0, 0
	}
	if g.layout != .BSP {
		return true, delta, 0
	}
	if sample.momentum == 0 && sample.phase & 8 == 0 && !g.switched {
		g.travel += delta
		if math.abs(g.travel) >= 80 {
			g.switched = true
			return true, 0, g.travel > 0 ? 1 : -1
		}
	}
	return true, 0, 0
}

space_gesture_switch :: proc(
	m: ^Manager,
	origin: u64,
	direction: int,
) -> string {
	s := space_by_id(m, origin)
	if direction == 0 ||
	   s == nil ||
	   !s.visible ||
	   s.view.layout != .BSP ||
	   m.suspended ||
	   m.gesture_active {
		return ""
	}
	d := display_by_id(m, s.display)
	if d == nil || d.active_space != origin {
		return ""
	}
	// Native indices are ordered across displays. Filter by the originating
	// display for both adjacency and cyclic wraparound.
	target: ^Space
	wrapped: ^Space
	for candidate in m.spaces {
		if candidate.display != s.display {
			continue
		}
		if wrapped == nil ||
		   (direction > 0 \
					   ? candidate.index < wrapped.index \
					   : candidate.index > wrapped.index) {
			wrapped = candidate
		}
		if direction > 0 &&
		   candidate.index > s.index &&
		   (target == nil || candidate.index < target.index) {
			target = candidate
		}
		if direction < 0 &&
		   candidate.index < s.index &&
		   (target == nil || candidate.index > target.index) {
			target = candidate
		}
	}
	if target == nil {
		target = wrapped
	}
	if target == nil || target.id == origin {
		return ""
	}
	return perform(m, {kind = .Space_Focus, space = target.id})
}
// Physical scroll phase is a bitmask; CG momentum phase is a separate enum.
// Once captured, the tail stays with its original Space, even if the modifier
// is released. Unclaimed application momentum is never intercepted.
scroll_gesture_route :: proc(
	g: ^Scroll_Gesture,
	sample: Scroll_Sample,
	space, modifier: u64,
	enabled: bool,
	now: f64,
) -> (
	bool,
	f64,
) {
	if !enabled ||
	   math.is_nan(sample.x) ||
	   math.is_inf(sample.x) ||
	   math.is_nan(sample.y) ||
	   math.is_inf(sample.y) {
		g.owned = false; return false, 0
	}
	if now - g.last > 1 || sample.phase & (1 | 128) != 0 {
		g.owned = false
	}
	g.last = now
	if sample.momentum != 0 {
		owned := g.owned
		if sample.momentum == 3 {
			g.owned = false
		}
		return owned, owned ? -sample.x : 0
	}
	if sample.phase == 0 {
		g.owned = false
		if space != 0 &&
		   sample.modifiers == modifier &&
		   math.abs(sample.x) > math.abs(sample.y) {
			g.space = space; return true, -sample.x
		}
		return false, 0
	}
	if !g.owned &&
	   space != 0 &&
	   sample.modifiers == modifier &&
	   math.abs(sample.x) > math.abs(sample.y) {
		g.owned, g.space = true, space
	}
	owned := g.owned
	if sample.phase & 8 != 0 {
		g.owned = false
	}
	return owned, owned ? -sample.x : 0
}

scroll_gesture_pan :: proc(m: ^Manager, space: u64, delta: f64) -> string {
	s := space_by_id(m, space)
	if s == nil ||
	   !s.visible ||
	   s.view.layout != .Scroll ||
	   m.suspended ||
	   m.gesture_active {
		return ""
	}
	if math.is_nan(delta) || math.is_inf(delta) {
		return "invalid scroll delta"
	}
	layout.scroll_pan(&s.view, s.view.scroll.offset + delta)
	if m.scroll_animate {
		return flush(m, s)
	}
	// Input already carries the system's momentum curve. Applying another
	// window animation per sample would lag behind the pointer.
	duration := m.animation_duration
	m.animation_duration = 0
	defer m.animation_duration = duration
	return flush(m, s)
}
