package shoji

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

// Per-user state files in /tmp. Reads refuse symlinks, other owners and files
// over the caller's limit; writes go through mkstemp (mode 0600), fsync and an
// atomic rename, so a crash never leaves a partial file behind.

// The returned bytes use the temp allocator. found is false when no file exists.
private_file_read :: proc(path: string, limit: int) -> (bytes: []u8, found: bool, err: string) {
	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.NOFOLLOW, .NONBLOCK, .CLOEXEC})
	if fd < 0 {
		if posix.errno() == .ENOENT {return nil, false, ""}
		return nil, false, "cannot open"
	}
	defer posix.close(fd)
	info: posix.stat_t
	if posix.fstat(fd, &info) != nil || !posix.S_ISREG(info.st_mode) ||
	   u32(info.st_uid) != getuid() || info.st_size <= 0 || info.st_size > posix.off_t(limit) {
		return nil, true, "invalid file"
	}
	bytes = make([]u8, int(info.st_size), context.temp_allocator)
	offset := 0
	for offset < len(bytes) {
		n := posix.read(fd, raw_data(bytes[offset:]), uint(int(len(bytes)) - offset))
		if n < 0 && posix.errno() == .EINTR {continue}
		if n <= 0 {return nil, true, "cannot read"}
		offset += int(n)
	}
	return bytes, true, ""
}

private_file_write :: proc(path: string, bytes: []u8) -> string {
	temporary := strings.clone_to_cstring(fmt.tprintf("%s.XXXXXX", path), context.temp_allocator)
	fd := posix.mkstemp(temporary)
	if fd < 0 {return "cannot create"}
	defer posix.close(fd)
	defer posix.unlink(temporary)
	offset := 0
	for offset < len(bytes) {
		n := posix.write(fd, raw_data(bytes[offset:]), uint(int(len(bytes)) - offset))
		if n < 0 && posix.errno() == .EINTR {continue}
		if n <= 0 {return "cannot write"}
		offset += int(n)
	}
	if posix.fsync(fd) != nil || os.rename(string(temporary), path) != nil {
		return "cannot commit"
	}
	return ""
}
