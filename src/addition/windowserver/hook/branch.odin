package wshook

// A direct AArch64 B preserves LR. The target is relative to the branch
// instruction itself, signed in units of four bytes, with a +/-128 MiB range.
encode_branch :: proc(source, destination: u64) -> (instruction: u32, ok: bool) {
	if source & 3 != 0 || destination & 3 != 0 {return}
	// Subtract only after checking the distance to avoid unsigned wraparound.
	if destination >= source {
		distance := destination - source
		if distance >= 0x08000000 {return}
		return 0x14000000 | u32(distance >> 2), true
	}
	distance := source - destination
	if distance > 0x08000000 {return}
	words := i64(distance >> 2)
	return 0x14000000 | (u32(-words) & 0x03ffffff), true
}

// This is the exact first instruction observed in the guest's 26A434
// ordering function, not a general-purpose instruction relocator.
PACIBSP :: u32(0xd503237f)

// Only the explicitly recovered entry instruction can be copied into a
// forwarding trampoline; unknown prologues fail closed.
supported_entry :: proc(instruction: u32) -> bool {
	return instruction == PACIBSP
}

Plan :: struct {
	entry_branch, displaced, resume_branch: u32,
}

// Pure planning only: it neither allocates nor modifies executable memory.
// The copied PACIBSP signs the trampoline caller's LR using the unchanged SP.
plan :: proc(entry, trampoline, replacement: u64, first_instruction: u32) -> (result: Plan, ok: bool) {
	if !supported_entry(first_instruction) || entry > max(u64) - 4 || trampoline > max(u64) - 4 {return}
	if trampoline == entry || replacement == entry || replacement == trampoline {return}
	entry_branch, entry_ok := encode_branch(entry, replacement)
	resume_branch, resume_ok := encode_branch(trampoline + 4, entry + 4)
	if !entry_ok || !resume_ok {return}
	return {entry_branch, first_instruction, resume_branch}, true
}
