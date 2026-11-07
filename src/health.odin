package shoji

// Runtime health reporting
// ------------------------------------------------------------------------
// Background failures (Dock payload recovery, startup configuration) must be
// visible to the user with their real cause. Everything here is bounded:
// fixed-size text buffers, a fixed escalation threshold and a bounded
// directory scan. Notifications consume the transitions recorded here.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:time"

OUTPUT_TAIL_BYTES :: 2048
HEALTH_TEXT_BYTES :: 512
HEALTH_PATH_BYTES :: 1024
// Consecutive load failures before recovery is reported as failed. Retries
// continue with backoff; only the reported state escalates.
PAYLOAD_FAILURE_ESCALATION :: 3
CRASH_REPORT_SCAN_LIMIT :: 4096
CRASH_REPORT_PREFIX :: "shoji-loader-"
CONFIG_FAILURE_LIMIT :: 8
// Shell trace prefix for startup configuration; LINENO is expanded by sh.
CONFIG_TRACE_PREFIX :: "+shojirc:"

Child_Exit_Kind :: enum u8 {
	Exited,
	Signaled,
	Unknown,
}
Child_Exit :: struct {
	kind: Child_Exit_Kind,
	code: i32, // Exit status or terminating signal.
}

child_exit_from_status :: proc(status: i32) -> Child_Exit {
	if posix.WIFEXITED(status) {
		return {.Exited, i32(posix.WEXITSTATUS(status))}
	}
	if posix.WIFSIGNALED(status) {
		return {.Signaled, i32(posix.WTERMSIG(status))}
	}
	return {.Unknown, status}
}

child_exit_ok :: proc(exit: Child_Exit) -> bool {
	return exit.kind == .Exited && exit.code == 0
}

child_exit_text :: proc(exit: Child_Exit) -> string {
	switch exit.kind {
	case .Exited:
		return fmt.tprintf("exit status %d", exit.code)
	case .Signaled:
		return fmt.tprintf("killed by signal %d", exit.code)
	case .Unknown:
	}
	return fmt.tprintf("unrecognized wait status %#x", exit.code)
}

// Fixed-capacity text with explicit truncation; never allocates.
Bounded_Text :: struct($N: int) {
	bytes: [N]u8,
	count: int,
}

bounded_set :: proc(text: ^Bounded_Text($N), value: string) {
	text.count = min(len(value), N)
	copy(text.bytes[:text.count], value)
}

bounded_get :: proc(text: ^Bounded_Text($N)) -> string {
	return string(text.bytes[:text.count])
}

// Keeps the most recent OUTPUT_TAIL_BYTES of a child's output.
Output_Tail :: struct {
	bytes: [OUTPUT_TAIL_BYTES]u8,
	count: int,
}

output_tail_append :: proc(tail: ^Output_Tail, data: []u8) {
	assert(tail.count <= len(tail.bytes))
	if len(data) >= len(tail.bytes) {
		copy(tail.bytes[:], data[len(data) - len(tail.bytes):])
		tail.count = len(tail.bytes)
		return
	}
	overflow := tail.count + len(data) - len(tail.bytes)
	if overflow > 0 {
		copy(tail.bytes[:], tail.bytes[overflow:tail.count])
		tail.count -= overflow
	}
	copy(tail.bytes[tail.count:], data)
	tail.count += len(data)
}

output_tail_text :: proc(tail: ^Output_Tail) -> string {
	return string(tail.bytes[:tail.count])
}

// Last non-empty line, without the trailing newline.
output_tail_last_line :: proc(tail: ^Output_Tail) -> string {
	text := strings.trim_right_space(output_tail_text(tail))
	if index := strings.last_index_byte(text, '\n'); index >= 0 {
		return strings.trim_space(text[index + 1:])
	}
	return strings.trim_space(text)
}

// Reads whatever a nonblocking pipe holds now. Returns false at end of file
// or on a read error; the caller then closes the descriptor.
output_tail_drain :: proc(tail: ^Output_Tail, fd: i32) -> (open: bool) {
	if fd < 0 {
		return false
	}
	chunk: [512]u8
	for _ in 0 ..< OUTPUT_TAIL_BYTES / len(chunk) + 1 {
		n := posix.read(posix.FD(fd), &chunk[0], len(chunk))
		if n > 0 {
			output_tail_append(tail, chunk[:n])
			continue
		}
		if n < 0 && (posix.errno() == .EAGAIN || posix.errno() == .EINTR) {
			return true
		}
		return false
	}
	return true
}

// Payload health
// ------------------------------------------------------------------------

Payload_Health_State :: enum u8 {
	Starting,
	Ready,
	Recovering,
	Failed,
}

Health_Transition :: enum u8 {
	None,
	Failed,
	Recovered,
}

Payload_Health :: struct {
	state: Payload_Health_State,
	failures: u32, // Consecutive failed recovery attempts.
	cause: Bounded_Text(HEALTH_TEXT_BYTES),
	crash_report: Bounded_Text(HEALTH_PATH_BYTES),
	changed_at: time.Time,
}

payload_health_failure :: proc(
	h: ^Payload_Health,
	cause, crash_report: string,
	now: time.Time,
) -> Health_Transition {
	h.failures += 1
	bounded_set(&h.cause, cause)
	bounded_set(&h.crash_report, crash_report)
	if h.failures < PAYLOAD_FAILURE_ESCALATION {
		if h.state != .Failed {h.state = .Recovering}
		return .None
	}
	if h.state == .Failed {
		return .None
	}
	h.state = .Failed
	h.changed_at = now
	return .Failed
}

