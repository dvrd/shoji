package tests

import gate "../src/windowserver/gate"
import "core:testing"

windowserver_hook_reject_release :: proc "c" (task: u32, address, size: u64) -> i32 {
	return 5
}

windowserver_hook_accept_release :: proc "c" (task: u32, address, size: u64) -> i32 {
	return 0
}

@(test)
windowserver_hook_pending_release_preserves_ownership_until_retry :: proc(t: ^testing.T) {
	// No mappings or instructions are accessed: installed is false and the
	// injected callback models an alias whose release has not completed.
	state := gate.Hook_State {
		alias_page = 0x4000,
		page_size = 0x4000,
		deallocate = windowserver_hook_reject_release,
	}
	testing.expect(t, !gate.teardown_quiescent(&state))
	testing.expect_value(t, state.alias_page, u64(0x4000))
	testing.expect_value(t, state.page_size, u64(0x4000))
	testing.expect(t, !gate.install_entry_via_alias(&state, 0, 4, gate.PACIBSP, windowserver_hook_accept_release))
	state.deallocate = windowserver_hook_accept_release
	testing.expect(t, gate.teardown_quiescent(&state))
	testing.expect_value(t, state.alias_page, u64(0))
	testing.expect(t, state.deallocate == nil)
	testing.expect(t, gate.teardown_quiescent(&state))
}

@(test)
windowserver_hook_teardown_recognizes_completed_restore :: proc(t: ^testing.T) {
	// A failed read-back check may already have published the original word.
	// Its next teardown must accept that completed restore without overwriting
	// an unrelated partial or conflicting state.
	branch := u32(0x14000001)
	testing.expect_value(t, gate.restore_decision(gate.PACIBSP, gate.PACIBSP, gate.PACIBSP, branch), gate.Restore_Decision.Restored)
	testing.expect_value(t, gate.restore_decision(branch, branch, gate.PACIBSP, branch), gate.Restore_Decision.Write)
	testing.expect_value(t, gate.restore_decision(branch, gate.PACIBSP, gate.PACIBSP, branch), gate.Restore_Decision.Conflict)
	testing.expect_value(t, gate.restore_decision(gate.PACIBSP, branch, gate.PACIBSP, branch), gate.Restore_Decision.Conflict)
	testing.expect_value(t, gate.restore_decision(0, 0, gate.PACIBSP, branch), gate.Restore_Decision.Conflict)
}

@(test)
windowserver_hook_empty_ownership_and_invalid_install :: proc(t: ^testing.T) {
	state: gate.Hook_State
	testing.expect(t, gate.teardown_quiescent(&state))
	testing.expect(t, !gate.teardown_quiescent(nil))
	testing.expect(t, !gate.install_entry_via_alias(&state, 0, 4, gate.PACIBSP, nil))
	state.installed = true
	testing.expect(t, !gate.teardown_quiescent(&state))
	testing.expect(t, !gate.install_entry_via_alias(&state, 0, 4, gate.PACIBSP, nil))
}

@(test)
windowserver_hook_branch_checks_alignment_and_signed_range :: proc(t: ^testing.T) {
	cases := []struct {source, target: u64, instruction: u32, ok: bool} {
		{0x10000000, 0x10000000, 0x14000000, true},
		{0x10000000, 0x10000004, 0x14000001, true},
		{0x10000000, 0x0ffffffc, 0x17ffffff, true},
		{0x10000000, 0x17fffffc, 0x15ffffff, true},
		{0x10000000, 0x08000000, 0x16000000, true},
		{0x10000000, 0x18000000, 0, false},
		{0x10000004, 0x08000000, 0, false},
		{0x10000002, 0x10000000, 0, false},
		{0x10000000, 0x10000002, 0, false},
		{0, 0xfffffffffffffffc, 0, false},
	}
	for c in cases {
		instruction, ok := gate.encode_branch(c.source, c.target)
		testing.expect_value(t, ok, c.ok)
		if ok {testing.expect_value(t, instruction, c.instruction)}
	}
}

