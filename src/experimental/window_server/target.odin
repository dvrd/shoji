package experimental

PATH :: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"
CANONICAL_PATH :: "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer"
UID :: u32(88)
EXPERIMENT_ENV :: "SHOJI_WINDOWSERVER_EXPERIMENT"

// Exact extracted SkyLight identity observed in the disposable 26A434 guest.
// These constants are experiment gates, not addresses for another build.
ORDERING_IMAGE_UUID :: [16]u8{0x8a, 0x3b, 0x34, 0x8e, 0x46, 0x37, 0x36, 0x85, 0x92, 0xd0, 0x6c, 0xbc, 0x2f, 0x36, 0xa2, 0x34}
ORDERING_UNSLID_ENTRY :: u64(0x1873f6260)
ORDERING_ENTRY_SIGNATURE :: [16]u8{0x7f, 0x23, 0x03, 0xd5, 0xfc, 0x6f, 0xba, 0xa9, 0xfa, 0x67, 0x01, 0xa9, 0xf8, 0x5f, 0x02, 0xa9}

Ordering_Location :: struct {
	uuid: [16]u8,
	slide, text_start, text_size, candidate: u64,
}

// Validate all address arithmetic before the caller reads the entry signature.
// The caller must obtain these ranges from the loaded image, not a cache file.
valid_ordering_location :: proc(location: Ordering_Location) -> bool {
	if location.uuid != ORDERING_IMAGE_UUID || location.candidate < location.slide ||
	   location.candidate - location.slide != ORDERING_UNSLID_ENTRY ||
	   location.text_size < len(ORDERING_ENTRY_SIGNATURE) ||
	   location.text_size > max(u64) - location.text_start ||
	   location.candidate < location.text_start {return false}
	offset := location.candidate - location.text_start
	return offset <= location.text_size - len(ORDERING_ENTRY_SIGNATURE)
}

matches_ordering_entry :: proc(location: Ordering_Location, signature: []u8) -> bool {
	if !valid_ordering_location(location) || len(signature) != len(ORDERING_ENTRY_SIGNATURE) {return false}
	expected := ORDERING_ENTRY_SIGNATURE
	for b, i in signature {
		if b != expected[i] {return false}
	}
	return true
}

valid_pid :: proc(pid: i32) -> bool {
	return pid > 0
}

valid_path :: proc(path: string) -> bool {
	return path == PATH || path == CANONICAL_PATH
}

validate_target :: proc(pid: i32, path: string) -> string {
	if !valid_pid(pid) {
		return "WindowServer injection requires a positive process ID"
	}
	if !valid_path(path) {
		return "target process is not the system WindowServer"
	}
	return ""
}
