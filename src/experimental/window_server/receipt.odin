package experimental

// Ordering completion receipt (C2). One bounded watch slot: the controller
// arms a window id, and the first matching order-in call (op 1) in the
// forwarding callback records a receipt and forwards immediately — no sleep,
// unlike the hold. Reading a fired receipt consumes it. The generation binds
// the receipt to its arm, so stale or replayed reads are rejected.
//
// Gate status codes: 0 fired (consumed), 6 pending, 7 stale generation,
// 8 idle (nothing armed / already consumed).
import "base:intrinsics"

Receipt_State :: enum u32 {
	Idle,
	Armed,
	Fired,
}

Receipt_Slot :: struct {
	state:      u32, // Receipt_State
	target:     u64,
	generation: u32,
	result:     i32,
	ticks:      u64,
}

receipt_arm :: proc "contextless" (slot: ^Receipt_Slot, wid: u64) -> (generation: u32, ok: bool) {
	if intrinsics.atomic_load_explicit(&slot.state, .Acquire) == u32(Receipt_State.Armed) {
		return slot.generation, false
	}
	slot.target = wid
	slot.result = 0
	slot.ticks = 0
	generation = intrinsics.atomic_add_explicit(&slot.generation, 1, .Acq_Rel) + 1
	intrinsics.atomic_store_explicit(&slot.state, u32(Receipt_State.Armed), .Release)
	return generation, true
}

// Called from the forwarding callback after the original returns. Fires at
// most once per arm; returns true when this call produced the receipt.
receipt_fire :: proc "contextless" (slot: ^Receipt_Slot, wid: u64, result: i32, ticks: u64) -> bool {
	if intrinsics.atomic_load_explicit(&slot.state, .Acquire) != u32(Receipt_State.Armed) {return false}
	if wid != slot.target {return false}
	slot.result = result
	slot.ticks = ticks
	intrinsics.atomic_store_explicit(&slot.state, u32(Receipt_State.Fired), .Release)
	return true
}

receipt_cancel :: proc "contextless" (slot: ^Receipt_Slot) {
	intrinsics.atomic_store_explicit(&slot.state, u32(Receipt_State.Idle), .Release)
}

// Consume-once read: a fired receipt is returned exactly once, then the slot
// returns to Idle. A nonzero generation must match the armed generation.
receipt_take :: proc "contextless" (slot: ^Receipt_Slot, generation: u32) -> (status: i32, result: i32, ticks: u64) {
	state := intrinsics.atomic_load_explicit(&slot.state, .Acquire)
	if state == u32(Receipt_State.Idle) {return 8, 0, 0}
	if generation != 0 && generation != slot.generation {return 7, 0, 0}
	if state == u32(Receipt_State.Armed) {return 6, 0, 0}
	result = slot.result
	ticks = slot.ticks
	intrinsics.atomic_store_explicit(&slot.state, u32(Receipt_State.Idle), .Release)
	return 0, result, ticks
}
