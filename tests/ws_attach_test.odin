package tests

import mac "../src"
import gate "../src/windowserver/gate"
import "core:strings"
import "core:testing"
import health "../src/health"
import service "../src/service"
import attach "../src/windowserver/attach"

@(private = "file")
status_bytes :: proc(status: gate.Tgate_Status) -> []u8 {
	data := make([]u8, size_of(gate.Tgate_Status), context.temp_allocator)
	copied := status
	copy(data, (cast([^]u8)&copied)[:size_of(gate.Tgate_Status)])
	return data
}

@(test)
tgate_status_decode_requires_current_status_for_live_windowserver :: proc(t: ^testing.T) {
	good := gate.Tgate_Status {
		magic            = gate.TGATE_MAGIC,
		version          = gate.TGATE_VERSION,
		mach_port        = 0x1303,
		windowserver_pid = 400,
	}
	data := status_bytes(good)
	status, ok := gate.tgate_status_decode(data, gate.UID, 400)
	testing.expect(t, ok)
	testing.expect_value(t, status.mach_port, 0x1303)
	// A status left by a previous WindowServer must not be trusted.
	_, ok = gate.tgate_status_decode(data, gate.UID, 401)
	testing.expect(t, !ok)
	// Only WindowServer's user may have written the file.
	_, ok = gate.tgate_status_decode(data, 501, 400)
	testing.expect(t, !ok)
	_, ok = gate.tgate_status_decode(data[:len(data) - 1], gate.UID, 400)
	testing.expect(t, !ok)
	old := good
	old.version = gate.TGATE_VERSION - 1
	_, ok = gate.tgate_status_decode(status_bytes(old), gate.UID, 400)
	testing.expect(t, !ok)
	foreign_magic := good
	foreign_magic.magic[0] = 'X'
	_, ok = gate.tgate_status_decode(status_bytes(foreign_magic), gate.UID, 400)
	testing.expect(t, !ok)
}

@(test)
ws_attach_payload_safe_requires_root_owned_unwritable_file_and_dir :: proc(t: ^testing.T) {
	file :: u32(0o100644)
	dir :: u32(0o040755)
	testing.expect(t, attach.ws_attach_payload_safe(0, file, 0, dir))
	testing.expect(t, !attach.ws_attach_payload_safe(501, file, 0, dir))
	testing.expect(t, !attach.ws_attach_payload_safe(0, file, 501, dir))
	testing.expect(t, !attach.ws_attach_payload_safe(0, 0o100664, 0, dir))
	testing.expect(t, !attach.ws_attach_payload_safe(0, 0o100646, 0, dir))
	testing.expect(t, !attach.ws_attach_payload_safe(0, file, 0, 0o040775))
	testing.expect(t, !attach.ws_attach_payload_safe(0, 0o120755, 0, dir)) // symlink
	testing.expect(t, !attach.ws_attach_payload_safe(0, file, 0, 0o120755))
}

@(test)
ws_attach_clients_merge_keeps_recent_wellformed_entries :: proc(t: ^testing.T) {
	a := strings.repeat("a", 40, context.temp_allocator)
	b := strings.repeat("b", 40, context.temp_allocator)
	c := strings.repeat("c", 40, context.temp_allocator)
	self := strings.repeat("1", 40, context.temp_allocator)
	merged := attach.ws_attach_clients_merge("", self, 3)
	testing.expect_value(t, merged, strings.concatenate({self, "\n"}, context.temp_allocator))
	// Self moves to the end; malformed entries drop; oldest entries age out.
	existing := strings.concatenate({a, ",", self, " bogus\n", b, "\n", c}, context.temp_allocator)
	merged = attach.ws_attach_clients_merge(existing, self, 3)
	expected := strings.concatenate({b, "\n", c, "\n", self, "\n"}, context.temp_allocator)
	testing.expect_value(t, merged, expected)
	// Already newest: unchanged, so the caller skips the write.
	testing.expect_value(t, attach.ws_attach_clients_merge(expected, self, 3), expected)
	upper := strings.repeat("A", 40, context.temp_allocator)
	merged = attach.ws_attach_clients_merge(upper, self, 3)
	testing.expect(t, !strings.contains(merged, upper))
}

