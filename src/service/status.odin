package service

// `shoji service status`: a compact summary of what launchd knows about the
// process and what the daemon knows about its features. Parsing and rendering
// are pure so they can be tested; `--verbose` keeps the raw launchd dump.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import posix "core:sys/posix"
import health "../health"
import ipc "../ipc"

STATUS_LABEL_WIDTH :: 9

Launchd_Status :: struct {
	state: string,
	pid: string,
	runs: string,
	last_exit: string,
	program: string,
	config: string,
	stderr_path: string,
}

Status_Style :: struct {
	color: bool,
	home: string,
}

// Reads top-level `key = value` lines and the `-c` argument of the launchd
// dump. Unknown keys are ignored, so new launchd fields do not break it.
launchd_status_parse :: proc(text: string) -> Launchd_Status {
	s: Launchd_Status
	in_arguments, want_config := false, false
	for line in strings.split_lines(text, context.temp_allocator) {
		trimmed := strings.trim_space(line)
		if in_arguments {
			if trimmed == "}" {in_arguments = false; continue}
			if want_config {s.config = trimmed}
			want_config = trimmed == "-c"
			continue
		}
		if !strings.has_prefix(line, "\t") || strings.has_prefix(line, "\t\t") {continue}
		at := strings.index(trimmed, " = ")
		if at < 0 {continue}
		key, value := trimmed[:at], trimmed[at + 3:]
		switch key {
		case "state":
			s.state = value
		case "pid":
			s.pid = value
		case "runs":
			s.runs = value
		case "last exit code":
			s.last_exit = value
		case "program":
			s.program = value
		case "stderr path":
			s.stderr_path = value
		case "arguments":
			in_arguments = true
		}
	}
	return s
}

paint :: proc(style: Status_Style, code, text: string) -> string {
	if !style.color {return text}
	return fmt.tprintf("\x1b[%sm%s\x1b[0m", code, text)
}

GREEN :: "32"
YELLOW :: "33"
RED :: "31"
DIM :: "2"
BOLD :: "1"

// Shortens the home prefix and the app bundle's inner executable path.
status_path :: proc(style: Status_Style, path: string) -> string {
	p := path
	if at := strings.index(p, ".app/Contents/MacOS/"); at >= 0 {p = p[:at + 4]}
	if style.home != "" && strings.has_prefix(p, style.home) {
		p = fmt.tprintf("~%s", p[len(style.home):])
	}
	return p
}

status_row :: proc(b: ^strings.Builder, style: Status_Style, label, value: string) {
	padded := fmt.tprintf("%-*s", STATUS_LABEL_WIDTH, label)
	fmt.sbprintf(b, "  %s %s\n", paint(style, DIM, padded), value)
}

status_detail :: proc(b: ^strings.Builder, style: Status_Style, text: string) {
	fmt.sbprintf(b, "  %*s %s\n", STATUS_LABEL_WIDTH, "", paint(style, DIM, text))
}

status_render_header :: proc(b: ^strings.Builder, style: Status_Style, l: Launchd_Status) {
	state := l.state == "" ? "unknown" : l.state
	mark := paint(style, l.state == "running" ? GREEN : RED, fmt.tprintf("● %s", state))
	fmt.sbprintf(b, "%s  %s", paint(style, BOLD, "Shoji"), mark)
	facts := make([dynamic]string, context.temp_allocator)
	if l.pid != "" {append(&facts, fmt.tprintf("pid %s", l.pid))}
	if l.runs != "" {append(&facts, fmt.tprintf("runs %s", l.runs))}
	if l.last_exit != "" && l.last_exit != "0" && l.last_exit != "(never exited)" {
		append(&facts, paint(style, YELLOW, fmt.tprintf("last exit %s", l.last_exit)))
	}
	if len(facts) > 0 {
		joined := strings.join(facts[:], " · ", context.temp_allocator)
		fmt.sbprintf(b, "  %s", paint(style, DIM, joined))
	}
	strings.write_byte(b, '\n')
	if l.program != "" {status_row(b, style, "app", status_path(style, l.program))}
}

