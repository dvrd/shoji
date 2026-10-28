package tests

import hook "../src/addition/windowserver/hook"
import "core:testing"

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
