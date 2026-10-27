package macos

// Query WindowServer once, rather than sending AXWindows to every menu-bar helper.
// Occluded windows are included; desktop elements and non-document levels are not.
accessory_window_owners :: proc() -> (owners: map[i32]bool, known: bool) {
	list := CGWindowListCopyWindowInfo(1 | 16, 0)
	if list == nil {return nil, false}
	defer CFRelease(list)
	owners = make(map[i32]bool, context.temp_allocator)
	for i in 0 ..< CFArrayGetCount(list) {
		entry := CFArrayGetValueAtIndex(list, i)
		if number(dictionary(entry, "kCGWindowLayer")) != 0 {continue}
		pid := i32(number(dictionary(entry, "kCGWindowOwnerPID")))
		if pid > 0 {owners[pid] = true}
	}
	return owners, true
}

poll_application_windows :: proc(
	pid: i32,
	activation_policy: int,
	frontmost_pid: i32,
	owners: map[i32]bool,
	owners_known: bool,
) -> bool {
	if activation_policy == 0 {return true}
	if activation_policy != 1 {return false}
	return !owners_known || pid == frontmost_pid || owners[pid]
}
