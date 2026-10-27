package tests

import mac "../src/macos"
import "core:sys/posix"
import "core:testing"
import "core:time"

config_launch_count: int
record_config_launch :: proc(_: string) -> bool {config_launch_count += 1;return true}
fail_config_launch :: proc(_: string) -> bool {return false}

@(test)
startup_config_waits_for_verified_payload_and_runs_only_once :: proc(t: ^testing.T) {
	r: mac.Addition_Reload;rec: Reload_Recorder
	reload_fixture(&r, &rec);defer delete(rec.phases)
	started := false
	config_launch_count = 0
	now := time.now()
	mac.addition_reload_tick(&r, 42, now)
	testing.expect(t, mac.startup_config_start("test-config", &r, &started, record_config_launch))
	testing.expect(t, !started && config_launch_count == 0)
	mac.addition_reload_finished(&r, r.child, false, now)
	mac.addition_reload_tick(&r, 42, now)
	mac.addition_reload_finished(&r, r.child, true, now)
	testing.expect(t, mac.startup_config_start("test-config", &r, &started, record_config_launch))
	testing.expect(t, !started && config_launch_count == 0)
	mac.addition_reload_tick(&r, 42, now)
	mac.addition_reload_finished(&r, r.child, true, now)
	testing.expect(t, mac.startup_config_start("test-config", &r, &started, record_config_launch))
	testing.expect(t, started && config_launch_count == 1)
	mac.addition_reload_tick(&r, 43, now)
	testing.expect(t, mac.startup_config_start("test-config", &r, &started, record_config_launch))
	testing.expect_value(t, config_launch_count, 1)
	started = false;r.payload = ""
	testing.expect(t, !mac.startup_config_start("test-config", &r, &started, fail_config_launch))
	testing.expect(t, !started)
}

Reload_Recorder :: struct {
	phases:     [dynamic]mac.Addition_Reload_Phase,
	fail_spawn: bool,
}
reload_spawn :: proc(
	user: rawptr,
	phase: mac.Addition_Reload_Phase,
	binary, payload: string,
) -> (
	i32,
	string,
) {
	r := (^Reload_Recorder)(user)
	append(&r.phases, phase)
	if r.fail_spawn {return 0, "test spawn failure"}
	return i32(len(r.phases) + 100), ""
}
reload_fixture :: proc(r: ^mac.Addition_Reload, rec: ^Reload_Recorder) {
	r.binary = "test-shoji"
	r.payload = "test-payload"
	r.spawn = reload_spawn
	r.user = rec
}
@(test)
reload_checks_before_loading_and_verifies_success :: proc(t: ^testing.T) {
	r: mac.Addition_Reload;rec: Reload_Recorder
	reload_fixture(&r, &rec);defer delete(rec.phases)
	now := time.now()
	mac.addition_reload_tick(&r, 42, now)
	testing.expect_value(t, rec.phases[0], mac.Addition_Reload_Phase.Check)
	mac.addition_reload_tick(&r, 42, now)
	testing.expect_value(t, len(rec.phases), 1)
	mac.addition_reload_finished(&r, r.child, false, now)
	mac.addition_reload_tick(&r, 42, now)
	testing.expect_value(t, rec.phases[1], mac.Addition_Reload_Phase.Load)
	mac.addition_reload_finished(&r, r.child, true, now)
	mac.addition_reload_tick(&r, 42, now)
	testing.expect_value(t, rec.phases[2], mac.Addition_Reload_Phase.Check)
	mac.addition_reload_finished(&r, r.child, true, now)
	testing.expect(t, r.healthy)
	mac.addition_reload_tick(&r, 42, time.time_add(now, time.Second))
	testing.expect_value(t, len(rec.phases), 3)
}
@(test)
reload_handles_dock_disappearance_and_stale_child_result :: proc(t: ^testing.T) {
	r: mac.Addition_Reload;rec: Reload_Recorder
	reload_fixture(&r, &rec);defer delete(rec.phases)
	now := time.now()
	mac.addition_reload_tick(&r, 42, now)
	old_child := r.child
	mac.addition_reload_tick(&r, 0, now)
	mac.addition_reload_tick(&r, 43, now)
	testing.expect_value(t, len(rec.phases), 1)
	mac.addition_reload_finished(&r, old_child, true, now)
	testing.expect(t, !r.healthy)
	mac.addition_reload_tick(&r, 43, now)
	testing.expect_value(t, len(rec.phases), 2)
	testing.expect_value(t, r.child_dock, i32(43))
	mac.addition_reload_finished(&r, r.child, true, now)
	mac.addition_reload_tick(&r, 44, now)
	testing.expect(t, !r.healthy)
	testing.expect_value(t, len(rec.phases), 3)
}
@(test)
reload_retries_failed_load_with_capped_backoff :: proc(t: ^testing.T) {
	r: mac.Addition_Reload;rec: Reload_Recorder
	reload_fixture(&r, &rec);defer delete(rec.phases)
	now := time.now()
	mac.addition_reload_tick(&r, 42, now)
	mac.addition_reload_finished(&r, r.child, false, now)
	for _ in 0 ..< 8 {
		mac.addition_reload_tick(&r, 42, now)
		if r.phase == .Check {
			mac.addition_reload_finished(&r, r.child, false, now)
			mac.addition_reload_tick(&r, 42, now)
		}
		testing.expect_value(t, r.phase, mac.Addition_Reload_Phase.Load)
		mac.addition_reload_finished(&r, r.child, false, now)
		testing.expect(t, r.retry_delay <= 30 * time.Second)
		count := len(rec.phases)
		mac.addition_reload_tick(&r, 42, now)
		testing.expect_value(t, len(rec.phases), count)
		now = r.next_attempt
	}
	mac.addition_reload_tick(&r, 43, now)
	testing.expect_value(t, r.phase, mac.Addition_Reload_Phase.Check)
	testing.expect_value(t, r.retry_delay, time.Duration(0))
}
@(test)
reload_spawn_failure_and_disabled_mode_are_safe :: proc(t: ^testing.T) {
	r: mac.Addition_Reload;rec: Reload_Recorder
	now := time.now()
	mac.addition_reload_tick(&r, 42, now)
	testing.expect_value(t, r.child, i32(0))
	reload_fixture(&r, &rec);defer delete(rec.phases)
	rec.fail_spawn = true
	mac.addition_reload_tick(&r, 42, now)
	testing.expect_value(t, r.child, i32(0))
	testing.expect(t, time.diff(now, r.next_attempt) > 0)
	testing.expect(t, !mac.addition_reload_finished(&r, 999, true, now))
}
@(test)
reload_does_not_reinject_after_successful_load_with_bad_handshake :: proc(t: ^testing.T) {
	r: mac.Addition_Reload;rec: Reload_Recorder
	reload_fixture(&r, &rec);defer delete(rec.phases)
	now := time.now()
	mac.addition_reload_tick(&r, 42, now)
	mac.addition_reload_finished(&r, r.child, false, now)
	mac.addition_reload_tick(&r, 42, now)
	mac.addition_reload_finished(&r, r.child, true, now)
	mac.addition_reload_tick(&r, 42, now)
	mac.addition_reload_finished(&r, r.child, false, now)
	mac.addition_reload_tick(&r, 42, r.next_attempt)
	testing.expect_value(t, rec.phases[3], mac.Addition_Reload_Phase.Check)
}
@(test)
reload_restart_detection_survives_missing_dock_poll :: proc(t: ^testing.T) {
	state: mac.State
	mac.workspace_set_dock_pid(&state, 42)
	testing.expect(t, .Dock_Restart not_in state.workspace_events.pending)
	mac.workspace_set_dock_pid(&state, 0)
	mac.workspace_set_dock_pid(&state, 43)
	testing.expect(t, .Dock_Restart in state.workspace_events.pending)
	testing.expect_value(t, state.workspace_events.dock_pid, i32(43))
}

