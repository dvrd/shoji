package shoji

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:time"
import layout "layout"

// Scroll layout persistence
// ------------------------------------------------------------------------
// Column membership, row order, the active tab and each column's width,
// full-width and tabbed state survive a daemon restart. Window IDs live as
// long as their app's WindowServer connection, so the snapshot sits in /tmp
// (gone after a reboot, when the IDs are too) and every window must match its
// saved ID and owning PID before it is placed. Windows that are gone are
// skipped; windows the snapshot does not know keep the place they opened in.

LAYOUT_SNAPSHOT_VERSION :: 1
LAYOUT_SNAPSHOT_BYTES :: 1 << 20
LAYOUT_SNAPSHOT_SPACES :: 64
LAYOUT_SNAPSHOT_SAVE_INTERVAL :: 2 * time.Second
// shojirc sets Space layouts, so restore waits for it, bounded like the ring
// hold so a hung config cannot keep the snapshot from ever applying.
LAYOUT_SNAPSHOT_RESTORE_WAIT :: 20 * time.Second

Snapshot_Window :: struct {
	id:  u32,
	pid: i32,
}
Snapshot_Column :: struct {
	windows:    []Snapshot_Window, // row order
	order:      []u32, // most recent first; order[0] is the active tab
	size_kind:  int,
	size_value: f64,
	width:      f64,
	preset:     int, // -1 when unset
	full:       bool,
	tabbed:     bool,
}
Snapshot_Space :: struct {
	uuid:    string,
	columns: []Snapshot_Column,
}
Snapshot_Data :: struct {
	version: int,
	spaces:  []Snapshot_Space,
}

Layout_Snapshot :: struct {
	path:      string,
	restored:  bool,
	started:   time.Time,
	next_save: time.Time,
	saved:     []u8, // last bytes written, heap-owned
}

layout_snapshot_open :: proc(snap: ^Layout_Snapshot, path: string, now: time.Time) {
	snap^ = {path = path, started = now}
}

// Saves a final snapshot, but only once the startup restore has run: before
// that the layout is the unrestored one and would overwrite the saved state.
layout_snapshot_close :: proc(snap: ^Layout_Snapshot, m: ^Manager) {
	if snap.path != "" && snap.restored {layout_snapshot_save(snap, m)}
	delete(snap.saved)
	delete(snap.path)
	snap^ = {}
}

layout_snapshot_tick :: proc(state: ^State, config_finished: bool, now: time.Time) {
	snap := &state.layout_snapshot
	if snap.path == "" {return}
	if !snap.restored {
		if !config_finished && time.diff(snap.started, now) < LAYOUT_SNAPSHOT_RESTORE_WAIT {return}
		snap.restored = true
		snap.next_save = time.time_add(now, LAYOUT_SNAPSHOT_SAVE_INTERVAL)
		if err := layout_snapshot_load(snap, &state.manager); err != "" {
			fmt.eprintln("shoji: layout snapshot:", err)
		}
		return
	}
	if time.diff(now, snap.next_save) > 0 {return}
	snap.next_save = time.time_add(now, LAYOUT_SNAPSHOT_SAVE_INTERVAL)
	layout_snapshot_save(snap, &state.manager)
}

layout_snapshot_save :: proc(snap: ^Layout_Snapshot, m: ^Manager) {
	bytes, err := json.marshal(layout_snapshot_capture(m), allocator = context.temp_allocator)
	if err != nil || len(bytes) > LAYOUT_SNAPSHOT_BYTES {
		fmt.eprintln("shoji: layout snapshot: cannot encode")
		return
	}
	if slice.equal(bytes, snap.saved) {return}
	if write_error := private_file_write(snap.path, bytes); write_error != "" {
		fmt.eprintln("shoji: layout snapshot:", write_error)
		return
	}
	delete(snap.saved)
	snap.saved = slice.clone(bytes)
}

layout_snapshot_load :: proc(snap: ^Layout_Snapshot, m: ^Manager) -> string {
	bytes, found, read_error := private_file_read(snap.path, LAYOUT_SNAPSHOT_BYTES)
	if !found && read_error == "" {return ""}
	if read_error != "" {return read_error}
	data: Snapshot_Data
	if json.unmarshal(bytes, &data, allocator = context.temp_allocator) != nil ||
	   data.version != LAYOUT_SNAPSHOT_VERSION ||
	   len(data.spaces) > LAYOUT_SNAPSHOT_SPACES {
		return "invalid snapshot data"
	}
	layout_snapshot_restore(m, data)
	return ""
}

layout_snapshot_capture :: proc(m: ^Manager) -> Snapshot_Data {
	spaces := make([dynamic]Snapshot_Space, 0, len(m.spaces), context.temp_allocator)
	for s in m.spaces {
		if s.view.layout != .Scroll || s.uuid == "" || len(spaces) == LAYOUT_SNAPSHOT_SPACES {continue}
		columns := make([dynamic]Snapshot_Column, 0, 8, context.temp_allocator)
		for n := layout.first(s.view.root); n != nil; n = layout.next(n) {
			if n.count > 0 {append(&columns, snapshot_column(m, n))}
		}
		if len(columns) > 0 {append(&spaces, Snapshot_Space{s.uuid, columns[:]})}
	}
	return {LAYOUT_SNAPSHOT_VERSION, spaces[:]}
}

