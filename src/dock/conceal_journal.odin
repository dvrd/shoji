package dock

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

// Concealed windows outlive a Dock restart: WindowServer keeps the alpha and
// the empty event shape, but the payload's in-memory table does not. This
// file is that table. `boot` changes once per payload process so the daemon
// can tell a restarted Dock from a rewrite of the same process.

CONCEAL_JOURNAL_VERSION :: 1
CONCEAL_JOURNAL_LIMIT :: 256
CONCEAL_JOURNAL_BYTES :: 65536

Conceal_Record :: struct {
	window: u32,
	owner:  i32,
	client: i32,
}

Conceal_File :: struct {
	version: int,
	boot:    u64,
	entries: []Conceal_Record,
}

conceal_journal_path :: proc(uid: u32) -> string {
	return fmt.tprintf("/tmp/shoji-concealed_%d.json", uid)
}

conceal_journal_read :: proc(
	path: string,
) -> (
	file: Conceal_File,
	mtime: i64,
	found: bool,
	err: string,
) {
	fd := posix.open(
		strings.clone_to_cstring(path, context.temp_allocator),
		{.NOFOLLOW, .NONBLOCK, .CLOEXEC},
	)
	if fd < 0 {
		if posix.errno() == .ENOENT {
			return
		}
		return {}, 0, false, "cannot open"
	}
	defer posix.close(fd)
	info: posix.stat_t
	if posix.fstat(fd, &info) != nil ||
	   !posix.S_ISREG(info.st_mode) ||
	   info.st_uid != posix.getuid() ||
	   info.st_size <= 0 ||
	   info.st_size > CONCEAL_JOURNAL_BYTES {
		return {}, 0, true, "invalid file"
	}
	mtime = i64(info.st_mtim.tv_sec) * 1_000_000_000 + i64(info.st_mtim.tv_nsec)
	bytes := make([]u8, int(info.st_size), context.temp_allocator)
	offset := 0
	for offset < len(bytes) {
		n := posix.read(fd, raw_data(bytes[offset:]), uint(int(len(bytes)) - offset))
		if n < 0 && posix.errno() == .EINTR {
			continue
		}
		if n <= 0 {
			return {}, 0, true, "cannot read"
		}
		offset += int(n)
	}
	if json.unmarshal(bytes, &file, allocator = context.temp_allocator) != nil ||
	   file.version != CONCEAL_JOURNAL_VERSION ||
	   file.boot == 0 ||
	   len(file.entries) > CONCEAL_JOURNAL_LIMIT {
		return {}, 0, true, "invalid conceal journal"
	}
	for entry in file.entries {
		if entry.window == 0 || entry.owner == 0 || entry.client <= 0 {
			return {}, 0, true, "invalid conceal journal"
		}
	}
	return file, mtime, true, ""
}

// mtime is the file's modification time in nanoseconds. boot is zero when
// the file is absent or unreadable.
conceal_journal_stamp :: proc(path: string) -> (mtime: i64, boot: u64, ok: bool) {
	file, stamp, found, err := conceal_journal_read(path)
	if err != "" || !found {
		return
	}
	return stamp, file.boot, true
}

conceal_journal_write :: proc(path: string, boot: u64, entries: []Conceal_Record) -> string {
	if boot == 0 || len(entries) > CONCEAL_JOURNAL_LIMIT {
		return "invalid conceal journal"
	}
	for entry in entries {
		if entry.window == 0 || entry.owner == 0 || entry.client <= 0 {
			return "invalid conceal journal"
		}
	}
	stored := entries
	if stored == nil {
		stored = make([]Conceal_Record, 0, context.temp_allocator)
	}
	bytes, err := json.marshal(
		Conceal_File{CONCEAL_JOURNAL_VERSION, boot, stored},
		allocator = context.temp_allocator,
	)
	if err != nil {
		return "cannot encode conceal journal"
	}
	temporary := strings.clone_to_cstring(fmt.tprintf("%s.XXXXXX", path), context.temp_allocator)
	fd := posix.mkstemp(temporary)
	if fd < 0 {
		return "cannot create"
	}
	defer posix.close(fd)
	defer posix.unlink(temporary)
	offset := 0
	for offset < len(bytes) {
		n := posix.write(fd, raw_data(bytes[offset:]), uint(int(len(bytes)) - offset))
		if n < 0 && posix.errno() == .EINTR {
			continue
		}
		if n <= 0 {
			return "cannot write"
		}
		offset += int(n)
	}
	if posix.fsync(fd) != nil || os.rename(string(temporary), path) != nil {
		return "cannot commit"
	}
	return ""
}
