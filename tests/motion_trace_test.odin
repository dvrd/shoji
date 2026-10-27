package tests

import e "../src/engine"
import "core:encoding/json"
import "core:testing"
import "core:time"

@(test)
motion_capture_is_opt_in_bounded_and_restarts_cleanly :: proc(t: ^testing.T) {
	m: e.Manager
	defer delete(m.motion_trace.events)
	e.motion_trace_record(&m.motion_trace, {kind = "sample"})
	testing.expect_value(t, len(m.motion_trace.events), 0)
	testing.expect(t, !e.execute(&m, {"debug", "motion", "start"}).failed)
	began := m.motion_trace.started
	for i in 0 ..< e.MOTION_TRACE_LIMIT + 1 {
		e.motion_trace_record(&m.motion_trace, {kind = "sample", value = f64(i)}, began)
	}
	testing.expect_value(t, len(m.motion_trace.events), e.MOTION_TRACE_LIMIT)
	testing.expect(t, m.motion_trace.full && !m.motion_trace.active)
	e.execute(&m, {"debug", "motion", "start"})
	testing.expect(t, m.motion_trace.active && !m.motion_trace.full)
	testing.expect_value(t, len(m.motion_trace.events), 0)
	e.motion_trace_record(&m.motion_trace, {kind = "input", value = 15}, time.tick_add(m.motion_trace.started, time.Millisecond * 25))
	testing.expect_value(t, m.motion_trace.events[0].at_ms, f64(25))
	e.execute(&m, {"debug", "motion", "stop"})
	response := e.execute(&m, {"debug", "motion", "dump"})
	data: e.Motion_Export
	err := json.unmarshal(transmute([]u8)response.text, &data)
	defer delete(data.events)
	defer delete(data.clock)
	for event in data.events {delete(event.kind)}
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(data.events), 1)
	testing.expect_value(t, data.events[0].value, f64(15))
	e.execute(&m, {"debug", "motion", "clear"})
	testing.expect_value(t, len(m.motion_trace.events), 0)
}

@(test)
motion_capture_expires_and_rejects_invalid_commands :: proc(t: ^testing.T) {
	m: e.Manager
	defer delete(m.motion_trace.events)
	e.execute(&m, {"debug", "motion", "start"})
	e.motion_trace_record(&m.motion_trace, {kind = "sample"}, time.tick_add(m.motion_trace.started, 31 * time.Second))
	testing.expect(t, m.motion_trace.expired && !m.motion_trace.active)
	testing.expect_value(t, len(m.motion_trace.events), 0)
	testing.expect(t, e.execute(&m, {"debug", "motion"}).failed)
	testing.expect(t, e.execute(&m, {"debug", "motion", "unknown"}).failed)
}
