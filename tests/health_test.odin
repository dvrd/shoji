package tests

import mac "../src"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

@(test)
output_tail_keeps_most_recent_bytes_and_last_line :: proc(t: ^testing.T) {
	tail: mac.Output_Tail
	mac.output_tail_append(&tail, transmute([]u8)string("first\nsecond line\n"))
	testing.expect_value(t, mac.output_tail_last_line(&tail), "second line")
	big := make([]u8, mac.OUTPUT_TAIL_BYTES + 100, context.temp_allocator)
	for i in 0 ..< len(big) {big[i] = 'a'}
	copy(big[len(big) - 4:], "\nend")
	mac.output_tail_append(&tail, big)
	testing.expect_value(t, tail.count, mac.OUTPUT_TAIL_BYTES)
	testing.expect_value(t, mac.output_tail_last_line(&tail), "end")
	mac.output_tail_append(&tail, transmute([]u8)string("\nlast"))
	testing.expect_value(t, tail.count, mac.OUTPUT_TAIL_BYTES)
	testing.expect_value(t, mac.output_tail_last_line(&tail), "last")
}

@(test)
payload_cause_uses_evidence_not_assumptions :: proc(t: ^testing.T) {
	sudo := mac.payload_failure_cause(
		"Dock payload load failed",
		{.Exited, 1},
		"sudo: a password is required\n",
	)
	testing.expect(t, strings.contains(sudo, "sudo requires a password"))
	crash := mac.payload_failure_cause(
		"Dock payload load failed",
		{.Exited, 1},
		"Dock scripting addition is not loaded\narm64e loader helper failed\n",
	)
	testing.expect(t, strings.contains(crash, "arm64e loader helper failed"))
	testing.expect(t, strings.contains(crash, "exit status 1"))
	testing.expect(t, !strings.contains(crash, "sudo"))
	killed := mac.payload_failure_cause("Dock payload check failed", {.Signaled, 9}, "")
	testing.expect_value(t, killed, "Dock payload check failed: killed by signal 9")
}

@(test)
payload_health_escalates_once_and_reports_recovery :: proc(t: ^testing.T) {
	h: mac.Payload_Health
	now := time.now()
	for i in 1 ..< mac.PAYLOAD_FAILURE_ESCALATION {
		transition := mac.payload_health_failure(&h, "cause", "", now)
		testing.expect_value(t, transition, mac.Health_Transition.None)
		testing.expect_value(t, h.state, mac.Payload_Health_State.Recovering)
		testing.expect_value(t, h.failures, u32(i))
	}
	failed := mac.payload_health_failure(&h, "loader crashed", "/tmp/report.ips", now)
	testing.expect_value(t, failed, mac.Health_Transition.Failed)
	testing.expect_value(t, mac.bounded_get(&h.cause), "loader crashed")
	testing.expect_value(t, mac.bounded_get(&h.crash_report), "/tmp/report.ips")
	again := mac.payload_health_failure(&h, "loader crashed", "", now)
	testing.expect_value(t, again, mac.Health_Transition.None)
	testing.expect_value(t, h.state, mac.Payload_Health_State.Failed)
	testing.expect_value(t, mac.payload_health_success(&h, now), mac.Health_Transition.Recovered)
	testing.expect_value(t, h.failures, u32(0))
	testing.expect_value(t, mac.payload_health_success(&h, now), mac.Health_Transition.None)
}

