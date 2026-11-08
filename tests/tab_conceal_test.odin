package tests

import mac "../src"
import dock "../src/dock"
import layout "../src/layout"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:testing"

@(private = "file")
conceals :: proc(r: ^Recorder) -> (on, off: [dynamic]u32) {
	on = make([dynamic]u32, context.temp_allocator)
	off = make([dynamic]u32, context.temp_allocator)
	for a in r.actions {
		if a.kind != .Conceal {continue}
		if a.flag {append(&on, a.window)} else {append(&off, a.window)}
	}
	return
}

@(private = "file")
tab_fixture :: proc(m: ^mac.Manager, r: ^Recorder) {
	niri_fixture(m, r)
	niri_open(m, 2); niri_open(m, 3); niri_open(m, 4)
	mac.execute(m, {"window", "1", "--stack", "2"})
	mac.execute(m, {"window", "1", "--stack", "3"})
	mac.execute(m, {"window", "1", "--column-display", "tabbed"})
	mac.execute(m, {"window", "2", "--focus"})
	mac.execute(m, {"window", "1", "--focus"})
}

@(private = "file")
tab_order :: proc(m: ^mac.Manager, member: u32 = 1) -> []u32 {
	n := layout.find(m.spaces[0].view.root, member)
	return n.order[:n.count]
}

@(private = "file")
expect_hidden :: proc(t: ^testing.T, m: ^mac.Manager, hidden: ..u32) {
	for id, w in m.windows {
		want := false
		for h in hidden {if h == id {want = true}}
		testing.expectf(t, w.concealed == want, "window %d concealed=%v", id, w.concealed)
	}
}

@(test)
tab_conceal_hides_tabs_beyond_the_active_and_standby :: proc(t: ^testing.T) {
	m: mac.Manager; r: Recorder; tab_fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	// Off by default: tabs keep today's ordering only.
	on, off := conceals(&r)
	testing.expect_value(t, len(on) + len(off), 0)
	order := tab_order(&m)
	testing.expect_value(t, order[0], 1); testing.expect_value(t, order[1], 2)
	testing.expect(t, !mac.config(&m, {"tab_conceal", "on"}).failed)
	// 1 is active, 2 is the standby drawn behind it; only 3 is concealed.
	expect_hidden(t, &m, 3)
	// Switching tabs: 3 becomes active, 1 the standby, 2 is concealed.
	resize(&r.actions, 0)
	mac.execute(&m, {"window", "3", "--focus"})
	expect_hidden(t, &m, 2)
	first_reveal, first_conceal := -1, -1
	for a, i in r.actions {
		if a.kind != .Conceal {continue}
		if !a.flag && first_reveal < 0 {first_reveal = i}
		if a.flag && first_conceal < 0 {first_conceal = i}
	}
	testing.expect(t, first_reveal >= 0 && first_reveal < first_conceal)
	// A steady layout sends nothing more.
	resize(&r.actions, 0)
	mac.flush(&m, m.spaces[0])
	on, off = conceals(&r)
	testing.expect_value(t, len(on) + len(off), 0)
}

@(test)
tab_conceal_keeps_a_drawn_tab_under_closing_and_opening_tabs :: proc(t: ^testing.T) {
	m: mac.Manager; r: Recorder; tab_fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	mac.config(&m, {"tab_conceal", "on"})
	// Closing the active tab exposes the standby, which was never hidden.
	mac.remove_window(&m, 1)
	testing.expect(t, !m.windows[2].concealed)
	mac.flush(&m, m.spaces[0])
	expect_hidden(t, &m)
	// A new tab becomes active; the previous active one stays drawn under it.
	mac.execute(&m, {"window", "2", "--insert", "stack"})
	niri_open(&m, 5)
	testing.expect_value(t, tab_order(&m, 2)[0], 5)
	testing.expect(t, !m.windows[2].concealed)
	expect_hidden(t, &m, 3)
}

