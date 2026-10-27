package dockscan

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:time"

Progress :: struct {
	interactive, drawn: bool,
	label, detail, last_label, file, log_path: string,
	started: time.Tick,
	frame: int,
	log: ^os.File,
	output: ^os.File,
}
Window_Size :: struct {
	rows, columns, x_pixels, y_pixels: u16,
}
foreign import progress_libc "system:c"
foreign progress_libc {
	@(link_name = "ioctl")
	progress_ioctl :: proc(fd: i32, request: uintptr, data: ^Window_Size) -> i32 ---
}
progress_open :: proc(work: string, enabled: bool) -> (Progress, string) {
	path := join(work, "acquisition.log")
	log, err := os.open(
		path,
		{.Read, .Write, .Create, .Append},
		os.perm(0o600),
	)
	if err != nil {
		return {}, fmt.tprintf("cannot open acquisition log: %v", err)
	}
	terminal := os.get_env("TERM", context.allocator)
	return Progress {
			interactive = enabled && posix.isatty(2) && terminal != "dumb",
			log = log,
			output = os.stderr,
			log_path = path,
			started = time.tick_now(),
		},
		""
}
progress_clear :: proc(p: ^Progress) {
	if p == nil || !p.drawn {
		return
	}
	fmt.fprint(p.output, "\r\x1b[2K")
	p.drawn = false
}
progress_close :: proc(p: ^Progress) {
	progress_clear(p)
	if p != nil && p.log != nil {
		_ = os.close(p.log); p.log = nil
	}
}
progress_stage :: proc(p: ^Progress, label: string, detail: string = "") {
	if p == nil {
		return
	}
	if p.label != label {
		p.started = time.tick_now(); p.frame = 0
	}
	p.label = label; p.detail = detail
	if !p.interactive && p.last_label != label {
		fmt.fprintln(p.output, label)
	}
	p.last_label = label
}
// ASCII frames and width-limited text avoid wrapping when the terminal is narrow.
// No cursor hiding or terminal mode changes need recovery after interruption.
progress_line :: proc(
	label, detail: string,
	frame, elapsed: int,
	bytes: i64,
	width: int,
	allocator := context.allocator,
) -> string {
	frames := [4]string{"|", "/", "-", "\\"}
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "%s %s", frames[frame % 4], label)
	if detail != "" {
		fmt.sbprintf(&b, " (%s)", detail)
	}
	if bytes >= 0 {
		if bytes >= 1024 * 1024 * 1024 {
			fmt.sbprintf(&b, "  %.2f GiB", f64(bytes) / (1024 * 1024 * 1024))
		} else {
			fmt.sbprintf(&b, "  %.1f MiB", f64(bytes) / (1024 * 1024))
		}
	}
	fmt.sbprintf(&b, "  %d:%02d", elapsed / 60, elapsed % 60)
	s := strings.to_string(b); limit := max(0, width - 1)
	if len(s) > limit {
		return s[:limit]
	}
	return s
}
progress_draw :: proc(p: ^Progress) {
	if p == nil || !p.interactive {
		return
	}
	// Each frame uses bounded stack storage and never changes the caller's allocators.
	buffer: [8192]u8
	scratch: mem.Arena
	mem.arena_init(&scratch, buffer[:])
	allocator := mem.arena_allocator(&scratch)
	columns := 80
	size: Window_Size
	if p.output == os.stderr &&
	   progress_ioctl(2, 0x40087468, &size) == 0 &&
	   size.columns > 0 {
		columns = int(size.columns)
	}
	bytes: i64 = -1
	if p.file != "" {
		if info, err := os.stat(p.file, allocator); err == nil {
			bytes = info.size
		}
	}
	line := progress_line(
		p.label,
		p.detail,
		p.frame,
		int(time.tick_since(p.started) / time.Second),
		bytes,
		columns,
		allocator,
	)
	fmt.fprintf(p.output, "\r\x1b[2K%s", line)
	p.frame += 1; p.drawn = true
}
log_tail :: proc(log: ^os.File) -> string {
	end, err := os.seek(log, 0, .End); if err != nil {
		return ""
	}
	_, _ = os.seek(log, max(i64(0), end - 4096), .Start)
	b := make([]u8, min(i64(4096), end))
	n, read_error := os.read(log, b)
	_, _ = os.seek(log, 0, .End)
	if read_error != nil {
		return ""
	}
	return strings.trim_space(string(b[:n]))
}
// Redirect subprocess output to files so verbose extraction cannot flood the
// terminal or fill a pipe while the parent polls and renders progress.
run_progress :: proc(
	args: []string,
	p: ^Progress,
	capture: bool = true,
) -> (
	string,
	string,
) {
	if p == nil {
		return run(args)
	}
	fmt.fprintf(p.log, "command: %q\n", args)
	output, err := os.create_temp_file(
		filepath.dir(p.log_path),
		"command-output-*",
	)
	if err != nil {
		return "", fmt.tprintf("cannot create progress output: %v", err)
	}
	defer os.close(output)
	defer os.remove(os.name(output))
	destination := output
	if !capture {
		destination = p.log
	}
	child, start_error := os.process_start(
		os.Process_Desc{command = args, stdout = destination, stderr = p.log},
	)
	if start_error != nil {
		return "", fmt.tprintf("cannot start %s: %v", args[0], start_error)
	}
	defer progress_clear(p)
	state: os.Process_State
	for {
		wait_error: os.Error
		state, wait_error = os.process_wait(
			child,
			p.interactive ? 0 : os.TIMEOUT_INFINITE,
		)
		if wait_error == .Timeout {
			progress_draw(p)
			time.sleep(100 * time.Millisecond)
			continue
		}
		if wait_error != nil {
			_ = os.process_kill(child); _, _ = os.process_wait(child)
			return "", fmt.tprintf(
				"cannot wait for %s: %v",
				args[0],
				wait_error,
			)
		}
		break
	}
	if !state.success {
		return "", fmt.tprintf(
			"%s failed (%d); details: %s\n%s",
			args[0],
			state.exit_code,
			p.log_path,
			log_tail(p.log),
		)
	}
	if !capture {
		return "", ""
	}
	_, _ = os.seek(output, 0, .Start)
	bytes, read_error := os.read_entire_file(output, context.allocator)
	if read_error != nil {
		return "", fmt.tprintf("cannot read command output: %v", read_error)
	}
	return string(bytes), ""
}