@(test)
ws_attach_rejects_arguments :: proc(t: ^testing.T) {
	testing.expect_value(t, attach.ws_attach_cli({"--payload", "/tmp/x.dylib"}), 2)
}

@(test)
ws_attach_retries_transient_failures_and_stops_on_refusal :: proc(t: ^testing.T) {
	failed := health.Child_Exit{.Exited, 1}
	refused := health.Child_Exit{.Exited, attach.WS_ATTACH_EXIT_REFUSED}
	Outcome :: mac.Ws_Attach_Outcome
	testing.expect_value(t, mac.ws_attach_exit_outcome(failed, true, 1), Outcome.Connected)
	testing.expect_value(t, mac.ws_attach_exit_outcome(failed, false, 1), Outcome.Retry)
	testing.expect_value(t, mac.ws_attach_exit_outcome(refused, false, 1), Outcome.Give_Up)
	last := u32(mac.WS_ATTACH_ATTEMPTS)
	testing.expect_value(t, mac.ws_attach_exit_outcome(failed, false, last), Outcome.Give_Up)
}

@(test)
windowserver_gate_setting_requires_the_daemon :: proc(t: ^testing.T) {
	m: mac.Manager
	mac.manager_init(&m)
	defer mac.manager_destroy(&m)
	response := mac.execute(&m, {"config", "windowserver_gate", "on"})
	testing.expect(t, response.failed)
}

@(test)
service_status_shows_gate_failure_cause :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	h := health.Health_JSON{gate = "failed", gate_cause = "payload not installed"}
	service.status_render_health(&b, {color = false, home = "/Users/u"}, h)
	text := strings.to_string(b)
	testing.expect(t, strings.contains(text, "● failed"))
	testing.expect(t, strings.contains(text, "payload not installed"))
}

@(test)
dock_payload_resolves_beside_the_executable :: proc(t: ^testing.T) {
	// The test binary lives in bin/, beside the development payload.
	path, err := mac.addition_payload_path()
	testing.expect_value(t, err, "")
	testing.expect(t, strings.has_suffix(path, "/bin/shoji-sa.dylib"))
}

@(test)
ws_images_scan_reads_this_process_without_a_payload :: proc(t: ^testing.T) {
	// Exercises the dyld image-list walk on a task that surely has no payload.
	scan := attach.ws_images_scan(gate.gate_mach_task_self())
	testing.expect_value(t, scan, attach.Ws_Images_Scan.Clean)
	testing.expect(t, attach.ws_image_path_is_shoji_payload(attach.WS_PAYLOAD_PREFIX))
	testing.expect(t, !attach.ws_image_path_is_shoji_payload("/System/Library/Frameworks/"))
}

@(test)
barrier_parks_suspended_threads_that_are_off_core :: proc(t: ^testing.T) {
	testing.expect(t, gate.barrier_run_state_parked(gate.TH_STATE_STOPPED, 1))
	testing.expect(t, gate.barrier_run_state_parked(gate.TH_STATE_WAITING, 1))
	// WindowServer keeps a thread in an uninterruptible kernel wait at login.
	testing.expect(t, gate.barrier_run_state_parked(gate.TH_STATE_UNINTERRUPTIBLE, 1))
	testing.expect(t, gate.barrier_run_state_parked(gate.TH_STATE_HALTED, 1))
	testing.expect(t, !gate.barrier_run_state_parked(gate.TH_STATE_RUNNING, 1))
	testing.expect(t, !gate.barrier_run_state_parked(gate.TH_STATE_WAITING, 0))
}
