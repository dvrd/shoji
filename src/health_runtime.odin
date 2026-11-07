package shoji

// Daemon health owner: connects the Dock payload reloader, the startup
// configuration run and notifications, and answers `query --health`.

import "core:encoding/json"
import "core:fmt"
import "core:time"

Runtime_Health :: struct {
	reload: ^Addition_Reload,
	config: Config_Run,
	notifier: Notifier,
	attach: ^Ws_Attach_Runtime, // nil outside the daemon
}

health_start :: proc(h: ^Runtime_Health, m: ^Manager) {
	assert(h.reload != nil)
	notifier_start(&h.notifier)
	m.health_report = health_report
	m.health_notify_test = health_notify_test
	m.health_user = h
}

health_stop :: proc(h: ^Runtime_Health) {
	config_run_stop(&h.config)
	notifier_stop(&h.notifier)
}

health_tick :: proc(h: ^Runtime_Health, now: time.Time) {
	config_run_drain(&h.config)
	notify_payload_transition(&h.notifier, h.reload, now)
	notify_config_failures(&h.notifier, &h.config, now)
	if h.attach != nil && h.attach.failed_event {
		h.attach.failed_event = false
		cause := bounded_get(&h.attach.cause)
		notify(&h.notifier, "Shoji: WindowServer gate unavailable", cause, now)
	}
}

// Routes a reaped child to its owner by process ID.
health_child_finished :: proc(h: ^Runtime_Health, pid, status: i32, now: time.Time) {
	exit := child_exit_from_status(status)
	if addition_reload_finished(h.reload, pid, exit, now) {
		notify_payload_transition(&h.notifier, h.reload, now)
		return
	}
	if config_run_finished(&h.config, pid, exit) {
		notify_config_failures(&h.notifier, &h.config, now)
	}
}

Health_Config_Failure_JSON :: struct {
	line: i32,
	command: string,
	error: string,
}

Health_JSON :: struct {
	payload: string,
	payload_enabled: bool,
	payload_failures: u32,
	payload_cause: string,
	crash_report: string,
	config_finished: bool,
	config_exit: string,
	config_failures: []Health_Config_Failure_JSON,
	config_failures_dropped: int,
	notifications: string,
	notifications_suppressed: int,
	gate: string,
	gate_cause: string,
}

health_report :: proc(user: rawptr) -> string {
	h := (^Runtime_Health)(user)
	r := h.reload
	report := &h.config.report
	failures := make([]Health_Config_Failure_JSON, report.count, context.temp_allocator)
	for i in 0 ..< report.count {
		f := &report.failures[i]
		failures[i] = {f.line, bounded_get(&f.command), bounded_get(&f.error)}
	}
	value := Health_JSON {
		payload = health_payload_state_name(r),
		payload_enabled = r.payload != "",
		payload_failures = r.health.failures,
		payload_cause = bounded_get(&r.health.cause),
		crash_report = bounded_get(&r.health.crash_report),
		config_finished = report.finished,
		config_exit = report.finished ? child_exit_text(report.exit) : "",
		config_failures = failures,
		config_failures_dropped = report.dropped,
		notifications = health_notifier_name(&h.notifier),
		notifications_suppressed = h.notifier.suppressed,
		gate = "off",
	}
	if h.attach != nil {
		value.gate = ws_attach_state_name(h.attach.state)
		value.gate_cause = bounded_get(&h.attach.cause)
	}
	data, err := json.marshal(value, {pretty = true}, context.temp_allocator)
	if err != nil {
		return "{}"
	}
	return string(data)
}

health_payload_state_name :: proc(r: ^Addition_Reload) -> string {
	if r.payload == "" {
		return "disabled"
	}
	switch r.health.state {
	case .Starting:
		return "starting"
	case .Ready:
		return "ready"
	case .Recovering:
		return "recovering"
	case .Failed:
		return "failed"
	}
	return "unknown"
}

health_notifier_name :: proc(n: ^Notifier) -> string {
	if !n.available {
		return "unavailable"
	}
	switch n.authorization {
	case .Unknown:
		return "pending"
	case .Granted:
		return "allowed"
	case .Denied:
		return "denied"
	}
	return "unknown"
}

// Posts a visible test notification. The time keeps repeated tests from being
// deduplicated; the rate limit still applies and is reported.
health_notify_test :: proc(user: rawptr) -> Response {
	n := &(^Runtime_Health)(user).notifier
	switch health_notifier_name(n) {
	case "unavailable":
		return failure("notifications unavailable: run Shoji from Shoji.app")
	case "denied":
		return failure("notifications denied: allow Shoji in System Settings > Notifications")
	}
	now := time.now()
	hour, minute, second := time.clock_from_time(now)
	body := fmt.tprintf("Notifications work (%02d:%02d:%02d).", hour, minute, second)
	suppressed := n.suppressed
	notify(n, "Shoji: test", body, now)
	if n.suppressed != suppressed {
		return failure("not posted: rate limit reached (5 per 10 minutes)")
	}
	if health_notifier_name(n) == "pending" {
		return success("posted; permission still pending, answer the macOS prompt\n")
	}
	return success("posted test notification\n")
}
