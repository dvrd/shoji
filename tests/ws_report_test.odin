package tests

import "core:testing"
import shoji "../src"
import e "../src"

@(private = "file")
put :: proc(data: []u8, offset: int, value: $T) {
	for i in 0 ..< size_of(T) {data[offset + i] = u8(u64(value) >> (8 * uint(i)))}
}

@(private = "file")
ring_fixture :: proc() -> []u8 {
	data := make([]u8, shoji.WS_RING_SIZE, context.temp_allocator)
	copy(data, "WSOBSERV")
	put(data, 8, u64(3)); put(data, 16, u64(300)) // version, calls
	put(data, 40, u32(125)); put(data, 44, u32(3)) // timebase 125/3 ns
	// Slot 2 holds sequence 290, slot 0 sequence 300 (wrapped ring).
	for slot_seq in ([][2]int{{0, 300}, {2, 290}}) {
		off := shoji.WS_RING_HEADER + slot_seq[0] * shoji.WS_RING_STRIDE
		put(data, off, u64(slot_seq[1]))
		put(data, off + 16, u64(1000)); put(data, off + 24, u64(1024)) // 24 ticks = 1 µs
		put(data, off + 32, u32(1)); put(data, off + 44, u32(1)); put(data, off + 48, u32(3))
		put(data, off + 52, u32(38)); put(data, off + 68, i32(24))
	}
	return data
}

@(test)
ws_ring_decodes_sorted_events_and_refuses_bad_snapshots :: proc(t: ^testing.T) {
	data := ring_fixture()
	ring, err := shoji.ws_ring_decode(data)
	testing.expect_value(t, err, "")
	testing.expect_value(t, ring.calls, 300)
	testing.expect_value(t, ring.retained, 2)
	testing.expect_value(t, ring.events[0].sequence, 290)
	testing.expect_value(t, ring.events[1].sequence, 300)
	testing.expect_value(t, ring.events[1].held, 3)
	testing.expect_value(t, ring.events[1].ids[0], 38)
	testing.expect_value(t, ring.events[1].ops[0], 24)
	testing.expect_value(t, ring.events[1].duration_us, 1.0)
	_, short := shoji.ws_ring_decode(data[:100])
	testing.expect(t, short != "")
	torn := ring_fixture(); put(torn, 48, u32(1))
	_, torn_err := shoji.ws_ring_decode(torn)
	testing.expect(t, torn_err != "")
	future := ring_fixture(); put(future, shoji.WS_RING_HEADER, u64(301)) // sequence > calls
	_, future_err := shoji.ws_ring_decode(future)
	testing.expect(t, future_err != "")
	dup := ring_fixture(); put(dup, shoji.WS_RING_HEADER + 2 * shoji.WS_RING_STRIDE, u64(300))
	_, dup_err := shoji.ws_ring_decode(dup)
	testing.expect(t, dup_err != "")
}

@(test)
ws_clients_report_requires_trust_before_listing :: proc(t: ^testing.T) {
	self: [20]u8
	for i in 0 ..< 20 {self[i] = 0xab}
	listed := "0123456789abcdef0123456789abcdef01234567\nabababababababababababababababababababab\n"
	r := shoji.ws_clients_evaluate(listed, 0, 0o100644, 82, 0, 0o040755, self[:])
	testing.expect(t, r.trusted && r.listed)
	testing.expect_value(t, r.entries, 2)
	untrusted := shoji.ws_clients_evaluate(listed, 501, 0o100644, 82, 0, 0o040755, self[:])
	testing.expect(t, !untrusted.trusted && !untrusted.listed) // payload would ignore it
	other := shoji.ws_clients_evaluate("0123456789abcdef0123456789abcdef01234567", 0, 0o100644, 40, 0, 0o040755, self[:])
	testing.expect(t, other.trusted && !other.listed)
}

@(test)
ws_dump_reports_calls_only_when_serving :: proc(t: ^testing.T) {
	g: Fake_Gate
	fake_push(&g, 0)          // hello
	fake_push(&g, 0, 1234)    // dump
	a := fake_adapter(&g)
	calls, ok := shoji.ws_dump(&a)
	testing.expect(t, ok)
	testing.expect_value(t, calls, 1234)
	idle: shoji.Ws_Adapter
	_, idle_ok := shoji.ws_dump(&idle)
	testing.expect(t, !idle_ok)
}

@(test)
debug_ws_requires_daemon_hook :: proc(t: ^testing.T) {
	m: e.Manager
	defer e.manager_destroy(&m)
	testing.expect(t, e.execute(&m, []string{"debug", "ws", "status"}).failed)
	m.ws_debug = proc(_: rawptr, dump: bool) -> string {return dump ? "dumped" : "status"}
	r := e.execute(&m, []string{"debug", "ws", "dump"})
	testing.expect(t, !r.failed)
	testing.expect_value(t, r.text, "dumped")
	testing.expect(t, e.execute(&m, []string{"debug", "ws", "bogus"}).failed)
}
