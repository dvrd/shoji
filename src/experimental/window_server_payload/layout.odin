package payload

import "base:intrinsics"
import hook "../window_server"

layout_plan: hook.Layout_Plan
layout_generation: u32
layout_budget_us: u64
layout_complete: u32
layout_result: i32
layout_elapsed_us: u32
layout_applied: u32

// All pointers/bounds are validated before the first mutation. No allocation,
// external IPC or intentional waiting is permitted on this callback path.
apply_server_layout :: proc "contextless" (connection: rawptr) {
	started := mach_absolute_time()
	status := i32(0)
	windows: [hook.LAYOUT_LIMIT]rawptr
	before: [hook.LAYOUT_LIMIT]Placement_Rect
	applied := u32(0)
	if connection == nil {status = 8}
	for index in 0 ..< layout_plan.count {
		windows[index] = placement_lookup(layout_plan.items[index].wid)
		if windows[index] == nil {status = 8; break}
		before[index] = placement_bounds(windows[index])
		b := before[index]
		if !(b.w > 0 && b.h > 0 && b.x >= -1_000_000 && b.x <= 1_000_000 && b.y >= -1_000_000 && b.y <= 1_000_000) {status = 8; break}
	}
	if status == 0 {
		for index in 0 ..< layout_plan.count {
			item := layout_plan.items[index]
			placement_move(connection, windows[index], nil, f64(item.x) - before[index].x, f64(item.y) - before[index].y)
			applied += 1
		}
		for index in 0 ..< layout_plan.count {
			after := placement_bounds(windows[index])
			item := layout_plan.items[index]
			if after.x != f64(item.x) || after.y != f64(item.y) {status = 10}
		}
	}
	elapsed := (mach_absolute_time() - started) * u64(observer_timebase.numer) / u64(observer_timebase.denom) / 1000
	// Timing failure reports the overrun; it must not stop halfway through a
	// prevalidated layout. This is a measured budget, not a hard preemption.
	if status == 0 && elapsed > layout_budget_us {status = 11}
	layout_result = status
	layout_elapsed_us = u32(min(elapsed, u64(max(u32))))
	layout_applied = applied
	intrinsics.atomic_store_explicit(&layout_complete, 1, .Release)
}
