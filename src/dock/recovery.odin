package dock

// Connection ownership guards against replaying an old ID into another app.
Entry :: struct {
	window, proxy:      u32,
	owner, proxy_owner: i32,
}
Result :: enum {
	Active,
	Restored,
	Gone,
	Retry,
}
Backend :: struct {
	owner:   proc(user: rawptr, window: u32) -> (i32, bool),
	restore: proc(user: rawptr, entry: Entry, proxy_valid: bool) -> bool,
	user:    rawptr,
}
restore :: proc(entry: Entry, backend: Backend, only_orphan: bool) -> Result {
	owner, exists := backend.owner(backend.user, entry.window)
	if !exists || owner != entry.owner {return .Gone}
	proxy_owner, proxy_exists := backend.owner(backend.user, entry.proxy)
	proxy_valid := proxy_exists && proxy_owner == entry.proxy_owner
	if only_orphan && proxy_valid {return .Active}
	if !backend.restore(backend.user, entry, proxy_valid) {return .Retry}
	return .Restored
}
