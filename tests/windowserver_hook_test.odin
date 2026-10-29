package tests

import hook "../src/experimental/window_server"
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
	state := hook.Hook_State {
		alias_page = 0x4000,
		page_size = 0x4000,
		deallocate = windowserver_hook_reject_release,
	}
	testing.expect(t, !hook.teardown_quiescent(&state))
	testing.expect_value(t, state.alias_page, u64(0x4000))
	testing.expect_value(t, state.page_size, u64(0x4000))
	testing.expect(t, !hook.install_entry_via_alias(&state, 0, 4, hook.PACIBSP, windowserver_hook_accept_release))
	state.deallocate = windowserver_hook_accept_release
	testing.expect(t, hook.teardown_quiescent(&state))
	testing.expect_value(t, state.alias_page, u64(0))
	testing.expect(t, state.deallocate == nil)
	testing.expect(t, hook.teardown_quiescent(&state))
}

@(test)
windowserver_hook_teardown_recognizes_completed_restore :: proc(t: ^testing.T) {
	// A failed read-back check may already have published the original word.
	// Its next teardown must accept that completed restore without overwriting
	// an unrelated partial or conflicting state.
	branch := u32(0x14000001)
	testing.expect_value(t, hook.restore_decision(hook.PACIBSP, hook.PACIBSP, hook.PACIBSP, branch), hook.Restore_Decision.Restored)
	testing.expect_value(t, hook.restore_decision(branch, branch, hook.PACIBSP, branch), hook.Restore_Decision.Write)
	testing.expect_value(t, hook.restore_decision(branch, hook.PACIBSP, hook.PACIBSP, branch), hook.Restore_Decision.Conflict)
	testing.expect_value(t, hook.restore_decision(hook.PACIBSP, branch, hook.PACIBSP, branch), hook.Restore_Decision.Conflict)
	testing.expect_value(t, hook.restore_decision(0, 0, hook.PACIBSP, branch), hook.Restore_Decision.Conflict)
}

@(test)
windowserver_hook_empty_ownership_and_invalid_install :: proc(t: ^testing.T) {
	state: hook.Hook_State
	testing.expect(t, hook.teardown_quiescent(&state))
	testing.expect(t, !hook.teardown_quiescent(nil))
	testing.expect(t, !hook.install_entry_via_alias(&state, 0, 4, hook.PACIBSP, nil))
	state.installed = true
	testing.expect(t, !hook.teardown_quiescent(&state))
	testing.expect(t, !hook.install_entry_via_alias(&state, 0, 4, hook.PACIBSP, nil))
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
		instruction, ok := hook.encode_branch(c.source, c.target)
		testing.expect_value(t, ok, c.ok)
		if ok {testing.expect_value(t, instruction, c.instruction)}
	}
}

@(test)
windowserver_hook_nearby_allocation_is_bounded_in_both_directions :: proc(t: ^testing.T) {
	page := u64(0x4000)
	base := u64(0x10000000)
	for below in ([]bool{false, true}) {
		candidate, ok := hook.nearby_region_base(base, page, 3 * page, page, below)
		testing.expect(t, ok)
		expected := base + page
		if below {expected = base - page}
		testing.expect_value(t, candidate, expected)
	}
	candidate, ok := hook.nearby_region_base(base, 0x08000000 - 3 * page, 3 * page, page, true)
	testing.expect(t, ok)
	testing.expect_value(t, candidate, base - (0x08000000 - 3 * page))
	_, ok = hook.nearby_region_base(base, 0x08000000, 3 * page, page, false)
	testing.expect(t, !ok)
	_, ok = hook.nearby_region_base(page, 2 * page, 3 * page, page, true)
	testing.expect(t, !ok)
	_, ok = hook.nearby_region_base(max(u64) - page + 1, page, 3 * page, page, false)
	testing.expect(t, !ok)
	_, ok = hook.nearby_region_base(base, 0, 3 * page, page, false)
	testing.expect(t, !ok)
	_, ok = hook.nearby_region_base(base, 1, 3 * page, page, false)
	testing.expect(t, !ok)
	_, ok = hook.nearby_region_base(base, page, 3 * page, 0, false)
	testing.expect(t, !ok)
}

@(test)
windowserver_hook_rejects_unverified_prologues :: proc(t: ^testing.T) {
	testing.expect(t, hook.supported_entry(0xd503237f))
	testing.expect(t, !hook.supported_entry(0xd503233f))
	testing.expect(t, !hook.supported_entry(0x14000000))
	testing.expect(t, !hook.supported_entry(0))
}

@(test)
windowserver_hook_plans_only_bounded_verified_forwarding :: proc(t: ^testing.T) {
	p, ok := hook.plan(0x1000, 0x2000, 0x3000, hook.PACIBSP)
	testing.expect(t, ok)
	testing.expect_value(t, p.entry_branch, u32(0x14000800))
	testing.expect_value(t, p.displaced, hook.PACIBSP)
	testing.expect_value(t, p.resume_branch, u32(0x17fffc00))
	_, ok = hook.plan(0x1000, 0x2000, 0x3000, 0xd503233f)
	testing.expect(t, !ok)
	_, ok = hook.plan(0x1000, 0x2000, 0x1000, hook.PACIBSP)
	testing.expect(t, !ok)
	_, ok = hook.plan(0x1000, 0x80001000, 0x3000, hook.PACIBSP)
	testing.expect(t, !ok)
}
