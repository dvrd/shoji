package macos

import "core:fmt"
import "core:time"

motion_active :: proc(state: ^State) -> bool {
	if len(state.animations) > 0 ||
	   len(state.resize_covers) > 0 ||
	   state.mouse.scroll_tracking ||
	   state.mouse.drag.window != 0 {
		return true
	}
	for s in state.manager.spaces {
		if s.visible &&
		   s.view.layout == .Scroll &&
		   (s.view.scroll.motion.active || s.view.scroll.geometry_active) {
			return true
		}
	}
	return false
}

// One display pulse, one fixed sample time and one presentation batch for
// native geometry and its content covers. Nested AX/scroll batches stay inside
// this boundary; no overlay is presented ahead of its corresponding frame.
motion_frame_tick :: proc(
	state: ^State,
	ready: bool,
	sample_now: time.Time,
	uptime: f64,
) {
	if !ready {
		mouse_tick(state, false, sample_now)
		if !state.manager.resize_fade || state.resize_cover_cancel {
			resize_cover_tick(state, uptime)
		}
		return
	}
	active := motion_active(state)
	if active {
		if err := frame_updates_begin(state); err != "" {
			fmt.eprintln("shoji: motion:", err); return
		}
	}
	defer {
		if active {
			if err := frame_updates_end(state); err != "" {
				fmt.eprintln("shoji: motion:", err)
			}
		}
	}
	state.manager.scroll_time = time.duration_seconds(
		time.diff(time.Time{}, sample_now),
	)
	animation_tick(state, sample_now)
	mouse_tick(state, true, sample_now)
	scroll_native_tick(state, sample_now)
	resize_cover_tick(state, uptime)
}
