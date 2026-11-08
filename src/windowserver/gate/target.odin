package gate

import "core:strings"

PATH :: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"
CANONICAL_PATH :: "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer"
UID :: u32(88)
EXPERIMENT_ENV :: "SHOJI_WINDOWSERVER_EXPERIMENT"

Placement_Helper :: struct {
	unslid:    u64,
	signature: [4]u32,
}

// Exact SkyLight identity of one supported build. Values come from
// artifacts/macos_versions/<build>/model (`spelunker-port build`) and are
// exact-build gates: the payload refuses when UUID or entry bytes differ.
Build_Target :: struct {
	build:                 string,
	ordering_image_uuid:   [16]u8,
	ordering_unslid_entry: u64,
	table_unslid:          u64,
	// PKGTransactionCommit: adrp x24, table@PAGE; add x24, x24, table@PAGEOFF.
	dispatch_site_unslid:  u64,
	dispatch_site_words:   [2]u32,
	// The dispatcher bounds ops with `cmp w8 (op - 1), #(limit - 1)`.
	dispatch_op_limit:     u64,
	// window_by_id, WSCurrentUntransformedWindowBounds, WSMoveWindowWithGroupByOffset.
	placement_helpers:     [3]Placement_Helper,
}

// Every build one release supports; selected at runtime by OS build (daemon,
// --ws-attach) or by the loaded SkyLight UUID (payload). Port a new build with
// spelunker-port (spelunker project) and add it here and in gate_expected.odin.
BUILD_TARGETS :: [?]Build_Target {
	{
		build = "26B123", // macOS 27.2
		ordering_image_uuid = {
			0x1a, 0xd2, 0x6a, 0xfb, 0xb3, 0x13, 0x30, 0x86,
			0x95, 0xf0, 0x43, 0xfc, 0x18, 0xb8, 0xfb, 0xca,
		},
		ordering_unslid_entry = 0x1829fc168,
		table_unslid = 0x1e22470a8,
		dispatch_site_unslid = 0x182a57f04,
		dispatch_site_words = {0x902fbf98, 0x9102a318},
		dispatch_op_limit = 0x8e,
		placement_helpers = {
			{0x1829ef0e4, {0x34000160, 0x903439c8, 0xf9422d08, 0xb4000108}},
			{0x182932620, {0xd02ec188, 0xf9471508, 0x6d400500, 0x6d410d02}},
			{0x182937680, {0xd503237f, 0xd10203ff, 0x6d0323e9, 0xa9045ff8}},
		},
	},
	{
		build = "26A434", // macOS 27.0.1
		ordering_image_uuid = {
			0x8a, 0x3b, 0x34, 0x8e, 0x46, 0x37, 0x36, 0x85,
			0x92, 0xd0, 0x6c, 0xbc, 0x2f, 0x36, 0xa2, 0x34,
		},
		ordering_unslid_entry = 0x1873f6260,
		table_unslid = 0x1e873d430,
		dispatch_site_unslid = 0x187451678,
		dispatch_site_words = {0x90309778, 0x9110c318},
		dispatch_op_limit = 0x8c,
		placement_helpers = {
			{0x1873e91c8, {0x34000160, 0x902e8d48, 0xf942d508, 0xb4000108}},
			{0x18732e534, {0xf02c7408, 0xf944c908, 0x6d400500, 0x6d410d02}},
			{0x187333594, {0xd503237f, 0xd10203ff, 0x6d0323e9, 0xa9045ff8}},
		},
	},
}

target_by_build :: proc(build: string) -> (Build_Target, bool) {
	targets := BUILD_TARGETS
	for target in targets {if target.build == build {return target, true}}
	return {}, false
}

target_by_uuid :: proc(uuid: [16]u8) -> (Build_Target, bool) {
	targets := BUILD_TARGETS
	for target in targets {if target.ordering_image_uuid == uuid {return target, true}}
	return {}, false
}

// Comma-separated supported builds, for reports and errors.
supported_builds :: proc(allocator := context.temp_allocator) -> string {
	targets := BUILD_TARGETS
	names := make([dynamic]string, 0, len(targets), allocator)
	for target in targets {append(&names, target.build)}
	return strings.join(names[:], ", ", allocator)
}

// Files shared by the payload, its controllers and Shoji. They carry no build
// tag: readers validate the version and the writing WindowServer's pid.
TGATE_STATUS_PATH :: "/private/tmp/shoji-ws-observer-tgate.bin"
OBSERVER_STATUS_PATH :: "/private/tmp/shoji-ws-observer-status.bin"
OBSERVER_STARTED_PATH :: "/private/tmp/shoji-ws-observer-started.bin"
OBSERVER_RESPONSE_PATH :: "/private/tmp/shoji-ws-observer-response.bin"

ORDERING_ENTRY_SIGNATURE :: [16]u8{0x7f, 0x23, 0x03, 0xd5, 0xfc, 0x6f, 0xba, 0xa9, 0xfa, 0x67, 0x01, 0xa9, 0xf8, 0x5f, 0x02, 0xa9}

Ordering_Location :: struct {
	uuid: [16]u8,
	slide, text_start, text_size, candidate: u64,
}

// Validate all address arithmetic before the caller reads the entry signature.
// The caller must obtain these ranges from the loaded image, not a cache file.
valid_ordering_location :: proc(location: Ordering_Location) -> bool {
	target, known := target_by_uuid(location.uuid)
	if !known || location.candidate < location.slide ||
	   location.candidate - location.slide != target.ordering_unslid_entry ||
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
