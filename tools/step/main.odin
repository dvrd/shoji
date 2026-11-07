package step

// Build step runner for the Taskfile: one readable line per step.
//
//   bin/step [--show] COMPONENT ACTION DETAIL -- COMMAND [ARGS...]
//
// Runs COMMAND with stdout and stderr captured in a temporary file. On
// success prints one line with the component, action, detail and elapsed
// time; --show also prints the captured output (for steps whose output is the
// point, such as the signing identity). On failure prints the command and its
// full output and exits with its code, so nothing is lost compared to running
// the command directly. Output is captured on disk, so memory stays bounded
// regardless of how much the command prints. Colors only on a terminal, and
// never with NO_COLOR set.

import "core:bytes"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

COMPONENT_WIDTH :: 13
ACTION_WIDTH :: 10
// "  ✓ " occupies four columns before the component.
DETAIL_COLUMN :: 4 + COMPONENT_WIDTH + 1 + ACTION_WIDTH
COPY_CHUNK_BYTES :: 4096
EXIT_USAGE :: 2
EXIT_NOT_EXECUTED :: 127

Style :: struct {
	green, red, dim, bold, reset: string,
}

Step :: struct {
	component, action, detail: string,
	command: []string,
	show: bool,
}

main :: proc() {
	step, ok := parse_arguments(os.args[1:])
	if !ok {
		fmt.eprintln("usage: step [--show] COMPONENT ACTION DETAIL -- COMMAND...")
		os.exit(EXIT_USAGE)
	}
	style := Style{}
	no_color := os.get_env("NO_COLOR", context.temp_allocator) != ""
	if posix.isatty(posix.STDOUT_FILENO) && !no_color {
		style = {"\x1b[32m", "\x1b[31m", "\x1b[2m", "\x1b[1m", "\x1b[0m"}
	}
	template := strings.clone_to_cstring("/tmp/shoji-step.XXXXXX", context.temp_allocator)
	log := posix.mkstemp(template)
	if log < 0 {
		fmt.eprintln("step: cannot create output file")
		os.exit(1)
	}
	// The file is reached only through the descriptor; unlinking at once means
	// no exit path can leave it behind.
	// The process exits right after reporting, which closes the descriptor.
	posix.unlink(template)
	start := time.tick_now()
	code := run_captured(step.command, log)
	elapsed := time.duration_seconds(time.tick_since(start))
	if code == 0 {
		report_success(step, style, elapsed, log)
		os.exit(0)
	}
	report_failure(step, style, elapsed, log)
	os.exit(int(code))
}

parse_arguments :: proc(args: []string) -> (step: Step, ok: bool) {
	rest := args
	if len(rest) > 0 && rest[0] == "--show" {
		step.show = true
		rest = rest[1:]
	}
	if len(rest) < 5 || rest[3] != "--" {
		return {}, false
	}
	step.component, step.action, step.detail = rest[0], rest[1], rest[2]
	step.command = rest[4:]
	return step, true
}

// Returns the command's exit code, 128 + signal when it was killed, and
// EXIT_NOT_EXECUTED when it could not be started.
run_captured :: proc(command: []string, log: posix.FD) -> i32 {
	assert(len(command) > 0)
	argv := make([]cstring, len(command) + 1, context.temp_allocator)
	for argument, i in command {
		argv[i] = strings.clone_to_cstring(argument, context.temp_allocator)
	}
	pid := posix.fork()
	if pid < 0 {
		fmt.eprintln("step: fork failed")
		return EXIT_NOT_EXECUTED
	}
	if pid == 0 {
		posix.dup2(log, posix.STDOUT_FILENO)
		posix.dup2(log, posix.STDERR_FILENO)
		posix.execvp(argv[0], raw_data(argv))
		fmt.eprintf("step: cannot execute %s: %s\n", command[0], posix.strerror())
		posix._exit(EXIT_NOT_EXECUTED)
	}
	status: i32
	for posix.waitpid(pid, &status, {}) < 0 {
		if posix.errno() != .EINTR {
			fmt.eprintln("step: waitpid failed")
			return EXIT_NOT_EXECUTED
		}
	}
	if posix.WIFEXITED(status) {
		return posix.WEXITSTATUS(status)
	}
	return 128 + i32(posix.WTERMSIG(status))
}

step_heading :: proc(step: Step) -> string {
	return fmt.tprintf(
		"%-*s %-*s",
		COMPONENT_WIDTH,
		step.component,
		ACTION_WIDTH,
		step.action,
	)
}

report_success :: proc(step: Step, style: Style, elapsed: f64, log: posix.FD) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "  %s✓%s ", style.green, style.reset)
	fmt.sbprintf(&b, "%s%s%s", style.bold, step_heading(step), style.reset)
	fmt.sbprintf(&b, "%s%s  %.1fs%s\n", style.dim, step.detail, elapsed, style.reset)
	// Parallel tasks share the terminal: the step line is one write.
	write_all(posix.STDOUT_FILENO, strings.to_string(b))
	if step.show {
		indent := fmt.tprintf("%*s%s", DETAIL_COLUMN, "", style.dim)
		copy_output(log, posix.STDOUT_FILENO, indent, style.reset)
	}
}

report_failure :: proc(step: Step, style: Style, elapsed: f64, log: posix.FD) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "  %s✗ %s", style.red, step_heading(step))
	fmt.sbprintf(&b, "%s  %.1fs%s\n", step.detail, elapsed, style.reset)
	fmt.sbprintf(&b, "    %s$", style.dim)
	for argument in step.command {
		quoted := strings.contains_any(argument, " \"'$\\") || argument == ""
		fmt.sbprintf(&b, quoted ? " '%s'" : " %s", argument)
	}
	fmt.sbprintf(&b, "%s\n", style.reset)
	write_all(posix.STDERR_FILENO, strings.to_string(b))
	copy_output(log, posix.STDERR_FILENO, "    ", "")
}

// Streams the captured output in fixed chunks, decorating each line.
copy_output :: proc(log, out: posix.FD, prefix, suffix: string) {
	if posix.lseek(log, 0, .SET) < 0 {
		return
	}
	chunk: [COPY_CHUNK_BYTES]u8
	at_line_start := true
	for {
		n := posix.read(log, &chunk[0], len(chunk))
		if n < 0 && posix.errno() == .EINTR {continue}
		if n <= 0 {break}
		data := chunk[:n]
		for len(data) > 0 {
			if at_line_start {write_all(out, prefix)}
			end := bytes.index_byte(data, '\n')
			if end < 0 {
				write_all(out, string(data))
				at_line_start = false
				break
			}
			write_all(out, string(data[:end]))
			write_all(out, suffix)
			write_all(out, "\n")
			data = data[end + 1:]
			at_line_start = true
		}
	}
	if !at_line_start {
		write_all(out, suffix)
		write_all(out, "\n")
	}
}

write_all :: proc(out: posix.FD, text: string) {
	data := transmute([]u8)text
	for len(data) > 0 {
		n := posix.write(out, raw_data(data), uint(len(data)))
		if n < 0 && posix.errno() == .EINTR {continue}
		if n <= 0 {return}
		data = data[n:]
	}
}
