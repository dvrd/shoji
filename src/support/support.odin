package support

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import posix "core:sys/posix"
import "core:time"

foreign import process_system "system:System"

// Filesystem, options and serialization
// ------------------------------------------------------------------------

interrupt_requested: i32
cleanup_depth: int

// CLI entry points install these handlers; the daemon owns its signals.
configure_signals :: proc() {
	posix.signal(.SIGINT, interrupt_handler)
	posix.signal(.SIGTERM, interrupt_handler)
}
interrupt_handler :: proc "c" (_: posix.Signal) {
	sync.atomic_store(&interrupt_requested, 1)
}
interrupted :: proc() -> bool {
	return sync.atomic_load(&interrupt_requested) != 0
}
cancelled :: proc() -> bool { return interrupted() && cleanup_depth == 0 }
begin_cleanup :: proc() { cleanup_depth += 1 }
end_cleanup :: proc() { cleanup_depth -= 1 }

Request :: struct {
	args: []string,
	dir, input: string,
	timeout: time.Duration,
	env: []string,
}
Result :: struct {
	code: int,
	out, diagnostic: string,
	timed_out: bool,
}
Executor :: struct {
	user: rawptr,
	execute: proc(_: rawptr, _: Request) -> Result,
}
process_run :: proc(
	e: Executor,
	args: []string,
	dir: string = "",
	input: string = "",
	timeout: time.Duration = 30 * time.Second,
	env: []string = nil,
) -> Result {
	if cancelled() {
		return {130, "", "interrupted", false}
	}
	r := Request{args, dir, input, timeout, env}
	if e.execute != nil {
		return e.execute(e.user, r)
	}
	stage, err := os.make_directory_temp(
		"",
		"shoji-command-*",
		context.allocator,
	)
	if err != nil {
		return {-1, "", fmt.tprintf("temporary directory: %v", err), false}
	}
	defer os.remove_all(stage)
	_ = os.chmod(stage, {.Read_User, .Write_User, .Execute_User})
	outpath, errpath, inpath :=
		join(stage, "stdout"), join(stage, "stderr"), join(stage, "stdin")
	if err := os.write_entire_file(inpath, input); err != nil {
		return {-1, "", fmt.tprintf("command input: %v", err), false}
	}
	out, a := os.create(outpath); if a != nil {
		return {-1, "", fmt.tprintf("stdout: %v", a), false}
	}; defer os.close(out)
	stderr, b := os.create(errpath); if b != nil {
		return {-1, "", fmt.tprintf("stderr: %v", b), false}
	}; defer os.close(stderr)
	stdin, c := os.open(inpath); if c != nil {
		return {-1, "", fmt.tprintf("stdin: %v", c), false}
	}; defer os.close(stdin)
	child, group, start_error := process_start(
		{
			command = args,
			working_dir = dir,
			env = env,
			stdout = out,
			stderr = stderr,
			stdin = stdin,
		},
		command = true,
	)
	if start_error != nil {
		return {
			-1,
			"",
			fmt.tprintf("cannot start %s: %v", args[0], start_error),
			false,
		}
	}
	began := time.tick_now()
	state: os.Process_State
	wait: os.Error
	for {
		remaining := timeout - time.tick_since(began)
		state, wait = os.process_wait(
			child,
			clamp(remaining, 0, 100 * time.Millisecond),
		)
		if wait != .Timeout || remaining <= 0 || cancelled() {
			break
		}
	}
	timed := wait == .Timeout
	cleanup_error := stop_tree(child, group, wait == nil)
	output, output_error := os.read_entire_file(outpath, context.allocator)
	diagnostic, diagnostic_error := os.read_entire_file(
		errpath,
		context.allocator,
	)
	if output_error != nil || diagnostic_error != nil {
		return {
			-1,
			"",
			fmt.tprintf(
				"command evidence read: %v / %v; cleanup: %s",
				output_error,
				diagnostic_error,
				cleanup_error,
			),
			timed,
		}
	}
	code := int(state.exit_code)
	if wait != nil {
		code = -1
		diagnostic = transmute([]u8)fmt.tprintf(
			"%s\n%s: %v",
			string(diagnostic),
			args[0],
			wait,
		)
	}
	if cancelled() {
		return {
			130,
			string(output),
			cleanup_error == "" \
				? "interrupted" \
				: cat("interrupted; cleanup: ", cleanup_error),
			false,
		}
	}
	if cleanup_error != "" {
		return {
			-1,
			string(output),
			cat(string(diagnostic), "; ", cleanup_error),
			timed,
		}
	}
	return {code, string(output), string(diagnostic), timed}
}
checked :: proc(
	e: Executor,
	args: []string,
	dir: string = "",
	input: string = "",
	timeout: time.Duration = 30 * time.Second,
	env: []string = nil,
) -> (
	string,
	string,
) {
	r := process_run(e, args, dir, input, timeout, env)
	if r.code != 0 {
		return r.out, fmt.tprintf(
			"%s failed (%d): %s",
			args[0],
			r.code,
			r.diagnostic == "" ? r.out : r.diagnostic,
		)
	}
	return r.out, ""
}
join :: proc(a, b: string) -> string {
	p, _ := filepath.join([]string{a, b}); return p
}
abs :: proc(path: string) -> string {
	value := expand(path); if !filepath.is_abs(value) {
		cwd, _ := os.get_working_directory(context.allocator)
		value = join(cwd, value)
	}; clean, _ := filepath.clean(value); return clean
}
expand :: proc(path: string) -> string {
	if path == "~" {
		return home()
	}; if strings.has_prefix(path, "~/") {
		return join(home(), path[2:])
	}; return path
}
home :: proc() -> string { return os.get_env("HOME", context.allocator) }
kind :: proc(path: string) -> os.File_Type {
	f, err := os.lstat(path, context.allocator)
	return err == nil ? f.type : .Undetermined
}
regular :: proc(path: string) -> bool { return kind(path) == .Regular }
exists :: proc(path: string) -> bool { return kind(path) != .Undetermined }
mkdir :: proc(path: string) -> string {
	err := os.make_directory_all(path); if err != nil && err != .Exist {
		return fmt.tprintf("cannot create %s: %v", path, err)
	}; return ""
}
write :: proc(path, text: string) -> string {
	err := os.write_entire_file(path, text)
	return err == nil ? "" : fmt.tprintf("cannot write %s: %v", path, err)
}
read :: proc(path: string) -> (string, string) {
	b, err := os.read_entire_file(path, context.allocator)
	return string(b),
		err == nil ? "" : fmt.tprintf("cannot read %s: %v", path, err)
}
read_json :: proc(path: string, v: ^$T) -> string {
	b, err := os.read_entire_file(path, context.allocator); if err != nil {
		return fmt.tprintf("cannot read %s: %v", path, err)
	}; j := json.unmarshal(b, v)
	return j == nil ? "" : fmt.tprintf("invalid JSON %s: %v", path, j)
}
write_json :: proc(path: string, value: any) -> string {
	b, err := json.marshal(value, {pretty = true}); if err != nil {
		return fmt.tprintf("JSON: %v", err)
	}; return write(path, cat(string(b), "\n"))
}
atomic_write :: proc(path, text: string) -> string {
	if kind(path) == .Symlink {
		return "refusing to replace a symlink"
	}
	parent := filepath.dir(path); if err := mkdir(parent); err != "" {
		return err
	}
	f, err := os.create_temp_file(parent, ".shoji-*"); if err != nil {
		return fmt.tprintf("temporary file: %v", err)
	}
	name := strings.clone(os.name(f)); defer os.remove(name)
	_ = os.fchmod(f, {.Read_User, .Write_User})
	_, werr := os.write(f, transmute([]u8)text); ferr := os.flush(f)
	os.close(f)
	if werr != nil || ferr != nil {
		return "cannot flush atomic file"
	}
	if err := os.rename(name, path); err != nil {
		return fmt.tprintf("cannot install %s: %v", path, err)
	}
	return ""
}
copy_file :: proc(dst, src: string) -> string {
	if kind(dst) == .Symlink {
		return "refusing to replace a symlink"
	}; err := os.copy_file(dst, src)
	return err == nil ? "" : fmt.tprintf("cannot copy %s: %v", src, err)
}
temp :: proc(prefix: string) -> (string, string) {
	p, err := os.make_directory_temp("", cat(prefix, "-*"), context.allocator)
	return p, err == nil ? "" : fmt.tprintf("temporary directory: %v", err)
}
trim :: proc(s: string) -> string { return strings.trim_space(s) }
hexadecimal :: proc(s: string, n: int) -> bool {
	if len(s) != n {
		return false
	}; for c in s {
		if !(c >= '0' && c <= '9' ||
			   c >= 'a' && c <= 'f' ||
			   c >= 'A' && c <= 'F') {
			return false
		}
	}; return true
}
safe_name :: proc(s: string) -> bool {
	if len(s) == 0 ||
	   !(s[0] >= '0' && s[0] <= '9' ||
			   s[0] >= 'A' && s[0] <= 'Z' ||
			   s[0] >= 'a' && s[0] <= 'z') {
		return false
	}; for c in s {
		if !(c >= '0' && c <= '9' ||
			   c >= 'A' && c <= 'Z' ||
			   c >= 'a' && c <= 'z' ||
			   c == '.' ||
			   c == '_' ||
			   c == '-') {
			return false
		}
	}; return true
}
Options :: struct {
	values: map[string]string,
	flags: map[string]bool,
	positionals: [dynamic]string,
}
parse :: proc(args: []string, values, flags: []string) -> (Options, string) {
	o := Options {
		values = make(map[string]string),
		flags  = make(map[string]bool),
	}
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		if !strings.has_prefix(arg, "--") {
			append(&o.positionals, arg); continue
		}
		key := arg[2:]; value := ""; inline := false
		if at := strings.index(key, "="); at >= 0 {
			value, key, inline = key[at + 1:], key[:at], true
		}
		is_flag, is_value := false, false
		for v in flags {
			if v == key {
				is_flag = true
			}
		}
		for v in values {
			if v == key {
				is_value = true
			}
		}
		if is_flag && !inline {
			o.flags[key] = true; continue
		}
		if !is_value {
			return o, fmt.tprintf("unknown option %s", arg)
		}
		if !inline {
			i += 1; if i >= len(args) {
				return o, fmt.tprintf("%s requires a value", arg)
			}; value = args[i]
		}
		if value == "" {
			return o, fmt.tprintf("%s requires a nonempty value", arg)
		}
		if _, duplicate := o.values[key]; duplicate {
			return o, fmt.tprintf("duplicate option --%s", key)
		}
		o.values[key] = value
	}
	return o, ""
}
get :: proc(o: Options, key: string, default_value: string = "") -> string {
	v, ok := o.values[key]; return ok ? v : default_value
}
environment :: proc(key, value: string, base: []string = nil) -> []string {
	old := base
	if old == nil {
		old, _ = os.environ(context.allocator)
	}
	result := make([dynamic]string)
	for item in old {
		if !strings.has_prefix(item, cat(key, "=")) {
			append(&result, item)
		}
	}; append(&result, cat(key, "=", value)); return result[:]
}
cat :: proc(parts: ..string) -> string { return strings.concatenate(parts) }
real :: proc(path: string) -> string {
	buf: [4096]u8
	p := posix.realpath(
		strings.clone_to_cstring(expand(path)),
		raw_data(buf[:]),
	); if p == nil {
		return ""
	}; return strings.clone(string(p))
}
clone_args :: proc(args: []string) -> []string {
	copy_args := make([]string, len(args))
	for arg, i in args { copy_args[i] = strings.clone(arg) }; return copy_args
}