@(test)
reload_existing_payload_avoids_injection_and_duplicate_notifications :: proc(t: ^testing.T) {
	r: mac.Addition_Reload;rec: Reload_Recorder
	reload_fixture(&r, &rec);defer delete(rec.phases)
	now := time.now()
	mac.addition_reload_tick(&r, 42, now)
	mac.addition_reload_finished(&r, r.child, true, now)
	for _ in 0 ..< 3 {mac.addition_reload_tick(&r, 42, now)}
	testing.expect_value(t, len(rec.phases), 1)
	testing.expect(t, r.healthy)
}
@(test)
reload_native_subprocess_exit_drives_verification :: proc(t: ^testing.T) {
	// Exercise the real spawn/reap path without sudo, injection, or desktop changes.
	r := mac.Addition_Reload {
		binary  = "/usr/bin/true",
		payload = "unused",
	}
	now := time.now()
	mac.addition_reload_tick(&r, 42, now)
	testing.expect(t, r.child > 0)
	if r.child <= 0 {return}
	status: i32
	pid := posix.waitpid(posix.pid_t(r.child), &status, {})
	testing.expect_value(t, i32(pid), r.child)
	testing.expect(
		t,
		mac.addition_reload_finished(
			&r,
			i32(pid),
			posix.WIFEXITED(status) && posix.WEXITSTATUS(status) == 0,
			now,
		),
	)
	testing.expect(t, r.healthy)
}
@(test)
reload_init_validates_and_owns_paths :: proc(t: ^testing.T) {
	r: mac.Addition_Reload
	testing.expect(t, mac.addition_reload_init(&r, "/nonexistent/shoji-payload.dylib") != "")
	testing.expect_value(t, r.payload, "")
	testing.expect_value(t, mac.addition_reload_init(&r, "README.md"), "")
	testing.expect(t, len(r.payload) > 0 && r.payload[0] == '/')
	testing.expect(t, len(r.binary) > 0 && r.binary[0] == '/')
	mac.addition_reload_destroy(&r)
	testing.expect_value(t, r.payload, "")
}
