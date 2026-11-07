package shoji

import dock "dock"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
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
	fd := posix.open(
		strings.clone_to_cstring(path, context.temp_allocator),
		{.NOFOLLOW, .NONBLOCK, .CLOEXEC},
	)
	if fd < 0 {
		if posix.errno() == .ENOENT {
			return ""
		}
		return "cannot open animation recovery journal"
	}
	defer posix.close(fd)
	info: posix.stat_t
	if posix.fstat(fd, &info) != nil ||
	   !posix.S_ISREG(info.st_mode) ||
	   u32(info.st_uid) != getuid() ||
	   info.st_size <= 0 ||
	   info.st_size > 65536 {
		return "invalid animation recovery journal file"
	}
	bytes := make([]u8, int(info.st_size), context.temp_allocator)
	offset := 0
	for offset < len(bytes) {
		n := posix.read(
			fd,
			raw_data(bytes[offset:]),
			uint(int(len(bytes)) - offset),
		)
		if n < 0 && posix.errno() == .EINTR {
			continue
		}
		if n <= 0 {
			return "cannot read animation recovery journal"
		}
		offset += int(n)
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
	// mkstemp creates mode 0600. fsync before atomic rename ensures a crash
	// cannot leave a partial journal after the real window has been hidden.
	temporary := strings.clone_to_cstring(
		fmt.tprintf("%s.XXXXXX", j.path),
		context.temp_allocator,
	)
	fd := posix.mkstemp(temporary)
	if fd < 0 {
		return "cannot create animation recovery journal"
	}
	defer posix.close(fd)
	defer posix.unlink(temporary)
	offset := 0
	for offset < len(bytes) {
		n := posix.write(
			fd,
			raw_data(bytes[offset:]),
			uint(int(len(bytes)) - offset),
		)
		if n < 0 && posix.errno() == .EINTR {
			continue
		}
		if n <= 0 {
			return "cannot write animation recovery journal"
		}
		offset += int(n)
	}
	if posix.fsync(fd) != nil || os.rename(string(temporary), j.path) != nil {
		return "cannot commit animation recovery journal"
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
