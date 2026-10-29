package tests

import i "../../inspector/inspect"
import h "../harness"
import tc "../../common"
import s "../../../src"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import posix "core:sys/posix"
import "core:testing"
import "core:time"

@(test)
native_prebuilt_fixture_requires_a_verified_regular_file :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	root, _ := s.temp("shoji-prebuilt-fixture-test"); defer os.remove_all(root)
	r: Tool_Recorder
	c := tool_context(root, &r)
	testing.expect(t, h.build_live_helper(c, true) != "")
	testing.expect_value(t, len(r.calls), 0)
	_ = s.mkdir(s.join(root, "bin"))
	_ = s.write(tc.binary(c, "harness-fixture"), "fixture")
	r.fail_verify = true
	testing.expect(t, h.build_live_helper(c, true) != "")
	testing.expect_value(t, len(r.calls), 1)
	r.fail_verify = false
	testing.expect_value(t, h.build_live_helper(c, true), "")
	for call in r.calls {
		testing.expect(t, call.args[0] == "/usr/bin/codesign" || call.args[0] == "/usr/bin/shasum")
	}
}

@(test)
native_evidence_failures_propagate_and_preserve_original_failures :: proc(
	t: ^testing.T,
) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	root, _ := s.temp("shoji-evidence-error-test"); defer os.remove_all(root)
	blocked := s.join(root, "blocked"); _ = s.mkdir(blocked)
	report := h.Validation_Report {
		status = "desktop-preflight-passed",
	}
	err: string
	h.finish_validation(&report, blocked, "original check failure", &err)
	testing.expect_value(t, report.status, "failed")
	testing.expect(
		t,
		strings.contains(err, "original check failure") &&
		strings.contains(err, "report evidence"),
	)
	for status in ([]string{"desktop-blocked", "target-mismatch"}) {
		report.status = status
		h.finish_validation(
			&report,
			s.join(root, "validation.json"),
			"preflight failed",
			&err,
		)
		testing.expect_value(t, report.status, status)
		testing.expect_value(t, err, "preflight failed")
	}
	l := h.Live {
		evidence = root,
	}
	_ = s.mkdir(s.join(root, "commands.json"))
	h.record_cleanup(&l, "owned child", "could not reap")
	h.save_live(&l, "original live failure", &err)
	testing.expect_value(t, l.report.status, "failed")
	testing.expect(
		t,
		h.finish_live(&l, "returned check error") != "",
		"final evidence failure must determine the caller's returned status",
	)
	testing.expect(
		t,
		strings.contains(err, "original live failure") &&
		strings.contains(err, "could not reap") &&
		strings.contains(err, "command evidence"),
	)
	saved: h.Live_Report
	testing.expect_value(
		t,
		s.read_json(s.join(root, "report.json"), &saved),
		"",
	)
	testing.expect_value(t, saved.status, "failed")
	_ = os.remove(s.join(root, "report.json"))
	_ = s.mkdir(s.join(root, "report.json"))
	h.save_live(&l, "", &err)
	testing.expect(t, strings.contains(err, "report evidence"))
	testing.expect_value(t, l.report.status, "failed")
	// A missing/unreadable binary must prevent checks from starting without a hash.
	prepared, hash_error := h.prepare_live(
		{root = root},
		"shoji-missing-hash-test",
	)
	defer os.remove_all(prepared.evidence)
	testing.expect(t, strings.contains(hash_error, "binary evidence"))
	testing.expect_value(t, prepared.report.status, "failed")
}

