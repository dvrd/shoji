package tests

import mac "../src"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "core:testing"
import layout "../src/layout"

@(private = "file")
snapshot_fixture :: proc(m: ^mac.Manager, r: ^Recorder) {
	niri_fixture(m, r)
	m.spaces[0].uuid = strings.clone("SPACE-A")
	niri_open(m, 2); niri_open(m, 3); niri_open(m, 4)
	// Columns: [1] [2,3 tabbed, 3 active] [4 at half width]
	mac.execute(m, {"window", "2", "--stack", "3"})
	mac.execute(m, {"window", "2", "--column-display", "tabbed"})
	mac.execute(m, {"window", "3", "--focus"})
	mac.execute(m, {"window", "4", "--column-width", "abs:500"})
}

@(private = "file")
strip :: proc(m: ^mac.Manager) -> (columns: [dynamic][]u32) {
	columns = make([dynamic][]u32, context.temp_allocator)
	for n := layout.first(m.spaces[0].view.root); n != nil; n = layout.next(n) {
		append(&columns, n.windows[:n.count])
	}
	return
}

@(private = "file")
scatter :: proc(m: ^mac.Manager) {
	// What a fresh daemon sees: every window in its own column, defaults only.
	v := &m.spaces[0].view
	for id in ([4]u32{1, 2, 3, 4}) {layout.remove(v, id)}
	for id in ([4]u32{4, 3, 2, 1}) {layout.add(v, id)}
	mac.flush(m, m.spaces[0])
}

@(test)
layout_snapshot_restores_tabbed_columns_after_restart :: proc(t: ^testing.T) {
	m: mac.Manager; r: Recorder; snapshot_fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	data := mac.layout_snapshot_capture(&m)
	scatter(&m)
	testing.expect_value(t, len(strip(&m)), 4)
	mac.layout_snapshot_restore(&m, data)
	columns := strip(&m)
	if !testing.expect_value(t, len(columns), 3) {return}
	testing.expect_value(t, columns[0][0], 1)
	testing.expect_value(t, len(columns[1]), 2)
	testing.expect_value(t, columns[1][0], 2); testing.expect_value(t, columns[1][1], 3)
	testing.expect_value(t, columns[2][0], 4)
	tabs := layout.find(m.spaces[0].view.root, 2)
	testing.expect(t, tabs.column_tabbed)
	testing.expect_value(t, tabs.order[0], 3)
	testing.expect_value(t, layout.find(m.spaces[0].view.root, 4).column_width, 500)
}

@(test)
layout_snapshot_skips_reused_ids_and_keeps_unknown_windows :: proc(t: ^testing.T) {
	m: mac.Manager; r: Recorder; snapshot_fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	data := mac.layout_snapshot_capture(&m)
	scatter(&m)
	// Window 3's ID now belongs to another process; window 5 is new.
	m.windows[3].pid = 999
	niri_open(&m, 5)
	mac.layout_snapshot_restore(&m, data)
	tabs := layout.find(m.spaces[0].view.root, 2)
	testing.expect_value(t, tabs.count, 1)
	testing.expect(t, tabs.column_tabbed)
	testing.expect(t, layout.find(m.spaces[0].view.root, 3) != tabs)
	testing.expect(t, layout.find(m.spaces[0].view.root, 5) != nil)
	// Restored columns lead the strip, in saved order.
	columns := strip(&m)
	testing.expect_value(t, columns[0][0], 1)
	testing.expect_value(t, columns[1][0], 2)
	testing.expect_value(t, columns[2][0], 4)
}

@(test)
layout_snapshot_ignores_spaces_it_does_not_know :: proc(t: ^testing.T) {
	m: mac.Manager; r: Recorder; snapshot_fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	data := mac.layout_snapshot_capture(&m)
	scatter(&m)
	delete(m.spaces[0].uuid); m.spaces[0].uuid = strings.clone("SPACE-B")
	mac.layout_snapshot_restore(&m, data)
	testing.expect_value(t, len(strip(&m)), 4)
}

@(test)
layout_snapshot_file_is_written_only_after_restore_and_reloads :: proc(t: ^testing.T) {
	m: mac.Manager; r: Recorder; snapshot_fixture(&m, &r)
	defer mac.manager_destroy(&m); defer delete(r.actions)
	path := fmt.tprintf("/tmp/shoji-layout-test_%d.json", posix.getpid())
	defer posix.unlink(strings.clone_to_cstring(path, context.temp_allocator))
	snap: mac.Layout_Snapshot
	// A daemon stopped before its restore must not overwrite the saved layout.
	mac.layout_snapshot_open(&snap, strings.clone(path), time.now())
	mac.layout_snapshot_close(&snap, &m)
	_, found, _ := mac.private_file_read(path, 1 << 20)
	testing.expect(t, !found)
	mac.layout_snapshot_open(&snap, strings.clone(path), time.now())
	snap.restored = true
	mac.layout_snapshot_close(&snap, &m)
	_, found, _ = mac.private_file_read(path, 1 << 20)
	testing.expect(t, found)
	scatter(&m)
	mac.layout_snapshot_open(&snap, strings.clone(path), time.now())
	testing.expect_value(t, mac.layout_snapshot_load(&snap, &m), "")
	mac.layout_snapshot_close(&snap, &m)
	testing.expect(t, layout.find(m.spaces[0].view.root, 2).column_tabbed)
	testing.expect_value(t, len(strip(&m)), 3)
}
