package shoji

// Detects any Shoji payload already mapped in WindowServer, whatever its
// version. A payload that predates the current status format cannot prove
// it serves a gate, and a second payload would find the hooked entry points
// already patched (install status 24). Reads dyld's image list through the
// task port; bounded in images and bytes read.

import gate "windowserver/gate"

TASK_DYLD_INFO :: 17
// Task_Dyld_Info is five natural_t words.
TASK_DYLD_INFO_COUNT :: 5
WS_IMAGES_LIMIT :: 8192
WS_IMAGE_INFO_BYTES :: 24 // dyld_image_info: load address, path, mod date.
WS_IMAGES_RETRIES :: 10 // dyld clears the array while it updates the list.
WS_PAYLOAD_PREFIX :: WS_PAYLOAD_DIR + "/"

Task_Dyld_Info :: struct #packed {
	all_image_info_addr: u64,
	all_image_info_size: u64,
	all_image_info_format: i32,
}

Dyld_All_Image_Infos_Head :: struct {
	version:      u32,
	count:        u32,
	info_array:   u64,
}

Ws_Images_Scan :: enum {
	Clean,
	Shoji_Payload,
	Unreadable,
}

foreign import images_system "system:System"
@(default_calling_convention = "c")
foreign images_system {
	task_info :: proc(task: u32, flavor: u32, info: rawptr, count: ^u32) -> i32 ---
	@(link_name = "mach_vm_read_overwrite")
	images_read :: proc(task: u32, address, size: u64, data: uintptr, actual: ^u64) -> i32 ---
}

ws_images_read :: proc(task: u32, address: u64, out: []u8) -> bool {
	if address == 0 || len(out) == 0 {return false}
	actual: u64
	code := images_read(task, address, u64(len(out)), uintptr(raw_data(out)), &actual)
	return code == 0 && actual == u64(len(out))
}

ws_images_scan :: proc(task: u32) -> Ws_Images_Scan {
	info: Task_Dyld_Info
	count := u32(TASK_DYLD_INFO_COUNT)
	if task_info(task, TASK_DYLD_INFO, &info, &count) != 0 {return .Unreadable}
	head: Dyld_All_Image_Infos_Head
	for _ in 0 ..< WS_IMAGES_RETRIES {
		head_bytes := ([^]u8)(&head)[:size_of(head)]
		if !ws_images_read(task, info.all_image_info_addr, head_bytes) {return .Unreadable}
		if head.info_array != 0 {break}
	}
	if head.info_array == 0 || head.count == 0 || head.count > WS_IMAGES_LIMIT {
		return .Unreadable
	}
	entries := make([]u8, int(head.count) * WS_IMAGE_INFO_BYTES, context.temp_allocator)
	if !ws_images_read(task, head.info_array, entries) {return .Unreadable}
	for i in 0 ..< int(head.count) {
		path_address := (^u64)(&entries[i * WS_IMAGE_INFO_BYTES + 8])^
		if ws_image_is_shoji_payload(task, path_address) {return .Shoji_Payload}
	}
	return .Clean
}

// Reads only the prefix length. A read can fail only for a path shorter than
// the prefix that ends near an unmapped page, and such a path is not ours.
ws_image_is_shoji_payload :: proc(task: u32, path_address: u64) -> bool {
	prefix: [len(WS_PAYLOAD_PREFIX)]u8
	if !ws_images_read(task, path_address, prefix[:]) {return false}
	return ws_image_path_is_shoji_payload(string(prefix[:]))
}

ws_image_path_is_shoji_payload :: proc(path_prefix: string) -> bool {
	return path_prefix == WS_PAYLOAD_PREFIX
}

// Install status of the most recent payload start (ordering hook stage).
ws_attach_install_status :: proc() -> (status: u64, ok: bool) {
	data, st, read_ok := read_limited(gate.OBSERVER_STATUS_PATH, 4096)
	if !read_ok || u32(st.st_uid) != gate.UID || len(data) < 24 {return}
	if string(data[:8]) != "WSOBINST" {return}
	return (^u64)(&data[16])^, true
}
