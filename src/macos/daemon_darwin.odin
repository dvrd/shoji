package macos

import e "../engine"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import posix "core:sys/posix"
import "core:time"

foreign import libc "system:c"
@(default_calling_convention = "c")
foreign libc {
	_NSGetEnviron :: proc() -> ^[^]cstring ---
}
stop_requested: i32
stop_handler :: proc "c" (signal: posix.Signal) {
	sync.atomic_store(&stop_requested, 1)
}

run_config :: proc(path: string) {
	if path == "" {
		return
	}
	// The path is passed as argv, never interpolated into shell source.
	argv := [3]cstring{"/bin/sh", strings.clone_to_cstring(path, context.temp_allocator), nil}
	pid: posix.pid_t
	if posix.posix_spawn(&pid, "/bin/sh", nil, nil, &argv[0], _NSGetEnviron()^) != nil {
		fmt.eprintf("shoji: cannot execute config %s\n", path)
	}
}

default_config :: proc() -> string {
	xdg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	home := os.get_env("HOME", context.temp_allocator)
	candidates := [3]string {
		fmt.tprintf("%s/shoji/shojirc", xdg != "" ? xdg : fmt.tprintf("%s/.config", home)),
		fmt.tprintf("%s/.shojirc", home),
		"",
	}
	for path in candidates {
		if path != "" && os.exists(path) {
			return path
		}
	}
	return ""
}

inspect :: proc() -> int {
	if !AXIsProcessTrusted() {
		fmt.eprintln(
			"shoji: Accessibility permission is required to enumerate application windows",
		)
		return 1
	}
	state: State
	state_init(&state)
	defer state_destroy(&state)
	refresh(&state)
	fmt.print(
		"{\"displays\":",
		e.query(&state.manager, []string{"--displays"}).text,
		",\"spaces\":",
		e.query(&state.manager, []string{"--spaces"}).text,
		",\"windows\":",
		e.query(&state.manager, []string{"--windows"}).text,
		"}\n",
	)
	return 0
}

run :: proc(config_path: string) -> int {
	if geteuid() == 0 {
		fmt.eprintln("shoji: run as your desktop user, not root")
		return 1
	}
	if !AXIsProcessTrusted() {
		fmt.eprintln(
			"shoji: grant Accessibility permission to this executable in System Settings, then restart",
		)
		return 1
	}
	lock_path := fmt.tprintf("/tmp/shoji_%d.lock", getuid())
	lock := posix.open(
		strings.clone_to_cstring(lock_path, context.temp_allocator),
		{.RDWR, .CREAT, .NOFOLLOW, .CLOEXEC},
		{.IRUSR, .IWUSR},
	)
	if lock < 0 {
		fmt.eprintln("shoji: cannot open daemon lock")
		return 1
	}
	defer posix.close(lock)
	if flock(i32(lock), 2 | 4) != 0 {
		fmt.eprintln("shoji: another daemon is already running")
		return 1
	}
	socket_name := strings.clone(socket_path())
	defer delete(socket_name)
	cpath := strings.clone_to_cstring(socket_name)
	defer delete(cpath)
	addr, ok := address(socket_name)
	if !ok {
		return 1
	}
	fd := socket(1, 1, 0)
	if fd < 0 {
		fmt.eprintln("shoji: cannot create socket")
		return 1
	}
	defer close(fd)
	prepare_socket(fd)
	unlink(cpath)
	if bind(fd, &addr, size_of(addr)) != 0 {
		fmt.eprintln("shoji: cannot bind socket")
		return 1
	}
	defer unlink(cpath)
	if chmod(cpath, 0o600) != 0 || listen(fd, 64) != 0 {
		fmt.eprintln("shoji: cannot listen on socket")
		return 1
	}
	posix.signal(.SIGINT, stop_handler)
	posix.signal(.SIGTERM, stop_handler)
	state: State
	state_init(&state)
	defer state_destroy(&state)
	refresh(&state)
	config := config_path == "" ? default_config() : config_path
	if config != "" && !os.exists(config) {
		fmt.eprintf("shoji: config does not exist: %s\n", config)
		return 1
	}
	mouse_start(&state)
	defer mouse_stop(&state)
	run_config(config)
	fmt.eprintf("shoji: listening on %s\n", socket_name)
	last_refresh := time.now()
	for sync.atomic_load(&stop_requested) == 0 {
		scratch: mem.Dynamic_Arena
		mem.dynamic_arena_init(&scratch)
		{
			context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
			CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.016, true)
			mouse_tick(&state)
			now := time.now()
			if state.dirty || time.duration_seconds(time.diff(last_refresh, now)) >= 1 {
				refresh(&state)
				for s in state.manager.spaces {
					if s.visible {
						if err := e.flush(&state.manager, s); err != "" {
							fmt.eprintln("shoji:", err)
						}
					}
				}
				last_refresh = now
			}
			ready := Poll_FD {
				fd     = fd,
				events = 1,
			}
			if poll(&ready, 1, 0) > 0 && ready.revents & 1 != 0 {
				client_fd := accept(fd, nil, nil)
				if client_fd >= 0 {
					serve_message(client_fd, &state.manager)
				}
			}
			status: i32
			for posix.waitpid(-1, &status, {.NOHANG}) > 0 {
			}
		}
		mem.dynamic_arena_destroy(&scratch)
	}
	return 0
}
