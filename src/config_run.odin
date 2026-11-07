package shoji

// Startup configuration process
// ------------------------------------------------------------------------
// shojirc runs as 'sh -x' with a line-numbered PS4 so a failing command can
// be reported with its line. Trace lines are parsed, never logged; error
// output is forwarded to the daemon log and recorded in a bounded report.
// The daemon keeps running when configuration fails.

import "core:fmt"
import "core:strings"
import "core:sys/posix"

Config_Run :: struct {
	pid: i32,
	output_fd: i32,
	output_open: bool,
	report: Config_Report,
	notified: int, // Failures already handed to the notifier.
}

// Launches path; returns false only when the shell cannot be started.
config_run_start :: proc(run: ^Config_Run, path: string) -> bool {
	assert(run.pid == 0 && !run.output_open)
	if path == "" {
		return true
	}
	// The path is passed as argv, never interpolated into shell source.
	argv := [6]cstring {
		"/usr/bin/env",
		"PS4=" + CONFIG_TRACE_PREFIX + "${LINENO}: ",
		"/bin/sh",
		"-x",
		strings.clone_to_cstring(path, context.temp_allocator),
		nil,
	}
	pid, output_fd, err := spawn_with_stderr_pipe(argv[:])
	if err != "" {
		fmt.eprintf("shoji: cannot execute config %s: %s\n", path, err)
		return false
	}
	run^ = {}
	run.pid = pid
	run.output_fd = output_fd
	run.output_open = output_fd >= 0
	return true
}

// Moves available output into the report. Returns recorded failures.
config_run_drain :: proc(run: ^Config_Run) -> int {
	if !run.output_open {
		return 0
	}
	before := run.report.count + run.report.dropped
	chunk: [512]u8
	for _ in 0 ..< 64 {
		n := posix.read(posix.FD(run.output_fd), &chunk[0], len(chunk))
		if n > 0 {
			config_report_feed(&run.report, chunk[:n])
			continue
		}
		if n < 0 && (posix.errno() == .EAGAIN || posix.errno() == .EINTR) {
			break
		}
		posix.close(posix.FD(run.output_fd))
		run.output_open = false
		break
	}
	recorded := run.report.count + run.report.dropped - before
	for i in run.report.count - min(recorded, run.report.count) ..< run.report.count {
		fmt.eprintln("shoji:", config_failure_text(&run.report.failures[i]))
	}
	return recorded
}

// Handles the shell's exit. Returns false when child is not this run.
config_run_finished :: proc(run: ^Config_Run, child: i32, exit: Child_Exit) -> bool {
	if child == 0 || child != run.pid {
		return false
	}
	config_run_drain(run)
	if run.output_open {
		posix.close(posix.FD(run.output_fd))
		run.output_open = false
	}
	if run.report.pending.count > 0 {
		config_report_line(&run.report, bounded_get(&run.report.pending))
		bounded_set(&run.report.pending, "")
	}
	run.pid = 0
	run.report.exit = exit
	run.report.finished = true
	if !child_exit_ok(exit) && run.report.count == 0 && run.report.dropped == 0 {
		// The shell failed without an attributable error line.
		failure := &run.report.failures[0]
		failure.line = run.report.last_line
		bounded_set(&failure.command, bounded_get(&run.report.last_command))
		bounded_set(&failure.error, fmt.tprintf("configuration %s", child_exit_text(exit)))
		run.report.count = 1
		fmt.eprintln("shoji:", config_failure_text(failure))
	}
	return true
}

config_run_stop :: proc(run: ^Config_Run) {
	if run.output_open {
		posix.close(posix.FD(run.output_fd))
	}
	run.output_open = false
}