@(test)
tab_conceal_reveals_when_the_column_stops_being_tabbed_or_is_disabled :: proc(t: ^testing.T) {
	m: mac.Manager; r: Recorder; tab_fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	mac.config(&m, {"tab_conceal", "on"})
	expect_hidden(t, &m, 3)
	mac.execute(&m, {"window", "1", "--column-display", "normal"})
	expect_hidden(t, &m)
	mac.execute(&m, {"window", "1", "--column-display", "tabbed"})
	expect_hidden(t, &m, 3)
	mac.config(&m, {"tab_conceal", "off"})
	expect_hidden(t, &m)
	mac.config(&m, {"tab_conceal", "on"})
	mac.tab_conceal_release(&m)
	expect_hidden(t, &m)
}

@(test)
tab_conceal_refusal_keeps_ordering_and_does_not_retry_every_flush :: proc(t: ^testing.T) {
	m: mac.Manager; r: Recorder; tab_fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	m.tab_conceal = true
	r.fail = true
	calls := r.calls
	testing.expect_value(t, mac.flush(&m, m.spaces[0]), "")
	testing.expect(t, !m.windows[3].concealed && m.windows[3].conceal_refused)
	attempts := r.calls - calls
	mac.flush(&m, m.spaces[0])
	testing.expect_value(t, r.calls - calls, attempts)
	// Leaving the concealed set clears the refusal, so a later turn retries.
	r.fail = false
	mac.execute(&m, {"window", "3", "--focus"})
	testing.expect(t, !m.windows[3].conceal_refused)
	testing.expect(t, m.windows[2].concealed)
}

@(private = "file")
columns :: proc(m: ^mac.Manager) -> (ids: [dynamic][]u32, tabbed: [dynamic]bool) {
	ids = make([dynamic][]u32, context.temp_allocator)
	tabbed = make([dynamic]bool, context.temp_allocator)
	for n := layout.first(m.spaces[0].view.root); n != nil; n = layout.next(n) {
		append(&ids, n.windows[:n.count]); append(&tabbed, n.column_tabbed)
	}
	return
}

@(private = "file")
expect_columns :: proc(t: ^testing.T, m: ^mac.Manager, want: [][]u32, want_tabbed: []bool) {
	ids, tabbed := columns(m)
	if !testing.expect_value(t, len(ids), len(want)) {return}
	for c, i in want {
		testing.expect_value(t, len(ids[i]), len(c))
		for id, j in c {if j < len(ids[i]) {testing.expect_value(t, ids[i][j], id)}}
		testing.expect_value(t, tabbed[i], want_tabbed[i])
	}
}

@(private = "file")
tabbed_strip :: proc(m: ^mac.Manager, r: ^Recorder, top: bool) {
	niri_fixture(m, r)
	niri_open(m, 2); niri_open(m, 3); niri_open(m, 4)
	mac.execute(m, {"window", "2", "--stack", "3"})
	mac.execute(m, {"window", "2", "--column-display", "tabbed"})
	mac.execute(m, {"config", "tab_indicator_position", top ? "top" : "left"})
	mac.execute(m, {"window", "3", "--focus"})
}

@(test)
conceal_journal_round_trips_and_rejects_bad_records :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/shoji-test-concealed-round-%d.json", posix.getpid())
	defer posix.unlink(strings.clone_to_cstring(path, context.temp_allocator))
	entries := []dock.Conceal_Record{
		{window = 1, owner = 2, client = 3},
		{window = 4, owner = 5, client = 6},
	}
	testing.expect_value(t, dock.conceal_journal_write(path, 1, entries), "")
	file, mtime, found, err := dock.conceal_journal_read(path)
	testing.expect(t, found && err == "")
	testing.expect(t, mtime != 0)
	testing.expect_value(t, file.boot, u64(1))
	testing.expect_value(t, len(file.entries), 2)
	testing.expect_value(t, file.entries[1].window, u32(4))
	testing.expect(t, dock.conceal_journal_write(path, 0, entries) != "")
	testing.expect(t, dock.conceal_journal_write(path, 1, []dock.Conceal_Record{{window = 1, owner = 2, client = 0}}) != "")
	// The failed writes must leave the previous file intact.
	again, _, found_again, err_again := dock.conceal_journal_read(path)
	testing.expect(t, found_again && err_again == "")
	testing.expect_value(t, again.boot, u64(1))
}

