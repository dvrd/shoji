package gate

import "base:intrinsics"

// One control thread arms/releases; callbacks claim concurrently. Generation
// and phase share one CAS word, so a delayed claimant cannot consume a re-arm.
// Released remains busy until the callback has forwarded the original call.
Hold_State :: enum u32 {Free, Armed, Claimed, Released}
HOLD_SCOPE_INLINE :: 1
HOLD_SCOPE_TABLE :: 2

Hold_Slot :: struct {
	state: u64,
	target: u64,
	scope, generation: u32,
}

hold_busy :: proc "contextless" (slot: ^Hold_Slot) -> (target: u64, generation: u32, busy: bool) {
	state := intrinsics.atomic_load_explicit(&slot.state, .Acquire)
	if Hold_State(u32(state)) == .Free {return}
	return intrinsics.atomic_load_explicit(&slot.target, .Acquire), u32(state >> 32), true
}

hold_arm :: proc "contextless" (slot: ^Hold_Slot, wid: u64, scope: u32) -> (generation: u32, ok: bool) {
	if _, _, busy := hold_busy(slot); busy {return slot.generation, false}
	slot.generation += 1
	if slot.generation == 0 {slot.generation = 1}
	intrinsics.atomic_store_explicit(&slot.target, wid, .Release)
	intrinsics.atomic_store_explicit(&slot.scope, scope & 3, .Release)
	intrinsics.atomic_store_explicit(&slot.state, u64(slot.generation) << 32 | u64(Hold_State.Armed), .Release)
	return slot.generation, true
}

// Generation zero releases unconditionally. Keep the epoch after cancellation
// so a concurrent claim from before cancellation fails its compare/exchange.
hold_release :: proc "contextless" (slot: ^Hold_Slot, generation: u32) -> (target: u64, status: i32) {
	for {
		state := intrinsics.atomic_load_explicit(&slot.state, .Acquire)
		phase := Hold_State(u32(state))
		if phase == .Free {return 0, 0}
		target = intrinsics.atomic_load_explicit(&slot.target, .Acquire)
		if generation != 0 && generation != u32(state >> 32) {return target, 7}
		if phase == .Released {return target, 0}
		next := Hold_State.Released
		if phase == .Armed {next = .Free}
		desired := state & 0xffffffff00000000 | u64(next)
		if _, ok := intrinsics.atomic_compare_exchange_strong_explicit(&slot.state, state, desired, .Acq_Rel, .Acquire); ok {return target, 0}
	}
}

hold_try_claim :: proc "contextless" (slot: ^Hold_Slot, wid: u64, inline: bool) -> bool {
	state := intrinsics.atomic_load_explicit(&slot.state, .Acquire)
	if Hold_State(u32(state)) != .Armed {return false}
	if wid != intrinsics.atomic_load_explicit(&slot.target, .Acquire) {return false}
	scope := intrinsics.atomic_load_explicit(&slot.scope, .Acquire)
	if inline && scope & HOLD_SCOPE_INLINE == 0 {return false}
	if !inline && scope & HOLD_SCOPE_TABLE == 0 {return false}
	desired := state & 0xffffffff00000000 | u64(Hold_State.Claimed)
	_, ok := intrinsics.atomic_compare_exchange_strong_explicit(&slot.state, state, desired, .Acq_Rel, .Acquire)
	return ok
}

hold_released :: proc "contextless" (slot: ^Hold_Slot, inline: bool) -> bool {
	state := intrinsics.atomic_load_explicit(&slot.state, .Acquire)
	return Hold_State(u32(state)) == .Released
}

hold_finish :: proc "contextless" (slot: ^Hold_Slot) {
	for {
		state := intrinsics.atomic_load_explicit(&slot.state, .Acquire)
		phase := Hold_State(u32(state))
		if phase != .Claimed && phase != .Released {return}
		desired := state & 0xffffffff00000000
		if _, ok := intrinsics.atomic_compare_exchange_strong_explicit(&slot.state, state, desired, .Acq_Rel, .Acquire); ok {return}
	}
}
