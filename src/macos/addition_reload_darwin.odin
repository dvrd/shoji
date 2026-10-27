package macos

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:time"

Addition_Reload_Phase :: enum {
	Check,
	Load,
}
Addition_Reload :: struct {
	binary, payload: string,
	dock, child, child_dock: i32,
	phase: Addition_Reload_Phase,
	healthy, loaded: bool,
	next_attempt: time.Time,
	retry_delay: time.Duration,
	spawn: proc(
		user: rawptr,
		phase: Addition_Reload_Phase,
		binary, payload: string,
	) -> (
		i32,
		string,
	),
	user: rawptr,
}

addition_reload_init :: proc(r: ^Addition_Reload, payload: string) -> string {
	if payload == "" {
		return ""
	}
	path, err := filepath.abs(payload, context.temp_allocator)
	if err != nil || !os.is_file(path) {
		return "scripting-addition library does not exist or is not a file"
	}
	binary, binary_err := os.get_executable_path(context.temp_allocator)
	if binary_err != nil {
		return "cannot resolve shoji executable path"
	}
	r.payload = strings.clone(path)
	r.binary = strings.clone(binary)
	return ""
}
addition_reload_destroy :: proc(r: ^Addition_Reload) {
	// The standalone loader owns its remote operation and completion cleanup.
	// Do not interrupt an in-flight injection when the daemon shuts down.
	delete(r.payload); delete(r.binary)
	r^ = {}
}
addition_reload_spawn :: proc(
	user: rawptr,
	phase: Addition_Reload_Phase,
	binary, payload: string,
) -> (
	i32,
	string,
) {
	args: [6]cstring
	if phase == .Load {
		args = {
			"/usr/bin/sudo",
			"-n",
			strings.clone_to_cstring(binary, context.temp_allocator),
			"--load-sa",
			strings.clone_to_cstring(payload, context.temp_allocator),
			nil,
		}
	} else {
		args = {
			strings.clone_to_cstring(binary, context.temp_allocator),
			"--check-sa",
			nil,
			nil,
			nil,
			nil,
		}
	}
	pid: posix.pid_t
	if posix.posix_spawn(
		   &pid,
		   args[0],
		   nil,
		   nil,
		   &args[0],
		   _NSGetEnviron()^,
	   ) !=
	   nil {
		return 0, "cannot start scripting-addition recovery subprocess"
	}
	return i32(pid), ""
}
addition_reload_backoff :: proc(r: ^Addition_Reload, now: time.Time) {
	r.retry_delay =
		r.retry_delay == 0 \
			? time.Second \
			: min(r.retry_delay * 2, 30 * time.Second)
	r.next_attempt = time.time_add(now, r.retry_delay)
}
addition_reload_tick :: proc(r: ^Addition_Reload, dock: i32, now: time.Time) {
	if r.payload == "" {
		return
	}
	if dock != r.dock {
		r.dock = dock
		r.healthy, r.loaded = false, false
		r.phase = .Check
		r.next_attempt = now
		r.retry_delay = 0
	}
	if dock == 0 ||
	   r.child != 0 ||
	   r.healthy ||
	   time.diff(now, r.next_attempt) > 0 {
		return
	}
	spawn := r.spawn
	if spawn == nil {
		spawn = addition_reload_spawn
	}
	pid, err := spawn(r.user, r.phase, r.binary, r.payload)
	if err != "" || pid <= 0 {
		fmt.eprintln("shoji: payload recovery:", err)
		addition_reload_backoff(r, now)
		return
	}
	r.child, r.child_dock = pid, dock
}
addition_reload_finished :: proc(
	r: ^Addition_Reload,
	child: i32,
	success: bool,
	now: time.Time,
) -> bool {
	if child == 0 || child != r.child {
		return false
	}
	r.child = 0
	// A subprocess completing for an old Dock cannot establish current health.
	if r.child_dock != r.dock {
		return true
	}
	if r.phase == .Check {
		if success {
			r.healthy = true
			r.retry_delay = 0
			fmt.eprintln("shoji: Dock payload is ready")
		} else if !r.loaded {
			r.phase = .Load
			r.next_attempt = now
		} else {
			fmt.eprintln(
				"shoji: loaded payload handshake failed; retrying verification",
			)
			addition_reload_backoff(r, now)
		}
	} else {
		r.phase = .Check
		if success {
			r.loaded = true
			r.next_attempt = now
		} else {
			fmt.eprintln(
				"shoji: payload reload failed; retrying (noninteractive sudo permission is required)",
			)
			addition_reload_backoff(r, now)
		}
	}
	return true
}