// Process execution and cancellation
// ------------------------------------------------------------------------

// Darwin's opaque spawn objects are pointers; their APIs take pointers to those handles.
@(default_calling_convention = "c")
foreign process_system {
	posix_spawnattr_init :: proc(attr: ^rawptr) -> posix.Errno ---
	posix_spawnattr_destroy :: proc(attr: ^rawptr) -> posix.Errno ---
	posix_spawnattr_setflags :: proc(attr: ^rawptr, flags: i16) -> posix.Errno ---
	posix_spawnattr_setpgroup :: proc(attr: ^rawptr, group: posix.pid_t) -> posix.Errno ---
	posix_spawnattr_setsigdefault :: proc(attr: ^rawptr, signals: ^posix.sigset_t) -> posix.Errno ---
	posix_spawnattr_setsigmask :: proc(attr: ^rawptr, signals: ^posix.sigset_t) -> posix.Errno ---
	posix_spawn_file_actions_init :: proc(actions: ^rawptr) -> posix.Errno ---
	posix_spawn_file_actions_destroy :: proc(actions: ^rawptr) -> posix.Errno ---
	posix_spawn_file_actions_adddup2 :: proc(actions: ^rawptr, from, to: i32) -> posix.Errno ---
	posix_spawn_file_actions_addopen :: proc(actions: ^rawptr, fd: i32, path: cstring, flags: i32, mode: u16) -> posix.Errno ---
	// This spelling supports our macOS 15 target; the replacement requires macOS 26.
	posix_spawn_file_actions_addchdir_np :: proc(actions: ^rawptr, path: cstring) -> posix.Errno ---
}