payload_health_success :: proc(h: ^Payload_Health, now: time.Time) -> Health_Transition {
	previous := h.state
	h.state = .Ready
	h.failures = 0
	h.changed_at = now
	bounded_set(&h.cause, "")
	bounded_set(&h.crash_report, "")
	return previous == .Failed ? .Recovered : .None
}

// Explains a failed load or handshake from evidence, never by assumption.
payload_failure_cause :: proc(action: string, exit: Child_Exit, output: string) -> string {
	lower := strings.to_lower(output, context.temp_allocator)
	if strings.contains(lower, "sudo:") && strings.contains(lower, "password") {
		return fmt.tprintf(
			"%s: sudo requires a password; allow noninteractive sudo for 'shoji --load-sa'",
			action,
		)
	}
	tail: Output_Tail
	output_tail_append(&tail, transmute([]u8)output)
	line := output_tail_last_line(&tail)
	if line == "" {
		return fmt.tprintf("%s: %s", action, child_exit_text(exit))
	}
	return fmt.tprintf("%s: %s (%s)", action, line, child_exit_text(exit))
}

// Newest crash report whose name starts with prefix and that was modified at
// or after since. Scans at most CRASH_REPORT_SCAN_LIMIT entries.
crash_report_newest :: proc(directory, prefix: string, since: time.Time) -> string {
	handle, open_error := os.open(directory)
	if open_error != nil {
		return ""
	}
	defer os.close(handle)
	entries, read_error := os.read_dir(handle, CRASH_REPORT_SCAN_LIMIT, context.temp_allocator)
	if read_error != nil {
		return ""
	}
	best := ""
	best_time := since
	for entry in entries {
		if !strings.has_prefix(entry.name, prefix) || !strings.has_suffix(entry.name, ".ips") {
			continue
		}
		if time.diff(best_time, entry.modification_time) < 0 {
			continue
		}
		best_time = entry.modification_time
		best, _ = filepath.join({directory, entry.name}, context.temp_allocator)
	}
	return best
}

user_crash_report_directory :: proc() -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		return ""
	}
	path, _ := filepath.join({home, "Library/Logs/DiagnosticReports"}, context.temp_allocator)
	return path
}

// Startup configuration failures
// ------------------------------------------------------------------------

Config_Failure :: struct {
	line: i32, // 0 when the shell did not report a line.
	command: Bounded_Text(HEALTH_TEXT_BYTES),
	error: Bounded_Text(HEALTH_TEXT_BYTES),
}

Config_Report :: struct {
	failures: [CONFIG_FAILURE_LIMIT]Config_Failure,
	count: int,
	dropped: int, // Failures beyond CONFIG_FAILURE_LIMIT.
	exit: Child_Exit,
	finished: bool,
	// Parser state: the most recent traced command.
	last_line: i32,
	last_command: Bounded_Text(HEALTH_TEXT_BYTES),
	pending: Bounded_Text(HEALTH_TEXT_BYTES), // Partial output line.
}

// Feeds complete stderr lines from 'sh -x' with PS4=CONFIG_TRACE_PREFIX.
// Trace lines name the command; any other line is attributed to it.
config_report_line :: proc(report: ^Config_Report, line: string) -> (recorded: bool) {
	text := strings.trim_space(line)
	if text == "" {
		return false
	}
	if strings.has_prefix(text, CONFIG_TRACE_PREFIX) {
		rest := text[len(CONFIG_TRACE_PREFIX):]
		colon := strings.index_byte(rest, ':')
		if colon < 0 {
			return false
		}
		number := 0
		for c in rest[:colon] {
			if c < '0' || c > '9' || number > 1_000_000 {number = 0; break}
			number = number * 10 + int(c - '0')
		}
		report.last_line = i32(number)
		bounded_set(&report.last_command, strings.trim_space(rest[colon + 1:]))
		return false
	}
	if strings.has_prefix(text, "+") {
		return false // Nested trace output, for example from functions.
	}
	if report.count >= CONFIG_FAILURE_LIMIT {
		report.dropped += 1
		return true
	}
	failure := &report.failures[report.count]
	failure.line = report.last_line
	bounded_set(&failure.command, bounded_get(&report.last_command))
	bounded_set(&failure.error, text)
	report.count += 1
	return true
}

// Splits arbitrary output chunks into lines with a bounded carry buffer.
config_report_feed :: proc(report: ^Config_Report, data: []u8) -> (new_failures: int) {
	start := 0
	for i in 0 ..< len(data) {
		if data[i] != '\n' {continue}
		piece := string(data[start:i])
		if report.pending.count > 0 {
			joined := strings.concatenate(
				{bounded_get(&report.pending), piece},
				context.temp_allocator,
			)
			bounded_set(&report.pending, "")
			piece = joined
		}
		if config_report_line(report, piece) {new_failures += 1}
		start = i + 1
	}
	if start < len(data) {
		rest := strings.concatenate(
			{bounded_get(&report.pending), string(data[start:])},
			context.temp_allocator,
		)
		bounded_set(&report.pending, rest)
	}
	return
}

config_failure_text :: proc(failure: ^Config_Failure) -> string {
	if failure.line > 0 {
		return fmt.tprintf(
			"shojirc line %d: %s: %s",
			failure.line,
			bounded_get(&failure.command),
			bounded_get(&failure.error),
		)
	}
	return fmt.tprintf("shojirc: %s", bounded_get(&failure.error))
}