@(test)
reload_failures_escalate_and_release_waiting_config :: proc(t: ^testing.T) {
	r: mac.Addition_Reload;rec: Reload_Recorder
	reload_fixture(&r, &rec);defer delete(rec.phases)
	started := false
	config_launch_count = 0
	now := time.now()
	mac.addition_reload_tick(&r, 42, now)
	mac.addition_reload_finished(&r, r.child, reload_failed, now) // Expected: not loaded yet.
	testing.expect_value(t, r.health.failures, u32(0))
	for _ in 0 ..< mac.PAYLOAD_FAILURE_ESCALATION {
		mac.addition_reload_tick(&r, 42, now)
		if r.phase == .Check {
			mac.addition_reload_finished(&r, r.child, reload_failed, now)
			mac.addition_reload_tick(&r, 42, now)
		}
		testing.expect(t, mac.startup_config_start("cfg", &r, &started, record_config_launch))
		testing.expect(t, !started)
		mac.addition_reload_finished(&r, r.child, mac.Child_Exit{.Signaled, 9}, now)
		now = r.next_attempt
	}
	testing.expect_value(t, r.health.state, mac.Payload_Health_State.Failed)
	testing.expect_value(t, r.transition, mac.Health_Transition.Failed)
	testing.expect(t, strings.contains(mac.bounded_get(&r.health.cause), "killed by signal 9"))
	testing.expect(t, mac.startup_config_start("cfg", &r, &started, record_config_launch))
	testing.expect(t, started && config_launch_count == 1)
}

@(test)
crash_report_lookup_picks_newest_matching_report_since_spawn :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/shoji-crash-test-%d", posix.getpid())
	os.make_directory(dir)
	defer os.remove_all(dir)
	since := time.time_add(time.now(), -time.Second)
	write :: proc(dir, name: string) {
		path := fmt.tprintf("%s/%s", dir, name)
		_ = os.write_entire_file(path, transmute([]u8)string("{}"))
	}
	write(dir, "other-2026.ips")
	write(dir, "shoji-loader-a.ips")
	time.sleep(20 * time.Millisecond)
	write(dir, "shoji-loader-b.ips")
	write(dir, "shoji-loader-c.txt")
	found := mac.crash_report_newest(dir, mac.CRASH_REPORT_PREFIX, since)
	testing.expect(t, strings.has_suffix(found, "shoji-loader-b.ips"))
	later := time.time_add(time.now(), time.Hour)
	testing.expect_value(t, mac.crash_report_newest(dir, mac.CRASH_REPORT_PREFIX, later), "")
	testing.expect_value(t, mac.crash_report_newest("/nonexistent/dir", "x", since), "")
}

@(test)
config_report_attributes_errors_to_traced_lines_across_chunks :: proc(t: ^testing.T) {
	report: mac.Config_Report
	text := "+shojirc:4: shoji -m config layout scroll\n" +
		"+shojirc:12: shoji -m config focus_ring_color 0xff\n" +
		"Dock scripting addition is not loaded; use --load-sa\n" +
		"++ nested\n"
	data := transmute([]u8)text
	mac.config_report_feed(&report, data[:30])
	mac.config_report_feed(&report, data[30:])
	testing.expect_value(t, report.count, 1)
	failure := &report.failures[0]
	testing.expect_value(t, failure.line, i32(12))
	command := mac.bounded_get(&failure.command)
	testing.expect_value(t, command, "shoji -m config focus_ring_color 0xff")
	error_text := mac.bounded_get(&failure.error)
	testing.expect(t, strings.has_prefix(error_text, "Dock scripting addition"))
	for _ in 0 ..< mac.CONFIG_FAILURE_LIMIT + 3 {mac.config_report_line(&report, "error")}
	testing.expect_value(t, report.count, mac.CONFIG_FAILURE_LIMIT)
	testing.expect_value(t, report.dropped, 4)
}

@(test)
notifier_admission_deduplicates_and_rate_limits :: proc(t: ^testing.T) {
	n: mac.Notifier
	now := time.now()
	testing.expect(t, mac.notifier_admit(&n, 1, now))
	testing.expect(t, !mac.notifier_admit(&n, 1, now))
	later := time.time_add(now, mac.NOTIFY_DEDUPE_WINDOW + time.Second)
	testing.expect(t, mac.notifier_admit(&n, 1, later))
	for key in 2 ..< u64(mac.NOTIFY_RATE_LIMIT + 1) {
		testing.expect(t, mac.notifier_admit(&n, key, later))
	}
	testing.expect(t, !mac.notifier_admit(&n, 99, later))
	after := time.time_add(later, mac.NOTIFY_RATE_WINDOW + time.Second)
	testing.expect(t, mac.notifier_admit(&n, 100, after))
	testing.expect_value(t, n.suppressed, 2)
}

