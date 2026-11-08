package shoji

import "core:encoding/json"
import layout "layout"
import "core:strconv"
import "core:time"

// Motion traces
// ------------------------------------------------------------------------

// Opt-in bounded memory capture: no file I/O or logging on the animation path.
// Native bounds and AX completion are observations, not display presentation.
MOTION_TRACE_LIMIT :: 8192
MOTION_TRACE_SECONDS :: 60.0
Motion_Event :: struct {
	kind: string,
	at_ms, duration_ms, source_time, value: f64,
	space: u64,
	window: u32,
	requested, observed: Rect,
	status: i32,
}
Motion_Trace :: struct {
	active, full, expired: bool,
	started: time.Tick,
	events: [dynamic]Motion_Event,
}
Motion_Export :: struct {
	version: int,
	active, full, expired: bool,
	limit: int,
	clock: string,
	events: []Motion_Event,
}
motion_trace_record :: proc(trace: ^Motion_Trace, event: Motion_Event, now: time.Tick = {}) {
	if !trace.active {return}
	now := now
	if now == (time.Tick{}) {now = time.tick_now()}
	elapsed := time.duration_seconds(time.tick_diff(trace.started, now))
	if elapsed >= MOTION_TRACE_SECONDS {trace.active = false; trace.expired = true; return}
	if len(trace.events) >= MOTION_TRACE_LIMIT {trace.active = false; trace.full = true; return}
	event := event
	event.at_ms = elapsed * 1000
	append(&trace.events, event)
}
motion_debug :: proc(m: ^Manager, args: []string) -> Response {
	if len(args) == 2 && args[0] == "ws" && (args[1] == "status" || args[1] == "dump") {
		if m.ws_debug == nil {return failure("WindowServer adapter not available in this process")}
		return success(m.ws_debug(m.backend_user, args[1] == "dump"))
	}
	if len(args) == 3 && args[0] == "conceal" && (args[2] == "on" || args[2] == "off") {
		return debug_conceal(m, args[1], args[2] == "on")
	}
	if len(args) != 2 || args[0] != "motion" {return failure(DEBUG_USAGE)}
	t := &m.motion_trace
	switch args[1] {
	case "start":
		delete(t.events)
		t^ = {active = true, started = time.tick_now(), events = make([dynamic]Motion_Event, 0, MOTION_TRACE_LIMIT)}
		return success("motion capture started (60 seconds or 8192 events)")
	case "stop": t.active = false; return success("motion capture stopped")
	case "clear": delete(t.events); t^ = {}; return success()
	case "dump":
		motion_trace_record(t, {kind = "dump"})
		data, err := json.marshal(Motion_Export{1, t.active, t.full, t.expired, MOTION_TRACE_LIMIT, "monotonic milliseconds since capture start; source_time is CGEvent uptime for input, Core Animation uptime for presentation-tick", t.events[:]}, allocator = context.temp_allocator)
		if err != nil {return failure("could not encode motion trace")}
		return success(string(data))
	}
	return failure(DEBUG_USAGE)
}

// Where a window joined the layout: value = windows in its column, status =
// 1 when that column is tabbed, requested.x = the armed insertion window.
motion_trace_join :: proc(m: ^Manager, s: ^Space, id: u32, kind: string) {
	if !m.motion_trace.active || s == nil {return}
	n := layout.find(s.view.root, id)
	event := Motion_Event{kind = kind, window = id, space = s.id, requested = {x = f64(s.view.insertion)}}
	if n != nil {
		event.value = f64(n.count)
		event.status = n.column_tabbed ? 1 : 0
	}
	motion_trace_record(&m.motion_trace, event)
}

DEBUG_USAGE :: "debug expects motion start|stop|dump|clear, ws status|dump or conceal WID on|off"

debug_conceal :: proc(m: ^Manager, window: string, conceal: bool) -> Response {
	wid, ok := strconv.parse_u64(window)
	if !ok || wid == 0 || wid > u64(max(u32)) {return failure("conceal expects a window id")}
	if m.windows[u32(wid)] == nil {return failure("conceal expects a managed window")}
	if err := perform(m, {kind = .Conceal, window = u32(wid), flag = conceal}); err != "" {return failure(err)}
	return success()
}