COMMAND_GROUP_ENV :: "_SHOJI_OWNED_COMMAND_GROUP"

process_start :: proc(
	desc: os.Process_Desc,
	command: bool = false,
) -> (
	os.Process,
	posix.pid_t,
	os.Error,
) {
	if len(desc.command) == 0 {
		return {}, 0, .Invalid_Path
	}
	attr, actions: rawptr
	if err := posix_spawnattr_init(&attr); err != nil {
		return {}, 0, err
	}
	defer posix_spawnattr_destroy(&attr)
	if err := posix_spawn_file_actions_init(&actions); err != nil {
		return {}, 0, err
	}
	defer posix_spawn_file_actions_destroy(&actions)
	// Nested development commands stay in the top-level command's group. Otherwise
	// an interrupted Task could kill its wrapper while leaving a compiler in a new group.
	isolated := os.get_env(COMMAND_GROUP_ENV, context.allocator) != "1"
	flags: i16 = 0x4000 | 0x0004 | 0x0008 // CLOEXEC_DEFAULT, SETSIGDEF, SETSIGMASK
	if isolated {
		flags |= 0x0002 // SETPGROUP: group 0 gives the child its own PID as PGID.
		if err := posix_spawnattr_setpgroup(&attr, 0); err != nil {
			return {}, 0, err
		}
	}
	if err := posix_spawnattr_setflags(&attr, flags); err != nil {
		return {}, 0, err
	}
	defaults, mask: posix.sigset_t
	posix.sigemptyset(&defaults); posix.sigemptyset(&mask)
	for signal in ([]posix.Signal {
			.SIGINT,
			.SIGTERM,
			.SIGHUP,
			.SIGQUIT,
			.SIGPIPE,
		}) { _ = posix.sigaddset(&defaults, signal) }
	if err := posix_spawnattr_setsigdefault(&attr, &defaults); err != nil {
		return {}, 0, err
	}
	if err := posix_spawnattr_setsigmask(&attr, &mask); err != nil {
		return {}, 0, err
	}
	for file, fd in ([3]^os.File{desc.stdin, desc.stdout, desc.stderr}) {
		err: posix.Errno
		if file == nil {
			err = posix_spawn_file_actions_addopen(
				&actions,
				i32(fd),
				"/dev/null",
				fd == 0 ? 0 : 1,
				0,
			)
		} else {
			err = posix_spawn_file_actions_adddup2(
				&actions,
				i32(os.fd(file)),
				i32(fd),
			)
		}
		if err != nil {
			return {}, 0, err
		}
	}
	if desc.working_dir != "" {
		if err := posix_spawn_file_actions_addchdir_np(
			&actions,
			strings.clone_to_cstring(desc.working_dir),
		); err != nil {
			return {}, 0, err
		}
	}
	argv := make([]cstring, len(desc.command) + 1)
	for arg, i in desc.command { argv[i] = strings.clone_to_cstring(arg) }
	env := environment(
		COMMAND_GROUP_ENV,
		command || !isolated ? "1" : "",
		desc.env,
	)
	envp := make([]cstring, len(env) + 1)
	for item, i in env { envp[i] = strings.clone_to_cstring(item) }
	pid: posix.pid_t
	if err := posix.posix_spawnp(
		&pid,
		argv[0],
		&actions,
		&attr,
		raw_data(argv),
		raw_data(envp),
	); err != nil {
		return {}, 0, err
	}
	child, err := os.process_open(int(pid))
	group := isolated ? pid : posix.pid_t(0)
	if err != nil {
		_ = posix.kill(group > 1 ? -group : pid, .SIGKILL)
		status: i32; _ = posix.waitpid(pid, &status, {})
	}
	return child, group, err
}

