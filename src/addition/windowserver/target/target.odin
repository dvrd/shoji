package target

PATH :: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"
CANONICAL_PATH :: "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer"
UID :: u32(88)
EXPERIMENT_ENV :: "SHOJI_WINDOWSERVER_EXPERIMENT"

valid_pid :: proc(pid: i32) -> bool {
	return pid > 0
}

valid_path :: proc(path: string) -> bool {
	return path == PATH || path == CANONICAL_PATH
}

validate :: proc(pid: i32, path: string) -> string {
	if !valid_pid(pid) {
		return "WindowServer injection requires a positive process ID"
	}
	if !valid_path(path) {
		return "target process is not the system WindowServer"
	}
	return ""
}
