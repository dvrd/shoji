package main

// Exact 26A434 server helpers. Called only from the ordering callback, on
// its serialized server thread and with that callback's connection context.
// Never call these from the independent IPC/control thread.
import "base:intrinsics"
import hook "../../../src/experimental/window_server"

Placement_Rect :: struct {x, y, w, h: f64}
Placement_Lookup :: proc "c" (wid: u32) -> rawptr
Placement_Bounds :: proc "c" (window: rawptr) -> Placement_Rect
Placement_Move :: proc "c" (connection, window, options: rawptr, dx, dy: f64)

placement_lookup: Placement_Lookup
placement_bounds: Placement_Bounds
placement_move: Placement_Move
placement_generation: u32
placement_x, placement_y: i32
placement_complete: u32
placement_result: i32
placement_actual: u64
// SpacePlace arms restrict their claim to the space ops; ordinary table ops
// (e.g. 0x03 churn) must not consume them before the move arrives.
placement_space_only: u32
SPACE_OP_MIN, SPACE_OP_MAX :: 0x18, 0x19
// SpaceApply: apply on claim and forward immediately (held=3), no Release wait.
placement_auto: u32

verify_placement_helpers :: proc(slide: u64) -> bool {
	addresses := [3]u64{0x1873e91c8, 0x18732e534, 0x187333594}
	expected := [3][4]u32{
		{0x34000160, 0x902e8d48, 0xf942d508, 0xb4000108},
		{0xf02c7408, 0xf944c908, 0x6d400500, 0x6d410d02},
		{0xd503237f, 0xd10203ff, 0x6d0323e9, 0xa9045ff8},
	}
	for address, index in addresses {
		words := ([^]u32)(uintptr(address + slide))
		for word in 0 ..< 4 {if words[word] != expected[index][word] {return false}}
	}
	// Odin's indirect calls emit BLR and require raw addresses. Sign only
	// pointers handed to native C code which authenticates them with BLRAA.
	placement_lookup = transmute(Placement_Lookup)uintptr(addresses[0] + slide)
	placement_bounds = transmute(Placement_Bounds)uintptr(addresses[1] + slide)
	placement_move = transmute(Placement_Move)uintptr(addresses[2] + slide)
	return true
}

finish_placement :: proc "contextless" (status: i32, actual: u64) {
	placement_result = status
	placement_actual = actual
	intrinsics.atomic_store_explicit(&placement_complete, 1, .Release)
}

apply_server_placement :: proc "contextless" (connection: rawptr, wid: u32) {
	window := placement_lookup(wid)
	if window == nil || connection == nil {finish_placement(8, 0); return}
	before := placement_bounds(window)
	if !(before.w > 0 && before.h > 0) {finish_placement(8, 0); return}
	placement_move(connection, window, nil, f64(placement_x) - before.x, f64(placement_y) - before.y)
	after := placement_bounds(window)
	if !(after.x >= -1_000_000 && after.x <= 1_000_000 && after.y >= -1_000_000 && after.y <= 1_000_000) {finish_placement(10, 0); return}
	status := i32(10)
	if after.x == f64(placement_x) && after.y == f64(placement_y) {status = 0}
	finish_placement(status, hook.placement_pack(i32(after.x), i32(after.y)))
}