@(test)
native_cancellation_reaps_child_and_allows_cleanup :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	root, _ := s.temp("shoji-interrupt-test"); defer os.remove_all(root)
	c := tc.Context {
		root = tc.project_root(),
	}
	fixture := s.join(root, "cancellation")
	result := s.process_run(
		{},
		[]string {
			tc.compiler(c),
			"build",
			s.join(c.root, "tools/harness/fixtures/cancellation"),
			s.cat("-out:", fixture),
			"-warnings-as-errors",
		},
		env = tc.compiler_env(c),
	)
	testing.expect(t, result.code == 0, result.diagnostic)
	if result.code != 0 {
		return
	}
	l := h.Live {
		c        = c,
		evidence = root,
	}
	unrelated, unrelated_error := h.start_child(
		&l,
		[]string{"/bin/sleep", "30"},
		"unrelated",
	)
	testing.expect_value(t, unrelated_error, "")
	if unrelated_error != "" {
		return
	}
	defer h.stop_child(&unrelated)
	for mode in ([]string{"interrupt", "timeout", "stubborn"}) {
		pidfile := s.join(root, s.cat(mode, ".pid"))
		child, err := h.start_child(&l, []string{fixture, mode, pidfile}, mode)
		testing.expect_value(t, err, ""); if err != "" {
			return
		}
		defer h.stop_child(&child)
		line, startup_error := h.first_line(&child)
		testing.expect_value(t, startup_error, "")
		testing.expect_value(t, line, "ready")
		// Signal only the fixture process created by this test, never the test runner.
		started := time.tick_now()
		for !s.regular(pidfile) &&
		    time.tick_since(started) <
			    2 * time.Second { time.sleep(10 * time.Millisecond) }
		text, read_error := s.read(pidfile)
		testing.expect_value(t, read_error, "")
		pid, valid := strconv.parse_i64(s.trim(text))
		testing.expect(t, valid && pid > 1)
		if !valid || pid <= 1 {
			return
		}
		defer posix.kill(posix.pid_t(pid), .SIGKILL) // Emergency cleanup if the regression fails.
		if mode == "interrupt" {
			testing.expect_value(
				t,
				posix.kill(posix.pid_t(child.process.pid), .SIGINT),
				nil,
			)
		}
		state, wait_error := os.process_wait(child.process, 3 * time.Second)
		testing.expect_value(t, wait_error, nil)
		if wait_error == nil {
			child.active = false
		}
		testing.expect_value(t, int(state.exit_code), 130)
		output, _ := s.read(child.stdout)
		testing.expect(t, strings.contains(output, "cleanup completed"))
		deadline := time.tick_now()
		for posix.kill(posix.pid_t(pid), posix.Signal(0)) == nil &&
		    time.tick_since(deadline) <
			    time.Second { time.sleep(10 * time.Millisecond) }
		testing.expect(
			t,
			posix.kill(posix.pid_t(pid), posix.Signal(0)) != nil,
			"owned descendant survived command cleanup",
		)
		testing.expect(
			t,
			h.child_alive(&unrelated),
			"cleanup must preserve unrelated processes",
		)
	}
}

@(test)
native_validation_records_failures_and_timeouts_without_false_passes :: proc(
	t: ^testing.T,
) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	root, _ := s.temp("shoji-validation-test"); defer os.remove_all(root)
	c := tc.Context {
		root = root,
	}
	pass := make(map[string]h.Validation_Check); pass["test"] = {
		status = "pass",
	}
	fail := make(map[string]h.Validation_Check); fail["test"] = {
		status = "fail",
	}
	testing.expect_value(
		t,
		h.validation_summary(pass, fail, false),
		"desktop-blocked",
	)
	testing.expect_value(
		t,
		h.validation_summary(pass, fail, true),
		"desktop-blocked",
	)
	testing.expect_value(
		t,
		h.validation_summary(pass, pass, false),
		"automated-checks-passed-live-pending",
	)
	testing.expect_value(
		t,
		h.validation_summary(pass, pass, true),
		"selected-live-checks-passed",
	)
	testing.expect_value(t, h.validation_summary(fail, pass, true), "failed")
	result := h.validation_execute(
		c,
		[]string{"/bin/sh", "-c", "printf diagnostic; exit 7"},
		root,
		"failure",
	)
	testing.expect_value(t, result.exit_code, 7)
	testing.expect_value(t, result.status, "fail")
	text, _ := s.read(result.log)
	testing.expect(t, strings.contains(text, "diagnostic"))
	result = h.validation_execute(
		c,
		[]string{"/bin/sleep", "10"},
		root,
		"timeout",
		50 * time.Millisecond,
	)
	testing.expect_value(t, result.exit_code, -1)
	testing.expect_value(t, result.status, "fail")
	text, _ = s.read(result.log)
	testing.expect(t, strings.contains(text, "Timeout"))
}

@(test)
native_live_guards_preserve_existing_daemons_and_preexisting_spaces :: proc(
	t: ^testing.T,
) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	r := Tool_Recorder {
		shoji_running = true,
	}; c := tool_context("/test", &r)
	testing.expect(t, h.desktop_guard(c) != "")
	testing.expect_value(t, len(r.calls), 1)
	for id in ([3]u64{0, 1, 2}) {
		allowed, err := h.space_cleanup_allowed(
			id,
			1,
			[]u64{1, 2},
			[]u64{1, 2, 3, 4},
		); testing.expect(t, !allowed && err != "")
	}
	allowed, err := h.space_cleanup_allowed(
		3,
		1,
		[]u64{1, 2},
		[]u64{1, 2, 3, 4},
	); testing.expect(t, allowed && err == "")
	allowed, err = h.space_cleanup_allowed(3, 1, []u64{1, 2}, []u64{1, 2, 4})
	testing.expect(t, !allowed && err == "")
	allowed, err = h.space_cleanup_allowed(3, 1, []u64{1, 2}, []u64{2, 3, 4})
	testing.expect(t, !allowed && err != "")
	clear(&r.calls); l := h.Live {
		c = c,
	}
	testing.expect_value(t, h.restore_space(&l, 3, 1, []u64{1, 2}), "")
	testing.expect_value(t, len(r.calls), 3)
	testing.expect_value(t, r.calls[1].args[1], "space-focus")
	testing.expect_value(t, r.calls[1].args[2], "1")
	testing.expect_value(t, r.calls[2].args[1], "space-destroy")
	testing.expect_value(t, r.calls[2].args[2], "3")
}

