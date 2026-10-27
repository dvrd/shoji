package support

import "core:fmt"
import "core:os"
import "core:strings"
import posix "core:sys/posix"
import "core:time"

// Darwin's opaque spawn objects are pointers; their APIs take pointers to those handles.
foreign import process_system "system:System"
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

start :: proc(
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