status_render_config :: proc(
	b: ^strings.Builder,
	style: Status_Style,
	path: string,
	h: health.Health_JSON,
) {
	where_ := path == "" ? "(none)" : status_path(style, path)
	count := len(h.config_failures) + h.config_failures_dropped
	verdict: string
	switch {
	case !h.config_finished:
		verdict = paint(style, YELLOW, "… running")
	case count > 0:
		text := fmt.tprintf("✗ %d error%s · %s", count, count == 1 ? "" : "s", h.config_exit)
		verdict = paint(style, RED, text)
	case h.config_exit != "exit status 0":
		verdict = paint(style, RED, fmt.tprintf("✗ %s", h.config_exit))
	case:
		verdict = paint(style, GREEN, "✓ ok")
	}
	status_row(b, style, "config", fmt.tprintf("%s  %s", where_, verdict))
	for f in h.config_failures {
		status_detail(b, style, fmt.tprintf("line %d: %s → %s", f.line, f.command, f.error))
	}
	if h.config_failures_dropped > 0 {
		status_detail(b, style, fmt.tprintf("+%d more", h.config_failures_dropped))
	}
}

status_render_health :: proc(b: ^strings.Builder, style: Status_Style, h: health.Health_JSON) {
	code := DIM
	switch h.payload {
	case "ready":
		code = GREEN
	case "starting", "recovering":
		code = YELLOW
	case "failed":
		code = RED
	}
	dock := paint(style, code, fmt.tprintf("● %s", h.payload))
	if h.payload_failures > 0 {
		failures := fmt.tprintf("%d failures", h.payload_failures)
		dock = fmt.tprintf("%s  %s", dock, paint(style, DIM, failures))
	}
	status_row(b, style, "dock", dock)
	if h.payload_cause != "" {status_detail(b, style, h.payload_cause)}
	if h.crash_report != "" {status_detail(b, style, fmt.tprintf("crash: %s", h.crash_report))}
	code = h.notifications == "allowed" ? GREEN : YELLOW
	if h.notifications == "denied" {code = RED}
	notify_text := paint(style, code, fmt.tprintf("● %s", h.notifications))
	if h.notifications_suppressed > 0 {
		suppressed := fmt.tprintf("%d suppressed", h.notifications_suppressed)
		notify_text = fmt.tprintf("%s  %s", notify_text, paint(style, DIM, suppressed))
	}
	status_row(b, style, "notify", notify_text)
	if h.gate != "" && h.gate != "off" {
		code = DIM
		switch h.gate {
		case "serving":
			code = GREEN
		case "waiting", "attaching":
			code = YELLOW
		case "failed":
			code = RED
		}
		status_row(b, style, "gate", paint(style, code, fmt.tprintf("● %s", h.gate)))
		if h.gate_cause != "" {status_detail(b, style, h.gate_cause)}
	}
}

// `health_error` is set when the daemon could not answer; the launchd part
// is still shown so a crashed or stopped daemon remains diagnosable.
status_render :: proc(
	b: ^strings.Builder,
	style: Status_Style,
	l: Launchd_Status,
	h: health.Health_JSON,
	health_error: string,
) {
	status_render_header(b, style, l)
	if health_error != "" {
		status_row(b, style, "health", paint(style, RED, fmt.tprintf("✗ %s", health_error)))
	} else {
		status_render_config(b, style, l.config, h)
		status_render_health(b, style, h)
	}
	if l.stderr_path != "" {status_row(b, style, "log", status_path(style, l.stderr_path))}
}

service_status :: proc(m: Service_Manager, verbose: bool) -> int {
	r := launch(m, "print", target(m))
	no_color := os.get_env("NO_COLOR", context.temp_allocator) != ""
	color := isatty(i32(posix.STDOUT_FILENO)) != 0 && !no_color
	style := Status_Style{color, m.home}
	if r.code != 0 {
		fmt.printf("%s  %s\n", paint(style, BOLD, "Shoji"), paint(style, RED, "○ not loaded"))
		fmt.println(paint(style, DIM, "  start it with: shoji service start"))
		return r.code
	}
	if verbose {fmt.print(r.out, r.diagnostic)}
	l := launchd_status_parse(r.out)
	h: health.Health_JSON
	health_error := ""
	reply := strings.builder_make(context.temp_allocator)
	failed, err := ipc.client_exchange([]string{"query", "--health"}, &reply)
	switch {
	case err != "":
		health_error = err
	case failed:
		health_error = strings.trim_space(strings.to_string(reply))
	case json.unmarshal_string(
			strings.to_string(reply),
			&h,
			allocator = context.temp_allocator,
		) != nil:
		health_error = "unreadable health report"
	}
	out := strings.builder_make(context.temp_allocator)
	status_render(&out, style, l, h, health_error)
	fmt.print(strings.to_string(out))
	return health_error == "" ? 0 : 1
}