@(test)
windowserver_hook_nearby_allocation_is_bounded_in_both_directions :: proc(t: ^testing.T) {
	page := u64(0x4000)
	base := u64(0x10000000)
	for below in ([]bool{false, true}) {
		candidate, ok := gate.nearby_region_base(base, page, 3 * page, page, below)
		testing.expect(t, ok)
		expected := base + page
		if below {expected = base - page}
		testing.expect_value(t, candidate, expected)
	}
	candidate, ok := gate.nearby_region_base(base, 0x08000000 - 3 * page, 3 * page, page, true)
	testing.expect(t, ok)
	testing.expect_value(t, candidate, base - (0x08000000 - 3 * page))
	_, ok = gate.nearby_region_base(base, 0x08000000, 3 * page, page, false)
	testing.expect(t, !ok)
	_, ok = gate.nearby_region_base(page, 2 * page, 3 * page, page, true)
	testing.expect(t, !ok)
	_, ok = gate.nearby_region_base(max(u64) - page + 1, page, 3 * page, page, false)
	testing.expect(t, !ok)
	_, ok = gate.nearby_region_base(base, 0, 3 * page, page, false)
	testing.expect(t, !ok)
	_, ok = gate.nearby_region_base(base, 1, 3 * page, page, false)
	testing.expect(t, !ok)
	_, ok = gate.nearby_region_base(base, page, 3 * page, 0, false)
	testing.expect(t, !ok)
}

@(test)
windowserver_hook_rejects_unverified_prologues :: proc(t: ^testing.T) {
	testing.expect(t, gate.supported_entry(0xd503237f))
	testing.expect(t, !gate.supported_entry(0xd503233f))
	testing.expect(t, !gate.supported_entry(0x14000000))
	testing.expect(t, !gate.supported_entry(0))
}

@(test)
windowserver_hook_plans_only_bounded_verified_forwarding :: proc(t: ^testing.T) {
	p, ok := gate.plan(0x1000, 0x2000, 0x3000, gate.PACIBSP)
	testing.expect(t, ok)
	testing.expect_value(t, p.entry_branch, u32(0x14000800))
	testing.expect_value(t, p.displaced, gate.PACIBSP)
	testing.expect_value(t, p.resume_branch, u32(0x17fffc00))
	_, ok = gate.plan(0x1000, 0x2000, 0x3000, 0xd503233f)
	testing.expect(t, !ok)
	_, ok = gate.plan(0x1000, 0x2000, 0x1000, gate.PACIBSP)
	testing.expect(t, !ok)
	_, ok = gate.plan(0x1000, 0x80001000, 0x3000, gate.PACIBSP)
	testing.expect(t, !ok)
}

@(test)
windowserver_hook_plans_inline_absolute_forwarding :: proc(t: ^testing.T) {
	displaced := [4]u32{0xd503237f, 0xa9ba6ffc, 0x910003fd, 0xa9025ff8}
	p, ok := gate.plan_inline(0x1000, 0x9000, 0x123456788, displaced)
	testing.expect(t, ok)
	testing.expect_value(t, p.entry_jump[0], gate.INLINE_LDR_X16_LITERAL)
	testing.expect_value(t, p.entry_jump[1], gate.INLINE_BR_X16)
	testing.expect_value(t, p.entry_jump[2], u32(0x23456788))
	testing.expect_value(t, p.entry_jump[3], u32(0x1))
	testing.expect_value(t, p.displaced, displaced)
	testing.expect_value(t, p.resume_jump[2], u32(0x1010))
	testing.expect_value(t, p.resume_jump[3], u32(0))
	_, ok = gate.plan_inline(0x1002, 0x9000, 0x3000, displaced)
	testing.expect(t, !ok)
	_, ok = gate.plan_inline(max(u64) - 8, 0x9000, 0x3000, displaced)
	testing.expect(t, !ok)
}

@(test)
windowserver_hook_inline_restore_requires_matching_words :: proc(t: ^testing.T) {
	original := [4]u32{1, 2, 3, 4}
	jump := [4]u32{5, 6, 7, 8}
	testing.expect_value(t, gate.inline_restore_decision(original, original, original, jump), gate.Restore_Decision.Restored)
	testing.expect_value(t, gate.inline_restore_decision(jump, jump, original, jump), gate.Restore_Decision.Write)
	testing.expect_value(t, gate.inline_restore_decision(original, jump, original, jump), gate.Restore_Decision.Conflict)
	partial := original
	partial[3] = 99
	testing.expect_value(t, gate.inline_restore_decision(partial, partial, original, jump), gate.Restore_Decision.Conflict)
	state: gate.Inline_State
	testing.expect(t, gate.teardown_inline_quiescent(&state))
	testing.expect(t, !gate.install_inline_via_alias(&state, 0, 4, original, nil))
}
