package shoji

import dock "dock"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"

foreign import recovery_sls "system:SkyLight.framework"

// Animation recovery journal
// ------------------------------------------------------------------------

Animation_Journal :: struct {
	path: string,
	entries: map[u32]dock.Entry,
	next_retry: time.Time,
}
Journal_Data :: struct {
	version: int,
	entries: []dock.Entry,
}
JOURNAL_LIMIT :: 256
animation_journal_close :: proc(j: ^Animation_Journal) {
	delete(j.path); delete(j.entries); j^ = {}
}
animation_journal_open :: proc(j: ^Animation_Journal, path: string) -> string {
	j.path = strings.clone(path)
	j.entries = make(map[u32]dock.Entry)
	bytes, found, read_error := private_file_read(path, 65536)
	if !found && read_error == "" {
		return ""
	}
	if read_error != "" {
		return fmt.tprintf("animation recovery journal: %s", read_error)
	}
	data: Journal_Data
	if json.unmarshal(bytes, &data, allocator = context.temp_allocator) !=
		   nil ||
	   data.version != 1 ||
	   len(data.entries) > JOURNAL_LIMIT {
		return "invalid animation recovery journal data"
	}
	for entry in data.entries {
		if entry.window == 0 ||
		   entry.proxy == 0 ||
		   entry.owner == 0 ||
		   entry.proxy_owner == 0 ||
		   entry.window in j.entries {
			return "invalid animation recovery entry"
		}
		j.entries[entry.window] = entry
	}
	return ""
}
animation_journal_save :: proc(j: ^Animation_Journal) -> string {
	if j.path == "" {
		return "animation recovery journal is unavailable"
	}
	entries := make(
		[dynamic]dock.Entry,
		0,
		len(j.entries),
		context.temp_allocator,
	)
	for _, entry in j.entries { append(&entries, entry) }
	bytes, err := json.marshal(
		Journal_Data{1, entries[:]},
		allocator = context.temp_allocator,
	)
	if err != nil {
		return "cannot encode animation recovery journal"
	}
	// A crash must not leave a partial journal after a window was hidden.
	if write_error := private_file_write(j.path, bytes); write_error != "" {
		return fmt.tprintf("animation recovery journal: %s", write_error)
	}
	return ""
}
animation_journal_record :: proc(
	j: ^Animation_Journal,
	entry: dock.Entry,
) -> string {
	if entry.window in j.entries {
		return "window has unfinished animation recovery"
	}
	if len(j.entries) >= JOURNAL_LIMIT {
		return "animation recovery journal is full"
	}
	j.entries[entry.window] = entry
	if err := animation_journal_save(j); err != "" {
		delete_key(&j.entries, entry.window); return err
	}
	return ""
}
animation_journal_remove :: proc(
	j: ^Animation_Journal,
	window: u32,
) -> string {
	entry, exists := j.entries[window]
	if !exists {
		return ""
	}
	delete_key(&j.entries, window)
	if err := animation_journal_save(j); err != "" {
		j.entries[window] = entry; return err
	}
	return ""
}
animation_recovery_owner :: proc(user: rawptr, window: u32) -> (i32, bool) {
	state := (^State)(user)
	owner: i32
	if window == 0 {
		return owner, false
	}
	return animation_recovery_query_owner(state.connection, window)
}
foreign recovery_sls {
	SLSGetWindowOwner :: proc "c" (cid: i32, window: u32, owner: ^i32) -> i32 ---
}
animation_recovery_query_owner :: proc(cid: i32, window: u32) -> (i32, bool) {
	owner: i32
	code := SLSGetWindowOwner(cid, window, &owner)
	return owner, code == 0
}
animation_recovery_restore :: proc(
	user: rawptr,
	entry: dock.Entry,
	proxy_valid: bool,
) -> bool {
	return(
		animation_swap(
			{window = entry.window, id = proxy_valid ? entry.proxy : 0},
			false,
		) ==
		"" \
	)
}
animation_recovery_tick :: proc(state: ^State, now: time.Time) {
	j := &state.animation_journal
	if len(j.entries) == 0 || time.diff(now, j.next_retry) > 0 {
		return
	}
	j.next_retry = time.time_add(now, time.Second)
	// A unavailable Dock must not cause journal entries to be discarded.
	if _, err := addition_check(); err != "" {
		return
	}
	windows := make([dynamic]u32, context.temp_allocator)
	backend := dock.Backend {
		animation_recovery_owner,
		animation_recovery_restore,
		state,
	}
	for window, entry in j.entries {
		if window in state.animations || window in state.opening_guards {
			continue
		}
		result := dock.restore(entry, backend, false)
		if result == .Restored || result == .Gone {
			append(&windows, window)
		}
	}
	for window in windows {
		if err := animation_journal_remove(j, window); err != "" {
			fmt.eprintln("shoji:", err)
		}
	}
}