@(test)
conceal_boot_change_retries_a_refused_tab :: proc(t: ^testing.T) {
	m: mac.Manager; r: Recorder; tab_fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	path := fmt.tprintf("/tmp/shoji-test-concealed-boot-%d.json", posix.getpid())
	defer posix.unlink(strings.clone_to_cstring(path, context.temp_allocator))
	testing.expect_value(t, dock.conceal_journal_write(path, 1, nil), "")
	_, mtime, found, err := dock.conceal_journal_read(path)
	testing.expect(t, found && err == "" && mtime != 0)
	m.conceal_journal = strings.clone(path)
	m.conceal_boot = 1
	m.conceal_stamp = mtime
	m.tab_conceal = true
	r.fail = true
	calls := r.calls
	testing.expect_value(t, mac.flush(&m, m.spaces[0]), "")
	testing.expect(t, !m.windows[3].concealed && m.windows[3].conceal_refused)
	attempts := r.calls - calls
	mac.flush(&m, m.spaces[0])
	testing.expect_value(t, r.calls - calls, attempts)
	testing.expect_value(t, dock.conceal_journal_write(path, 2, nil), "")
	r.fail = false
	mac.flush(&m, m.spaces[0])
	testing.expect(t, !m.windows[3].conceal_refused)
	testing.expect(t, m.windows[3].concealed)
	testing.expect(t, r.calls - calls > attempts)
}

@(test)
tab_swap_reorders_tabs_then_moves_the_whole_tabbed_column :: proc(t: ^testing.T) {
	m: mac.Manager; r: Recorder; tabbed_strip(&m, &r, true)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	expect_columns(t, &m, {{1}, {2, 3}, {4}}, {false, true, false})
	// Top bar: west/east reorder tabs inside the column first.
	testing.expect(t, !mac.execute(&m, {"window", "--swap", "west"}).failed)
	expect_columns(t, &m, {{1}, {3, 2}, {4}}, {false, true, false})
	// At the first tab the column itself moves, keeping its tabbed display.
	testing.expect(t, !mac.execute(&m, {"window", "--swap", "west"}).failed)
	expect_columns(t, &m, {{3, 2}, {1}, {4}}, {true, false, false})
	testing.expect(t, !mac.execute(&m, {"window", "--swap", "east"}).failed)
	expect_columns(t, &m, {{2, 3}, {1}, {4}}, {true, false, false})
	testing.expect(t, !mac.execute(&m, {"window", "--swap", "east"}).failed)
	expect_columns(t, &m, {{1}, {2, 3}, {4}}, {false, true, false})
	testing.expect_value(t, m.focused, 3)
}

@(test)
tab_swap_with_left_bar_reorders_on_north_south :: proc(t: ^testing.T) {
	m: mac.Manager; r: Recorder; tabbed_strip(&m, &r, false)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	testing.expect(t, !mac.execute(&m, {"window", "--swap", "north"}).failed)
	expect_columns(t, &m, {{1}, {3, 2}, {4}}, {false, true, false})
	testing.expect(t, !mac.execute(&m, {"window", "--swap", "south"}).failed)
	expect_columns(t, &m, {{1}, {2, 3}, {4}}, {false, true, false})
	// West/east still move the whole column.
	testing.expect(t, !mac.execute(&m, {"window", "--swap", "west"}).failed)
	expect_columns(t, &m, {{2, 3}, {1}, {4}}, {true, false, false})
}
