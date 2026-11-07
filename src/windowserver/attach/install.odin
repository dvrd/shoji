package attach

// Install locations and host facts shared by `--ws-attach`, the daemon and
// `--ws-report`.

import "core:fmt"
import "core:strings"
import "core:sys/posix"

WS_PAYLOAD_DIR :: "/Library/GPUBundles/ShojiWindowServerProbe"
WS_DISABLE_SENTINEL :: WS_PAYLOAD_DIR + "/DISABLED"
WS_PAYLOAD_PATH :: WS_PAYLOAD_DIR + "/shoji-ws.dylib"
WS_CLIENTS_PATH :: WS_PAYLOAD_DIR + "/clients"

// `--ws-attach` exit status for refusals that a retry cannot fix.
WS_ATTACH_EXIT_REFUSED :: 3

foreign import attach_system_info "system:System"
@(default_calling_convention = "c")
foreign attach_system_info {
	sysctlbyname :: proc(name: cstring, old: rawptr, oldlen: ^uintptr, new_value: rawptr, newlen: uintptr) -> i32 ---
	csops :: proc(pid: i32, ops: u32, useraddr: rawptr, usersize: uintptr) -> i32 ---
}

hex :: proc(bytes: []u8) -> string {
	b := strings.builder_make(context.temp_allocator)
	for v in bytes {fmt.sbprintf(&b, "%02x", v)}
	return strings.to_string(b)
}

os_build :: proc() -> string {
	build: [32]u8
	length := uintptr(len(build))
	if sysctlbyname("kern.osversion", &build[0], &length, nil, 0) != 0 || length == 0 {return "unknown"}
	return strings.clone(string(build[:length - 1]), context.temp_allocator)
}

read_limited :: proc(path: string, limit: int) -> (data: []u8, st: posix.stat_t, ok: bool) {
	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.NOFOLLOW, .CLOEXEC})
	if fd < 0 {return}
	defer posix.close(fd)
	if posix.fstat(fd, &st) != .OK || i64(st.st_size) <= 0 || i64(st.st_size) > i64(limit) {return}
	data = make([]u8, int(st.st_size), context.temp_allocator)
	if i64(posix.read(fd, &data[0], len(data))) != i64(st.st_size) {return}
	return data, st, true
}