@(test)
config_run_reports_failing_line_from_real_shell :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/shoji-config-test-%d.sh", posix.getpid())
	script := "set -eu\ntrue\necho 'setting rejected' >&2\nfalse\necho unreachable\n"
	testing.expect(t, os.write_entire_file(path, transmute([]u8)script) == nil)
	defer os.remove(path)
	run: mac.Config_Run
	testing.expect(t, mac.config_run_start(&run, path))
	status: i32
	testing.expect_value(t, i32(posix.waitpid(posix.pid_t(run.pid), &status, {})), run.pid)
	testing.expect(t, mac.config_run_finished(&run, run.pid, mac.child_exit_from_status(status)))
	testing.expect(t, run.report.finished && !run.output_open)
	testing.expect_value(t, run.report.exit, mac.Child_Exit{.Exited, 1})
	testing.expect_value(t, run.report.count, 1)
	failure := &run.report.failures[0]
	testing.expect_value(t, failure.line, i32(3))
	testing.expect_value(t, mac.bounded_get(&failure.error), "setting rejected")
}

@(test)
stderr_pipe_spawn_captures_child_output_and_exit :: proc(t: ^testing.T) {
	argv := [4]cstring{"/bin/sh", "-c", "echo 'loader failed' >&2; exit 3", nil}
	pid, fd, err := mac.spawn_with_stderr_pipe(argv[:])
	testing.expect_value(t, err, "")
	status: i32
	posix.waitpid(posix.pid_t(pid), &status, {})
	tail: mac.Output_Tail
	for mac.output_tail_drain(&tail, fd) {time.sleep(time.Millisecond)}
	posix.close(posix.FD(fd))
	testing.expect_value(t, mac.output_tail_last_line(&tail), "loader failed")
	testing.expect_value(t, mac.child_exit_from_status(status), mac.Child_Exit{.Exited, 3})
}

@(test)
service_status_parses_launchd_and_renders_failures :: proc(t: ^testing.T) {
	dump := "gui/501/tech.shoji.window-manager = {\n" +
		"\tstate = running\n" +
		"\tprogram = /Users/u/shoji/bin/Shoji.app/Contents/MacOS/shoji\n" +
		"\targuments = {\n\t\t/x/shoji\n\t\t-c\n\t\t/Users/u/.config/shoji/shojirc\n\t}\n" +
		"\tstderr path = /Users/u/Library/Logs/shoji/shoji.err.log\n" +
		"\truns = 3\n\tpid = 42\n\tlast exit code = 0\n" +
		"\tdefault environment = {\n\t\tstate = nested\n\t}\n}\n"
	l := mac.launchd_status_parse(dump)
	testing.expect_value(t, l.state, "running")
	testing.expect_value(t, l.pid, "42")
	testing.expect_value(t, l.runs, "3")
	testing.expect_value(t, l.config, "/Users/u/.config/shoji/shojirc")
	failures := []mac.Health_Config_Failure_JSON{{4, "shoji -m bogus", "unknown domain"}}
	h := mac.Health_JSON {
		payload = "failed",
		payload_cause = "loader exited",
		config_finished = true,
		config_exit = "exit status 1",
		config_failures = failures,
		notifications = "allowed",
	}
	b := strings.builder_make(context.temp_allocator)
	mac.status_render(&b, {color = false, home = "/Users/u"}, l, h, "")
	out := strings.to_string(b)
	testing.expect(t, strings.contains(out, "Shoji  ● running  pid 42 · runs 3\n"))
	testing.expect(t, strings.contains(out, "~/shoji/bin/Shoji.app\n"))
	testing.expect(t, strings.contains(out, "✗ 1 error · exit status 1"))
	testing.expect(t, strings.contains(out, "line 4: shoji -m bogus → unknown domain"))
	testing.expect(t, strings.contains(out, "● failed"))
	testing.expect(t, !strings.contains(out, "\x1b["))
}