snapshot_column :: proc(m: ^Manager, n: ^layout.Node) -> Snapshot_Column {
	windows := make([]Snapshot_Window, n.count, context.temp_allocator)
	for i in 0 ..< n.count {
		pid: i32
		if w := m.windows[n.windows[i]]; w != nil {pid = w.pid}
		windows[i] = {n.windows[i], pid}
	}
	return {
		windows = windows,
		order = slice.clone(n.order[:n.count], context.temp_allocator),
		size_kind = int(n.column_size.kind),
		size_value = n.column_size.value,
		width = n.column_width,
		preset = n.column_preset.? or_else -1,
		full = n.column_full,
		tabbed = n.column_tabbed,
	}
}

layout_snapshot_restore :: proc(m: ^Manager, data: Snapshot_Data) {
	for space in data.spaces {
		s: ^Space
		for candidate in m.spaces {if candidate.uuid == space.uuid {s = candidate; break}}
		if s == nil || s.view.layout != .Scroll {continue}
		if snapshot_restore_space(m, s, space) == 0 {continue}
		if err := flush(m, s); err != "" {fmt.eprintln("shoji: layout snapshot:", err)}
	}
}

// Restored columns are rebuilt left to right in front of the windows the
// snapshot does not know, each one after the previously restored column.
snapshot_restore_space :: proc(m: ^Manager, s: ^Space, space: Snapshot_Space) -> (columns: int) {
	v := &s.view
	anchor: u32
	for column in space.columns {
		ids := snapshot_live_windows(m, s, column)
		if len(ids) == 0 {continue}
		for id in ids {layout.remove(v, id)}
		if !snapshot_place_column(v, ids, anchor) {continue}
		snapshot_apply_column(layout.find(v.root, ids[0]), column, ids)
		anchor = ids[0]
		columns += 1
	}
	return
}

// Saved windows that still exist, are owned by the same process and are tiled
// on this Space, in saved row order (temp allocator).
snapshot_live_windows :: proc(m: ^Manager, s: ^Space, column: Snapshot_Column) -> []u32 {
	ids := make([dynamic]u32, 0, len(column.windows), context.temp_allocator)
	for saved in column.windows {
		if len(ids) == layout.MAX_STACK || slice.contains(ids[:], saved.id) {continue}
		w := m.windows[saved.id]
		if w == nil || w.pid != saved.pid || w.space != s.id || !layout_admitted(w) {continue}
		if layout.find(s.view.root, saved.id) == nil {continue}
		append(&ids, saved.id)
	}
	return ids[:]
}

snapshot_place_column :: proc(v: ^layout.View, ids: []u32, anchor: u32) -> bool {
	target := layout.find(v.root, anchor)
	before := false
	if target == nil {
		target = layout.first(v.root)
		before = true
	}
	if target != nil && target.count > 0 {
		// Same insertion as a returning column (scroll_return_restore).
		anchor_id := target.windows[0]
		insert_first, insert_stack, insertion := target.insert_first, target.insert_stack, v.insertion
		target.insert_first, target.insert_stack = before, false
		ok := layout.add(v, ids[0], anchor_id)
		if old := layout.find(v.root, anchor_id); old != nil {
			old.insert_first, old.insert_stack = insert_first, insert_stack
		}
		v.insertion = insertion
		if !ok {return false}
	} else if !layout.add(v, ids[0]) {
		return false
	}
	n := layout.find(v.root, ids[0])
	for id in ids[1:] {
		// Cannot overflow: ids holds at most MAX_STACK windows.
		pushed := layout.stack_push(n, id)
		assert(pushed)
	}
	return true
}

snapshot_apply_column :: proc(n: ^layout.Node, column: Snapshot_Column, ids: []u32) {
	assert(n != nil && n.count == len(ids))
	for id, i in ids {n.windows[i] = id}
	count := 0
	for id in column.order {
		if count < n.count && slice.contains(ids, id) && !slice.contains(n.order[:count], id) {
			n.order[count] = id
			count += 1
		}
	}
	for id in ids {
		if count < n.count && !slice.contains(n.order[:count], id) {
			n.order[count] = id
			count += 1
		}
	}
	n.column_tabbed, n.column_full = column.tabbed, column.full
	if column.size_kind >= 0 && column.size_kind <= 2 && !math.is_nan(column.size_value) {
		n.column_size = {kind = type_of(n.column_size.kind)(column.size_kind), value = column.size_value}
	}
	if column.width > 0 && !math.is_inf(column.width) {
		n.column_width, n.column_resolved = column.width, column.width
	}
	n.column_preset = nil
	if column.preset >= 0 {n.column_preset = column.preset}
}
