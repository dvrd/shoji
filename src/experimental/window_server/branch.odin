package experimental

import mach "core:sys/darwin"

foreign import system "system:System"

@(default_calling_convention = "c")
foreign system {
	@(link_name = "mach_task_self")
	hook_mach_task_self :: proc() -> u32 ---
	@(link_name = "mach_vm_remap")
	hook_mach_vm_remap :: proc(target: u32, address: ^u64, size, mask: u64, flags: i32, source: u32, source_address: u64, copy: i32, current, maximum: ^i32, inheritance: i32) -> i32 ---
	@(link_name = "mach_vm_protect")
	hook_mach_vm_protect :: proc(task: u32, address, size: u64, maximum, protection: i32) -> i32 ---
	@(link_name = "sys_icache_invalidate")
	hook_sys_icache_invalidate :: proc(address: rawptr, size: uint) ---
}

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

// Find an aligned candidate on either side of a replacement without wrapping.
// The whole region stays conservatively within the direct-branch span.
nearby_region_base :: proc(replacement_page, distance, region_size, page_size: u64, below: bool) -> (candidate: u64, ok: bool) {
	if page_size == 0 || page_size & (page_size - 1) != 0 ||
	   replacement_page & (page_size - 1) != 0 ||
	   distance == 0 || distance & (page_size - 1) != 0 ||
	   region_size == 0 || region_size & (page_size - 1) != 0 ||
	   region_size >= 0x08000000 || distance > 0x08000000 - region_size {return}
	if below {
		if distance > replacement_page {return}
		return replacement_page - distance, true
	}
	if replacement_page > max(u64) - distance {return}
	return replacement_page + distance, true
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

Deallocate :: proc "c" (task: u32, address, size: u64) -> i32

INLINE_PATCH_BYTES :: 16
INLINE_LDR_X16_LITERAL :: u32(0x58000050)
INLINE_BR_X16 :: u32(0xd61f0200)
INLINE_LOOP :: u32(0x14000000)

Inline_Plan :: struct {
	entry_jump: [4]u32,
	displaced: [4]u32,
	resume_jump: [4]u32,
}

// An inline absolute jump needs no nearby allocation or code cave. The first
// four target instructions must be the exact validated prologue; they execute
// at the start of the trampoline with the unchanged stack.
plan_inline :: proc(entry, trampoline, replacement: u64, displaced: [4]u32) -> (result: Inline_Plan, ok: bool) {
	if entry & 3 != 0 || trampoline & 3 != 0 || replacement & 3 != 0 ||
	   entry > max(u64) - INLINE_PATCH_BYTES ||
	   trampoline == entry || replacement == entry || replacement == trampoline {return}
	jump :: proc(destination: u64) -> [4]u32 {
		return {INLINE_LDR_X16_LITERAL, INLINE_BR_X16, u32(destination), u32(destination >> 32)}
	}
	return {jump(replacement), displaced, jump(entry + INLINE_PATCH_BYTES)}, true
}

Inline_State :: struct {
	installed: bool,
	entry, target_page, alias_page, page_size: u64,
	original_words, jump_words: [4]u32,
	task: u32,
	deallocate: Deallocate,
}

inline_restore_decision :: proc(alias_words, entry_words, original_words, jump_words: [4]u32) -> Restore_Decision {
	alias_original, entry_original, alias_jump, entry_jump := true, true, true, true
	for index in 0 ..< 4 {
		alias_original &= alias_words[index] == original_words[index]
		entry_original &= entry_words[index] == original_words[index]
		alias_jump &= alias_words[index] == jump_words[index]
		entry_jump &= entry_words[index] == jump_words[index]
	}
	if alias_original && entry_original {return .Restored}
	if alias_jump && entry_jump {return .Write}
	return .Conflict
}

teardown_inline_quiescent :: proc(state: ^Inline_State) -> bool {
	if state == nil {return false}
	if state.alias_page == 0 {return !state.installed}
	if state.deallocate == nil {return false}
	if state.installed {
		alias := ([^]u32)(uintptr(state.alias_page + state.entry - state.target_page))
		entry := ([^]u32)(uintptr(state.entry))
		alias_words, entry_words: [4]u32
		for index in 0 ..< 4 {alias_words[index], entry_words[index] = alias[index], entry[index]}
		switch inline_restore_decision(alias_words, entry_words, state.original_words, state.jump_words) {
		case .Restored:
			state.installed = false
		case .Write:
			for index in 0 ..< 4 {alias[index] = state.original_words[index]}
			hook_sys_icache_invalidate(rawptr(uintptr(state.entry)), INLINE_PATCH_BYTES)
			for index in 0 ..< 4 {if entry[index] != state.original_words[index] {return false}}
			state.installed = false
		case .Conflict:
			return false
		}
	}
	if state.deallocate(state.task, state.alias_page, state.page_size) != 0 {return false}
	state^ = {}
	return true
}

// Park future callers at the entry while callers already past word zero finish
// the original prologue. The caller must hold an execution barrier and later
// resume before installing the complete inline jump.
write_inline_loop_via_alias :: proc(entry: u64, expected: [4]u32, deallocate: Deallocate) -> bool {
	if deallocate == nil || entry & 3 != 0 {return false}
	page_size := mach.vm_page_size
	if page_size == 0 || page_size & (page_size - 1) != 0 {return false}
	page := entry & ~(page_size - 1)
	entry_words := ([^]u32)(uintptr(entry))
	for index in 0 ..< 4 {if entry_words[index] != expected[index] {return false}}
	alias: u64
	current, maximum: i32
	task := hook_mach_task_self()
	if hook_mach_vm_remap(task, &alias, page_size, 0, 1, task, page, 0, &current, &maximum, 1) != 0 {return false}
	owned := true
	defer {
		if owned {deallocate(task, alias, page_size)}
	}
	if hook_mach_vm_protect(task, alias, page_size, 0, 1 | 2) != 0 {return false}
	patch := ([^]u32)(uintptr(alias + (entry - page)))
	for index in 0 ..< 4 {
		if patch[index] != expected[index] || entry_words[index] != expected[index] {return false}
	}
	patch[0] = INLINE_LOOP
	hook_sys_icache_invalidate(rawptr(uintptr(entry)), 4)
	if entry_words[0] != INLINE_LOOP {return false}
	if deallocate(task, alias, page_size) != 0 {return false}
	owned = false
	return true
}

restore_inline_loop_via_alias :: proc(entry: u64, expected: [4]u32, deallocate: Deallocate) -> bool {
	if deallocate == nil || entry & 3 != 0 {return false}
	page_size := mach.vm_page_size
	if page_size == 0 || page_size & (page_size - 1) != 0 {return false}
	entry_words := ([^]u32)(uintptr(entry))
	if entry_words[0] != INLINE_LOOP {return false}
	for index in 1 ..< 4 {if entry_words[index] != expected[index] {return false}}
	page := entry & ~(page_size - 1)
	alias: u64
	current, maximum: i32
	task := hook_mach_task_self()
	if hook_mach_vm_remap(task, &alias, page_size, 0, 1, task, page, 0, &current, &maximum, 1) != 0 {return false}
	owned := true
	defer {if owned {deallocate(task, alias, page_size)}}
	if hook_mach_vm_protect(task, alias, page_size, 0, 1 | 2) != 0 {return false}
	patch := ([^]u32)(uintptr(alias + (entry - page)))
	if patch[0] != INLINE_LOOP {return false}
	for index in 1 ..< 4 {if patch[index] != expected[index] {return false}}
	patch[0] = expected[0]
	hook_sys_icache_invalidate(rawptr(uintptr(entry)), 4)
	if entry_words[0] != expected[0] {return false}
	if deallocate(task, alias, page_size) != 0 {return false}
	owned = false
	return true
}

install_inline_after_loop :: proc(state: ^Inline_State, entry, replacement: u64, expected: [4]u32, deallocate: Deallocate) -> bool {
	if state == nil || state.installed || state.alias_page != 0 || deallocate == nil {return false}
	page_size := mach.vm_page_size
	if page_size == 0 || page_size & (page_size - 1) != 0 || entry & 3 != 0 || replacement & 3 != 0 ||
	   entry == replacement {return false}
	entry_words := ([^]u32)(uintptr(entry))
	if entry_words[0] != INLINE_LOOP {return false}
	for index in 1 ..< 4 {if entry_words[index] != expected[index] {return false}}
	plan, ok := plan_inline(entry, 0, replacement, expected)
	if !ok {return false}
	page := entry & ~(page_size - 1)
	alias: u64
	current, maximum: i32
	task := hook_mach_task_self()
	if hook_mach_vm_remap(task, &alias, page_size, 0, 1, task, page, 0, &current, &maximum, 1) != 0 {return false}
	state^ = {entry = entry, target_page = page, alias_page = alias, page_size = page_size,
		original_words = expected, jump_words = plan.entry_jump, task = task, deallocate = deallocate}
	if hook_mach_vm_protect(task, alias, page_size, 0, 1 | 2) != 0 {
		teardown_inline_quiescent(state)
		return false
	}
	patch := ([^]u32)(uintptr(alias + (entry - page)))
	if patch[0] != INLINE_LOOP {return false}
	for index in 1 ..< 4 {
		if patch[index] != expected[index] || entry_words[index] != expected[index] {
			teardown_inline_quiescent(state)
			return false
		}
	}
	for index in 0 ..< 4 {patch[index] = plan.entry_jump[index]}
	state.installed = true
	hook_sys_icache_invalidate(rawptr(uintptr(entry)), INLINE_PATCH_BYTES)
	for index in 0 ..< 4 {if entry_words[index] != plan.entry_jump[index] {return false}}
	return true
}

install_inline_via_alias :: proc(state: ^Inline_State, entry, replacement: u64, expected: [4]u32, deallocate: Deallocate) -> bool {
	if state == nil || state.installed || state.alias_page != 0 || deallocate == nil {return false}
	page_size := mach.vm_page_size
	if page_size == 0 || page_size & (page_size - 1) != 0 || entry & 3 != 0 || replacement & 3 != 0 ||
	   entry == replacement {return false}
	plan, ok := plan_inline(entry, 0, replacement, expected)
	if !ok {return false}
	page := entry & ~(page_size - 1)
	entry_words := ([^]u32)(uintptr(entry))
	for index in 0 ..< 4 {if entry_words[index] != expected[index] {return false}}
	alias: u64
	current, maximum: i32
	task := hook_mach_task_self()
	if hook_mach_vm_remap(task, &alias, page_size, 0, 1, task, page, 0, &current, &maximum, 1) != 0 {return false}
	state^ = {entry = entry, target_page = page, alias_page = alias, page_size = page_size,
		original_words = expected, jump_words = plan.entry_jump, task = task, deallocate = deallocate}
	if hook_mach_vm_protect(task, alias, page_size, 0, 1 | 2) != 0 {
		teardown_inline_quiescent(state)
		return false
	}
	patch := ([^]u32)(uintptr(alias + (entry - page)))
	for index in 0 ..< 4 {
		if patch[index] != expected[index] || entry_words[index] != expected[index] {
			teardown_inline_quiescent(state)
			return false
		}
	}
	for index in 0 ..< 4 {patch[index] = plan.entry_jump[index]}
	state.installed = true
	hook_sys_icache_invalidate(rawptr(uintptr(entry)), INLINE_PATCH_BYTES)
	for index in 0 ..< 4 {if entry_words[index] != plan.entry_jump[index] {return false}}
	return true
}

// Non-copyable ownership by convention. Installation/teardown must be serialized.
// The caller owns executable target/relay/trampoline memory separately and must
// retain it until all users have stopped and in-flight calls have drained.
Hook_State :: struct {
	installed: bool,
	entry, target_page, alias_page, page_size: u64,
	original_word, branch_word: u32,
	task: u32,
	deallocate: Deallocate,
}

Restore_Decision :: enum {
	Conflict,
	Write,
	Restored,
}

// Do not require a second branch after a successful restore whose read-back
// verification failed. Partial or unexpected words remain conflicts.
restore_decision :: proc(alias_word, entry_word, original_word, branch_word: u32) -> Restore_Decision {
	if alias_word == original_word && entry_word == original_word {return .Restored}
	if alias_word == branch_word && entry_word == branch_word {return .Write}
	return .Conflict
}

// Restore/release only with an externally established quiescence barrier. This
// function does not create that barrier; it is NOT safe for live unhooking.
teardown_quiescent :: proc(state: ^Hook_State) -> bool {
	if state == nil {return false}
	if state.alias_page == 0 {return !state.installed}
	if state.deallocate == nil {return false}
	if state.installed {
		patch := (^u32)(uintptr(state.alias_page + state.entry - state.target_page))
		switch restore_decision(patch^, (^u32)(uintptr(state.entry))^, state.original_word, state.branch_word) {
		case .Restored:
			state.installed = false
		case .Write:
			patch^ = state.original_word
			hook_sys_icache_invalidate(rawptr(uintptr(state.entry)), 4)
			if (^u32)(uintptr(state.entry))^ != state.original_word {return false}
			state.installed = false
		case .Conflict:
			return false
		}
	}
	// Preserve ownership on failure so callers can retry without another remap.
	if state.deallocate(state.task, state.alias_page, state.page_size) != 0 {return false}
	state^ = {}
	return true
}

// Install one verified entry branch through a writable alias. The original
// executable mapping remains executable. Callers must serialize code writers;
// this experiment does not establish concurrent instruction-fetch safety.
// Supply the correctly typed, raw Mach deallocator resolved by the caller,
// avoiding the incompatible declaration in the current Odin SDK.
install_entry_via_alias :: proc(state: ^Hook_State, entry, replacement: u64, expected: u32, deallocate: Deallocate) -> bool {
	if state == nil || state.installed || state.alias_page != 0 || deallocate == nil {return false}
	page_size := mach.vm_page_size
	if page_size == 0 || page_size & (page_size - 1) != 0 {return false}
	if entry == 0 || entry & 3 != 0 || entry == replacement || !supported_entry(expected) {return false}
	if (^u32)(uintptr(entry))^ != expected {return false}
	branch, ok := encode_branch(entry, replacement)
	if !ok {return false}
	page := entry & ~(page_size - 1)
	alias: u64
	current, maximum: i32
	task := hook_mach_task_self()
	if hook_mach_vm_remap(task, &alias, page_size, 0, 1, task, page, 0, &current, &maximum, 1) != 0 {
		return false
	}
	state^ = {entry = entry, target_page = page, alias_page = alias, page_size = page_size,
		original_word = expected, branch_word = branch, task = task, deallocate = deallocate}
	if hook_mach_vm_protect(task, alias, page_size, 0, 1 | 2) != 0 {
		teardown_quiescent(state)
		return false
	}
	patch := (^u32)(uintptr(alias + (entry - page)))
	if patch^ != expected || (^u32)(uintptr(entry))^ != expected {
		teardown_quiescent(state)
		return false
	}
	patch^ = branch
	// Conservatively retain ownership even if post-write verification fails.
	state.installed = true
	hook_sys_icache_invalidate(rawptr(uintptr(entry)), 4)
	return (^u32)(uintptr(entry))^ == branch
}

ALIAS_WORDS_LIMIT :: 4

// Replaces up to ALIAS_WORDS_LIMIT consecutive instruction words on one page
// through a temporary writable alias, as write_inline_loop_via_alias does.
// The page must already be privatized, and the caller must hold an execution
// barrier with no thread inside the replaced range. Returns false without
// writing when the live words differ from expected.
write_words_via_alias :: proc(
	address: u64,
	expected, replacement: []u32,
	deallocate: Deallocate,
) -> bool {
	count := len(expected)
	if deallocate == nil || address & 3 != 0 || count == 0 || count > ALIAS_WORDS_LIMIT ||
	   len(replacement) != count {return false}
	page_size := mach.vm_page_size
	if page_size == 0 || page_size & (page_size - 1) != 0 {return false}
	page := address & ~(page_size - 1)
	if address + u64(count) * 4 > page + page_size {return false}
	live := ([^]u32)(uintptr(address))
	for index in 0 ..< count {if live[index] != expected[index] {return false}}
	alias: u64
	current, maximum: i32
	task := hook_mach_task_self()
	remapped := hook_mach_vm_remap(task, &alias, page_size, 0, 1, task, page, 0, &current, &maximum, 1)
	if remapped != 0 {return false}
	// A failed alias release leaks one page mapping; the patch result stands.
	defer deallocate(task, alias, page_size)
	if hook_mach_vm_protect(task, alias, page_size, 0, 1 | 2) != 0 {return false}
	patch := ([^]u32)(uintptr(alias + (address - page)))
	for index in 0 ..< count {if patch[index] != expected[index] {return false}}
	for index in 0 ..< count {patch[index] = replacement[index]}
	hook_sys_icache_invalidate(rawptr(uintptr(address)), uint(count * 4))
	for index in 0 ..< count {if live[index] != replacement[index] {return false}}
	return true
}

// Encodes `adrp xd, target@PAGE; add xd, xd, target@PAGEOFF` for an adrp at
// pc. Fails when the target page is outside adrp's +/-4 GiB range.
encode_adrp_add :: proc(pc, target: u64, register: u32) -> (words: [2]u32, ok: bool) {
	if register > 30 {return}
	pages := i64(target >> 12) - i64(pc >> 12)
	if pages < -(1 << 20) || pages >= 1 << 20 {return}
	immediate := u32(pages) & 0x1fffff
	words[0] = 0x90000000 | (immediate & 3) << 29 | (immediate >> 2) << 5 | register
	words[1] = 0x91000000 | u32(target & 0xfff) << 10 | register << 5 | register
	return words, true
}
