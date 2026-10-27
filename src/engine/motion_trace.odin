package engine

import "core:encoding/json"
import "core:time"

// Opt-in bounded memory capture: no file I/O or logging on the animation path.
// Native bounds and AX completion are observations, not display presentation.
MOTION_TRACE_LIMIT :: 8192
MOTION_TRACE_SECONDS :: 30.0
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
	if len(args) != 2 || args[0] != "motion" {return failure("debug expects motion start|stop|dump|clear")}
	t := &m.motion_trace
	switch args[1] {
	case "start":
		delete(t.events)
		t^ = {active = true, started = time.tick_now(), events = make([dynamic]Motion_Event, 0, MOTION_TRACE_LIMIT)}
		return success("motion capture started (30 seconds or 8192 events)")
	case "stop": t.active = false; return success("motion capture stopped")
	case "clear": delete(t.events); t^ = {}; return success()
	case "dump":
		motion_trace_record(t, {kind = "dump"})
		data, err := json.marshal(Motion_Export{1, t.active, t.full, t.expired, MOTION_TRACE_LIMIT, "monotonic milliseconds since capture start; source_time is CGEvent uptime for input, Core Animation uptime for presentation-tick", t.events[:]}, allocator = context.temp_allocator)
		if err != nil {return failure("could not encode motion trace")}
		return success(string(data))
	}
	return failure("debug expects motion start|stop|dump|clear")
}