// Only a group returned by start may be signalled. Never signal the caller's
// group or discover targets by executable name. Reap the direct child and allow
// shells to reap their own children before escalating the remaining group.
stop_tree :: proc(
	child: os.Process,
	group: posix.pid_t,
	reaped: bool = false,
) -> string {
	if group > 1 {
		_ = posix.kill(-group, .SIGTERM)
	} else if !reaped {
		_ = os.process_terminate(child)
	}
	reaped := reaped
	began := time.tick_now()
	for {
		if !reaped {
			_, err := os.process_wait(child, 0)
			if err == nil {
				reaped = true
			} else if err != .Timeout {
				return fmt.tprintf(
					"cannot reap owned process %d: %v",
					child.pid,
					err,
				)
			}
		}
		alive := group > 1 && posix.kill(-group, posix.Signal(0)) == nil
		if reaped && !alive {
			return ""
		}
		if time.tick_since(began) >= 500 * time.Millisecond {
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	if group > 1 {
		_ = posix.kill(-group, .SIGKILL)
	}
	if !reaped {
		_ = os.process_kill(child)
		if _, err := os.process_wait(child, 3 * time.Second); err != nil {
			return fmt.tprintf(
				"cannot reap owned process %d: %v",
				child.pid,
				err,
			)
		}
	}
	return ""
}