@(test)
native_dock_restart_requires_policy_and_requests_recovery_on_timeout :: proc(
	t: ^testing.T,
) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	r := Tool_Recorder {
		policy_fail = true,
	}; c := tool_context("/test", &r)
	testing.expect(t, h.restart_dock(c, 501) != "")
	testing.expect_value(t, len(r.calls), 1)
	r.policy_fail = false; clear(&r.calls)
	testing.expect_value(t, h.restart_dock(c, 501), "")
	testing.expect_value(t, r.calls[1].args[2], "gui/501/com.apple.Dock.agent")
	testing.expect_value(t, r.calls[3].args[1], "kickstart")
	testing.expect_value(t, r.calls[3].args[2], "-k")
	r.dock_queries = 0; r.dock_stuck = true; clear(&r.calls)
	testing.expect(t, h.restart_dock(c, 501, 0) != "")
	last := r.calls[len(r.calls) - 1].args
	testing.expect_value(t, len(last), 3)
	testing.expect_value(t, last[1], "kickstart")
	for call in r.calls { testing.expect(t, !(call.args[0] == "sudo" && len(call.args) > 2 && call.args[2] == "/test/bin/shoji")) }
}

@(test)
native_alpha_parser_and_owned_child_cleanup_handle_failures :: proc(
	t: ^testing.T,
) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	invalid := []string {
		"",
		"[]",
		`{"window":123}`,
		`{"window":124,"query_alpha":1}`,
		`{"window":123,"query_alpha":true}`,
		`{"window":123,"query_alpha":NaN}`,
		`{"window":123,"query_alpha":2}`,
	}
	for text in invalid {
		_, err := h.parse_alpha(text, 123); testing.expect(t, err != "")
	}
	alpha, err := h.parse_alpha(`{"window":123,"query_alpha":0.5}`, 123)
	testing.expect_value(t, err, ""); testing.expect_value(t, alpha, f64(.5))
	root, _ := s.temp("shoji-child-test"); defer os.remove_all(root)
	live := h.Live {
		evidence = root,
	}
	child, e := h.start_child(&live, []string{"/bin/sleep", "10"}, "owned")
	testing.expect_value(t, e, "")
	testing.expect(t, h.child_alive(&child)); h.stop_child(&child)
	testing.expect(t, !child.active)
	malformed, e1 := h.start_child(
		&live,
		[]string{"/usr/bin/printf", "not JSON\n"},
		"malformed",
	); testing.expect_value(t, e1, "")
	line, e2 := h.first_line(&malformed); testing.expect_value(t, e2, "")
	testing.expect_value(t, line, "not JSON")
	h.stop_child(&malformed); testing.expect(t, !malformed.active)
}

@(test)
native_bootstrap_inspection_rejects_external_references :: proc(
	t: ^testing.T,
) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	metadata := "Section\nsectname __shoji_boot\nflags 0x80000400\n"
	code := "remote_entry remote_worker\n1000: d61f0260 br x19\n1004: d503201f nop\n"
	testing.expect_value(t, i.validate_bootstrap(metadata, code), "")
	testing.expect(
		t,
		i.validate_bootstrap(
			metadata,
			"remote_entry remote_worker\n1000: 94000000 bl 0x2000\n",
		) !=
		"",
	)
	testing.expect(
		t,
		i.validate_bootstrap(
			metadata,
			"remote_entry remote_worker\n1000: 90000000 adrp x0, 0x2000\n",
		) !=
		"",
	)
	testing.expect(
		t,
		i.validate_bootstrap(
			"Section\nsectname __shoji_boot\nflags 0x00000000",
			code,
		) !=
		"",
	)
}

@(test)
native_live_helper_emits_valid_json_without_windowserver :: proc(
	t: ^testing.T,
) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	root, _ := s.temp("shoji-helper-output-test"); defer os.remove_all(root)
	c := tc.Context {
		root = tc.project_root(),
	}; helper := s.join(root, "helper")
	r := s.process_run(
		{},
		[]string {
			tc.compiler(c),
			"build",
			s.join(c.root, "tools/harness/fixtures/desktop"),
			s.cat("-out:", helper),
			"-extra-linker-flags:-F/System/Library/PrivateFrameworks",
		},
		timeout = 120 * time.Second,
		env = tc.compiler_env(c),
	)
	testing.expect(t, r.code == 0, s.cat(r.out, r.diagnostic))
	if r.code != 0 {
		return
	}
	output := s.process_run(
		{},
		[]string{helper, "--self-test-output"},
		timeout = 15 * time.Second,
	)
	testing.expect_value(t, output.code, 0)
	alpha, err := h.parse_alpha(output.out, 123)
	testing.expect_value(t, err, ""); testing.expect_value(t, alpha, f64(.5))
}
