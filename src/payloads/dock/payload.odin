package dock_payload

import m "../../native"
import "base:intrinsics"
import objc "core:sys/darwin/Foundation"
import dock "../../dock"
import "core:fmt"
import "core:math"
import "core:time"
import "base:runtime"
import "core:mem"
import "core:strings"
import posix "core:sys/posix"
import inject "../../inject"

foreign import sls "system:SkyLight.framework"
foreign import sys "system:System"
foreign import cg "system:CoreGraphics.framework"

// Native declarations
// ------------------------------------------------------------------------

Object :: ^objc.Object
send :: intrinsics.objc_send
Transform :: struct {
	a, b, c, d, tx, ty: f64,
}
PSN :: struct {
	high, low: u32,
}
@(default_calling_convention = "c")
foreign sls {
	SLSSpaceGetType :: proc(cid: i32, sid: u64) -> i32 ---
	SLSCopyManagedDisplayForSpace :: proc(cid: i32, sid: u64) -> m.Ref ---
	SLSManagedDisplaySetCurrentSpace :: proc(cid: i32, display: m.Ref, sid: u64) ---
	SLSShowSpaces :: proc(cid: i32, spaces: m.Ref) ---
	SLSHideSpaces :: proc(cid: i32, spaces: m.Ref) ---
	SLSSetWindowAlpha :: proc(cid: i32, wid: u32, alpha: f32) -> i32 ---
	SLSMoveWindowWithGroup :: proc(cid: i32, wid: u32, point: ^m.Point) -> i32 ---
	// This symbol is a bare return on 15.6 and 27.0.1; w0 is not a status.
	SLSReassociateWindowsSpacesByGeometry :: proc(cid: i32, windows: m.Ref) ---
	SLSSetWindowSubLevel :: proc(cid: i32, wid: u32, level: i32) -> i32 ---
	SLSSetWindowTags :: proc(cid: i32, wid: u32, tags: ^u64, size: uint) -> i32 ---
	SLSClearWindowTags :: proc(cid: i32, wid: u32, tags: ^u64, size: uint) -> i32 ---
	SLSGetWindowOwner :: proc(cid: i32, wid: u32, owner: ^i32) -> i32 ---
	SLSGetConnectionPSN :: proc(cid: i32, psn: ^PSN) -> i32 ---
	SLSMoveWindowsToManagedSpace :: proc(cid: i32, windows: m.Ref, sid: u64) ---
	SLSOrderWindow :: proc(cid: i32, wid: u32, order: i32, relative: u32) -> i32 ---
	SLSGetWindowTransform :: proc(cid: i32, wid: u32, transform: ^Transform) -> i32 ---
	SLSSetWindowTransform :: proc(cid: i32, wid: u32, transform: Transform) -> i32 ---
	SLSTransactionCreate :: proc(cid: i32) -> m.Ref ---
	// On 15.6 these enqueue/commit calls leave no defined CGError in w0.
	// Reading their return register invents errors; see "Transaction return
	// values" in tools/DOCK_COMPATIBILITY.md.
	SLSTransactionCommit :: proc(transaction: m.Ref, synchronous: i32) ---
	SLSTransactionOrderWindowGroup :: proc(transaction: m.Ref, wid: u32, order: i32, relative: u32) ---
	SLSTransactionSetWindowSystemAlpha :: proc(transaction: m.Ref, wid: u32, alpha: f32) ---
	SLSTransactionAddWindowToSpace :: proc(transaction: m.Ref, wid: u32, sid: u64) ---
	SLSTransactionRemoveWindowFromSpace :: proc(transaction: m.Ref, wid: u32, sid: u64) ---
	SLSTransactionSetWindowEventShape :: proc(transaction: m.Ref, wid: u32, region: m.Ref) ---
	CGSNewEmptyRegion :: proc(region: ^m.Ref) -> i32 ---
	CGSNewRegionWithRect :: proc(rect: ^m.Rect, region: ^m.Ref) -> i32 ---
	CGSReleaseRegion :: proc(region: m.Ref) -> i32 ---
}
@(default_calling_convention = "c")
foreign sys {
	_dyld_get_image_header :: proc(index: u32) -> rawptr ---
	getsegmentdata :: proc(header: rawptr, segment: cstring, size: ^uint) -> [^]u8 ---
	_dispatch_main_q: u8
	dispatch_sync_f :: proc(queue, user: rawptr, callback: proc "c" (_: rawptr)) ---
	mach_task_self :: proc() -> u32 ---
	mach_vm_protect :: proc(task: u32, address, size: u64, maximum: i32, protection: i32) -> i32 ---
	vm_page_size: u64
	sys_icache_invalidate :: proc(start: rawptr, length: uint) ---
}
foreign cg {CGWindowLevelForKey :: proc(key: i32) -> i32 ---}
ivar :: proc(object: Object, name: cstring) -> Object {
	if object == nil {return nil}
	value: Object
	objc.object_getInstanceVariable(objc.id(object), name, rawptr(&value))
	return value
}
set_ivar :: proc(object: Object, name: cstring, value: Object) {
	old := ivar(object, name)
	if old == value {return}
	if value != nil {send(Object, value, "retain")}
	objc.object_setInstanceVariable(objc.id(object), name, objc.id(value))
	if old != nil {send(nil, old, "release")}
}
array_u64 :: proc(values: []u64) -> m.Ref {
	refs := make([]m.Ref, len(values), context.temp_allocator)
	for value, i in values {v := value;refs[i] = m.CFNumberCreate(nil, 4, &v)}
	// NSArray retains each CFNumber before its temporary owning reference is released.
	retaining := send(Object, objc.Array, "alloc")
	retaining = send(Object, retaining, "initWithObjects:count:", raw_data(refs), uint(len(refs)))
	for ref in refs {m.CFRelease(ref)}
	return rawptr(retaining)
}

dispatch_get_main_queue :: proc() -> rawptr {return &_dispatch_main_q}

// Dock discovery
// ------------------------------------------------------------------------

Globals :: struct {
	dock_object, pictures:    Object,
	add, remove, move, focus: rawptr,
	caps:                     dock.Capabilities,
	version:                  dock.Version,
	cid:                      i32,
}
g: Globals
locate :: proc(bytes: []u8, offset: u64, pattern: string) -> rawptr {
	if offset == 0 || offset >= u64(len(bytes)) || pattern == "" {return nil}
	compiled, ok := dock.compile(pattern)
	if !ok {return nil};defer dock.destroy(compiled)
	stop := min(len(bytes), int(offset) + 0x1286a0 + len(compiled.bytes))
	at, found := dock.find(bytes[int(offset):stop], compiled)
	if !found {return nil}
	return rawptr(&bytes[int(offset) + at])
}
resolve_global :: proc(address: rawptr) -> Object {
	if address == nil {return nil}
	value: u64
	when ODIN_ARCH == .arm64 {
		instructions := ([^]u32)(address)
		decoded, ok := dock.decode_adrp_add(instructions[0], instructions[1], u64(uintptr(address)))
		if !ok {return nil};value = decoded
	} else {
		// Read unaligned RIP displacement without imposing pointer alignment.
		displacement: i32
		copy(((^[4]u8)(&displacement))[:], (([^]u8)(address))[:4])
		value = u64(i64(uintptr(address)) + i64(displacement) + 4)
	}
	return (^Object)(uintptr(value))^
}
discover :: proc() {
	g.cid = m.SLSMainConnectionID()
	info := send(Object, objc.ProcessInfo, "processInfo")
	version := send(objc.OperatingSystemVersion, info, "operatingSystemVersion")
	g.version = {int(version.majorVersion), int(version.minorVersion), int(version.patchVersion)}
	if !dock.supported(
		g.version,
	) {fmt.eprintln("shoji-sa: unsupported Dock version", g.version);return}
	size: uint
	data := getsegmentdata(_dyld_get_image_header(0), "__TEXT", &size)
	if data == nil {return}
	bytes := data[:size]
	dock_symbol := locate(
		bytes,
		dock.get_dock_spaces_offset(g.version),
		dock.get_dock_spaces_pattern(g.version),
	)
	g.dock_object = resolve_global(dock_symbol)
	pictures := locate(bytes, dock.get_dppm_offset(g.version), dock.get_dppm_pattern(g.version))
	g.pictures = resolve_global(pictures)
	// Sonoma's alternate desktop-picture-manager slot is eight bytes earlier.
	if g.pictures == nil && pictures != nil {
		when ODIN_ARCH == .arm64 {
			ins := ([^]u32)(pictures)
			address, ok := dock.decode_adrp_add(ins[0], ins[1], u64(uintptr(pictures)))
			if ok {g.pictures = (^Object)(uintptr(address - 8))^}
		} else {
			displacement: i32;copy(((^[4]u8)(&displacement))[:], (([^]u8)(pictures))[:4])
			g.pictures = (^Object)(uintptr(i64(uintptr(pictures)) + i64(displacement) - 4))^
		}
	}
	g.add = locate(bytes, dock.get_add_space_offset(g.version), dock.get_add_space_pattern(g.version))
	g.remove = locate(
		bytes,
		dock.get_remove_space_offset(g.version),
		dock.get_remove_space_pattern(g.version),
	)
	g.move = locate(bytes, dock.get_move_space_offset(g.version), dock.get_move_space_pattern(g.version))
	g.focus = locate(
		bytes,
		dock.get_set_front_window_offset(g.version),
		dock.get_set_front_window_pattern(g.version),
	)
	if g.dock_object != nil {send(Object, g.dock_object, "retain");g.caps += {.Dock_Spaces}}
	if g.pictures != nil {send(Object, g.pictures, "retain");g.caps += {.Desktop_Pictures}}
	if g.add != nil {g.caps += {.Add_Space}};if g.remove != nil {g.caps += {.Remove_Space}}
	if g.move != nil {g.caps += {.Move_Space}};if g.focus != nil && !dock.focus_target_blocked(g.version) {g.caps += {.Focus_Window}}
	patch := locate(
		bytes,
		dock.get_fix_animation_offset(g.version),
		dock.get_fix_animation_pattern(g.version),
	)
	if patch != nil {
		page := u64(uintptr(patch)) & ~(vm_page_size - 1)
		// An eight-byte Intel patch can straddle the page boundary.
		span := ((u64(uintptr(patch)) + 8 + vm_page_size - 1) & ~(vm_page_size - 1)) - page
		if mach_vm_protect(mach_task_self(), page, span, 0, 1 | 2 | 16) == 0 {
			when ODIN_ARCH == .arm64 {(^u32)(patch)^ = 0x2f00e400;sys_icache_invalidate(patch, 4)} else {value: u64 = 0x660fefc0660fefc0;copy((([^]u8)(patch))[:8], ((^[8]u8)(&value))[:])}
			if mach_vm_protect(mach_task_self(), page, span, 0, 1 | 4) ==
			   0 {g.caps += {.Animation_Patch}}
		}
	}
	fmt.eprintf("shoji-sa: Dock %d.%d capabilities=%v\n", g.version.major, g.version.minor, g.caps)
}
space_object :: proc(uuid: m.Ref, id: u64) -> Object {
	if g.dock_object == nil || uuid == nil {return nil}
	array := send(Object, g.dock_object, "spacesForDisplay:", uuid)
	for i in 0 ..< send(uint, array, "count") {
		space := send(Object, array, "objectAtIndex:", i)
		if send(u64, space, "spid") == id {return space}
	};return nil
}
display_object :: proc(uuid: m.Ref) -> Object {
	array := ivar(g.dock_object, "_displaySpaces")
	for i in 0 ..< send(uint, array, "count") {
		display := send(Object, array, "objectAtIndex:", i)
		space := ivar(display, "_currentSpace")
		identifier := SLSCopyManagedDisplayForSpace(g.cid, send(u64, space, "spid"))
		if identifier == nil {continue}
		same := m.text(identifier) == m.text(uuid);m.CFRelease(identifier)
		if same {return display}
	};return nil
}

// Space operations
// ------------------------------------------------------------------------

@(objc_class = "ManagedSpace")
Managed_Space :: struct {
	using _: objc.Object,
}
@(objc_class = "Dock.ManagedSpace")
Legacy_Space :: struct {
	using _: objc.Object,
}
focus_space :: proc(id: u64) -> dock.Status {
	if g.dock_object == nil {return .Unsupported}
	uuid := SLSCopyManagedDisplayForSpace(g.cid, id)
	if uuid == nil {return .Operation_Failed};defer m.CFRelease(uuid)
	target := space_object(uuid, id);display := display_object(uuid)
	if target == nil || display == nil {return .Operation_Failed}
	old := m.SLSManagedDisplayGetCurrentSpace(g.cid, uuid)
	if old == id {return .OK}
	source := array_u64([]u64{old});defer m.CFRelease(source)
	destination := array_u64([]u64{id});defer m.CFRelease(destination)
	SLSShowSpaces(g.cid, destination);SLSHideSpaces(g.cid, source)
	SLSManagedDisplaySetCurrentSpace(g.cid, uuid, id)
	set_ivar(display, "_currentSpace", target)
	return .OK
}
space_action :: proc(op: dock.Opcode, r: ^dock.Reader, created_space: ^u64) -> dock.Status {
	id := dock.unpack(r, u64)
	if g.dock_object == nil || id == 0 {return .Unsupported}
	uuid := SLSCopyManagedDisplayForSpace(g.cid, id)
	if uuid == nil {return .Operation_Failed};defer m.CFRelease(uuid)
	object := space_object(uuid, id);display := display_object(uuid)
	if object == nil || display == nil {return .Operation_Failed}
	#partial switch op {
	case .Space_Focus:
		return focus_space(id)
	case .Space_Create, .Space_Create_Tracked:
		if g.add == nil {return .Unsupported}
		fresh: Object
		if g.version.major >=
		   15 {fresh = send(Object, Managed_Space, "alloc")} else {fresh = send(Object, Legacy_Space, "alloc")}
		fresh = send(Object, fresh, "init")
		if fresh == nil {return .Operation_Failed}
		// Preserve upstream ownership at this private Swift boundary.
		inject.call_add(rawptr(fresh), rawptr(display), g.add)
		if op == .Space_Create_Tracked {
			created_space^ = send(u64, fresh, "spid")
			if created_space^ == 0 {return .Operation_Failed}
		}
	case .Space_Destroy:
		if g.remove == nil {return .Unsupported}
		// Never destroy the display's only user space.
		if SLSSpaceGetType(g.cid, id) != 0 ||
		   alternate_user_space(uuid, id) == 0 {return .Operation_Failed}
		function := cast(proc "c" (_: Object, _: Object, _: Object, _: u64, _: u64))g.remove
		function(object, display, g.dock_object, id, id)
		current := m.SLSManagedDisplayGetCurrentSpace(g.cid, uuid)
		set_ivar(display, "_currentSpace", space_object(uuid, current))
	case .Space_Move:
		destination := dock.unpack(r, u64);previous := dock.unpack(r, u64)
		follow_byte := dock.unpack(r, u8)
		if follow_byte > 1 {return .Invalid_Message}
		follow := follow_byte == 1
		if g.move == nil || g.pictures == nil {return .Unsupported}
		target_uuid := SLSCopyManagedDisplayForSpace(g.cid, destination)
		if target_uuid == nil {return .Operation_Failed}
		defer m.CFRelease(target_uuid)
		target := space_object(target_uuid, destination)
		target_display := display_object(target_uuid)
		if target == nil || target_display == nil || id == destination {return .Operation_Failed}
		display_id := send(u32, g.dock_object, "displayIDForSpace:", target)
		if SLSSpaceGetType(g.cid, id) != 0 ||
		   SLSSpaceGetType(g.cid, destination) != 0 {return .Operation_Failed}
		if m.text(uuid) != m.text(target_uuid) {
			alternate := alternate_user_space(uuid, id)
			if alternate == 0 {return .Operation_Failed}
			if m.SLSManagedDisplayGetCurrentSpace(g.cid, uuid) == id &&
			   previous == 0 {previous = alternate;follow = true}
		}
		if previous != 0 {
			if previous == id ||
			   space_object(uuid, previous) == nil ||
			   focus_space(previous) != .OK {return .Operation_Failed}
		}
		inject.call_move(rawptr(object), rawptr(target), target_uuid, rawptr(g.dock_object), g.move)
		send(nil, g.pictures, "moveSpace:toDisplay:displayUUID:", object, display_id, target_uuid)
		if follow {return focus_space(id)}
	case:
		return .Invalid_Message
	}
	return .OK
}

alternate_user_space :: proc(uuid: m.Ref, excluded: u64) -> u64 {
	list := send(Object, g.dock_object, "spacesForDisplay:", uuid)
	for i in 0 ..< send(uint, list, "count") {
		space := send(Object, list, "objectAtIndex:", i)
		id := send(u64, space, "spid")
		if id != excluded && SLSSpaceGetType(g.cid, id) == 0 {return id}
	}
	return 0
}

// Window lifecycle
// ------------------------------------------------------------------------

Fade :: struct {
	start, end: f32,
	began:      time.Time,
	duration:   f64,
}
hidden_proxies: map[u32]dock.Entry
payload_recovery_owner :: proc(user: rawptr, window: u32) -> (i32, bool) {
	owner: i32
	code := SLSGetWindowOwner(g.cid, window, &owner)
	return owner, code == 0
}
payload_recovery_restore :: proc(user: rawptr, entry: dock.Entry, proxy_valid: bool) -> bool {
	transaction := SLSTransactionCreate(g.cid)
	if transaction == nil {return false}; defer m.CFRelease(transaction)
	SLSTransactionSetWindowSystemAlpha(transaction, entry.window, 1)
	if proxy_valid {SLSTransactionOrderWindowGroup(transaction, entry.proxy, 0, entry.window)}
	SLSTransactionCommit(transaction, 0)
	// This acknowledges a restoration request, not a pixel-level observation.
	// Ownership was checked by docklib.restore before this callback.
	return true
}
tick_proxy_recovery :: proc() {
	done := make([dynamic]u32, context.temp_allocator)
	backend := dock.Backend {payload_recovery_owner, payload_recovery_restore, nil}
	for window, entry in hidden_proxies {
		result := dock.restore(entry, backend, true)
		if result == .Restored || result == .Gone {append(&done, window)}
	}
	for window in done {delete_key(&hidden_proxies, window)}
}
// A concealed window is invisible and lets clicks through, so it must never
// outlive the Shoji process that concealed it. Each entry remembers that
// client; tick_concealed reveals the window once the client has exited.
// A Dock restart drops this table (the concealing daemon still owns them).
CONCEALED_LIMIT :: 256
CONCEALED_CHECK_INTERVAL :: 250 * time.Millisecond
Concealed :: struct {
	owner:  i32, // window owner connection, guards against ID reuse
	client: i32, // concealing process
}
concealed: map[u32]Concealed
concealed_checked: time.Time

peer_pid :: proc(fd: i32) -> i32 {
	pid: i32;size := posix.socklen_t(size_of(pid))
	// SOL_LOCAL (0), LOCAL_PEERPID (2) from <sys/un.h>.
	if posix.getsockopt(posix.FD(fd), 0, posix.Sock_Option(2), &pid, &size) != .OK {return 0}
	return pid
}

conceal_request :: proc(id: u32, conceal: bool, client: i32, diagnostic: ^dock.Native_Failure) -> dock.Status {
	if !conceal {
		delete_key(&concealed, id)
		return conceal_window(id, false, diagnostic)
	}
	// Refuse what the watchdog could not undo.
	if client <= 0 {return .Operation_Failed}
	owner, exists := payload_recovery_owner(nil, id)
	if !exists {return .Operation_Failed}
	if len(concealed) >= CONCEALED_LIMIT && id not_in concealed {return .Operation_Failed}
	concealed[id] = {owner, client}
	result := conceal_window(id, true, diagnostic)
	if result != .OK {delete_key(&concealed, id)}
	return result
}

tick_concealed :: proc() {
	if len(concealed) == 0 {return}
	now := time.now()
	if time.diff(concealed_checked, now) < CONCEALED_CHECK_INTERVAL {return}
	concealed_checked = now
	done := make([dynamic]u32, 0, 8, context.temp_allocator)
	for id, entry in concealed {
		owner, exists := payload_recovery_owner(nil, id)
		if !exists || owner != entry.owner {append(&done, id);continue}
		// ESRCH: the client is gone. EPERM still means it is alive.
		if posix.kill(posix.pid_t(entry.client), posix.Signal(0)) != .OK && posix.errno() == .ESRCH {
			if conceal_window(id, false, nil) == .OK {append(&done, id)}
		}
	}
	for id in done {delete_key(&concealed, id)}
}

conceal_window :: proc(id: u32, conceal: bool, diagnostic: ^dock.Native_Failure) -> dock.Status {
	region: m.Ref
	if conceal {
		if code := CGSNewEmptyRegion(&region); code != 0 || region == nil {return .Operation_Failed}
	} else {
		// No getter exists for the previous event shape; the window's own
		// rectangle is the shape AppKit installs for an ordinary window.
		frame: m.Rect
		if m.SLSGetWindowBounds(g.cid, id, &frame) != 0 {return .Operation_Failed}
		local := m.Rect{0, 0, frame.w, frame.h}
		if code := CGSNewRegionWithRect(&local, &region); code != 0 || region == nil {return .Operation_Failed}
	}
	defer _ = CGSReleaseRegion(region)
	transaction := SLSTransactionCreate(g.cid)
	if transaction == nil {dock.note_native_failure(diagnostic, .Transaction_Create, -1);return .Operation_Failed}
	defer m.CFRelease(transaction)
	SLSTransactionSetWindowSystemAlpha(transaction, id, conceal ? 0 : 1)
	SLSTransactionSetWindowEventShape(transaction, id, region)
	SLSTransactionCommit(transaction, 1)
	return .OK
}
fades: map[u32]Fade
status :: proc(code: i32) -> dock.Status {return code == 0 ? .OK : .Operation_Failed}
tick_fades :: proc() {
	now := time.now()
	done := make([dynamic]u32, 0, 8, context.temp_allocator)
	for id, fade in fades {
		t := clamp(time.duration_seconds(time.diff(fade.began, now)) / fade.duration, 0, 1)
		result := SLSSetWindowAlpha(g.cid, id, fade.start + f32(t) * (fade.end - fade.start))
		if t >= 1 || result != 0 {append(&done, id)}
	}
	for id in done {delete_key(&fades, id)}
}
window_action :: proc(op: dock.Opcode, r: ^dock.Reader, diagnostic: ^dock.Native_Failure, client: i32) -> dock.Status {
	if op == .Window_To_Space || op == .Window_List_To_Space {
		sid := dock.unpack(r, u64);if sid == 0 {return .Invalid_Message}
		values := make([dynamic]u64, 0, 8, context.temp_allocator)
		if op == .Window_To_Space {append(&values, u64(dock.unpack(r, u32)))} else {
			count := dock.unpack(r, i32)
			for _ in 0 ..< count {append(&values, u64(dock.unpack(r, u32)))}
		}
		for id in values {if id == 0 {return .Invalid_Message}}
		array := array_u64(values[:]);defer m.CFRelease(array)
		SLSMoveWindowsToManagedSpace(g.cid, array, sid)
		return .OK
	}
	if op == .Window_To_Space_Transaction {
		target := dock.unpack(r, u64);id := dock.unpack(r, u32);source := dock.unpack(r, u64)
		if target == 0 || id == 0 || source == target {return .Invalid_Message}
		transaction := SLSTransactionCreate(g.cid)
		if transaction == nil {dock.note_native_failure(diagnostic, .Transaction_Create, -1);return .Operation_Failed}
		defer m.CFRelease(transaction)
		SLSTransactionAddWindowToSpace(transaction, id, target)
		if source != 0 {SLSTransactionRemoveWindowFromSpace(transaction, id, source)}
		// Synchronous: the WindowServer gate applies staged placement inside
		// this commit, so the caller can read placement status on return.
		SLSTransactionCommit(transaction, 1)
		return .OK
	}
	if op == .Proxy_In || op == .Proxy_Out || op == .Window_Order_In {
		count := dock.unpack(r, i32)
		// Register every window before any transaction can hide it, including
		// transactions whose commit reports an ambiguous failure.
		check := r^
		ids := make([dynamic]u32, context.temp_allocator)
		for _ in 0..<count {
			id := dock.unpack(&check, u32)
			if id == 0 {continue}
			append(&ids, id)
			if op == .Window_Order_In {continue}
			proxy := dock.unpack(&check, u32)
			if op != .Proxy_In {continue}
			owner, real_ok := payload_recovery_owner(nil, id)
			proxy_owner, proxy_ok := payload_recovery_owner(nil, proxy)
			if !real_ok || !proxy_ok || proxy == 0 || id == proxy {return .Invalid_Message}
			entry := dock.Entry {id, proxy, owner, proxy_owner}
			if previous, exists := hidden_proxies[id]; exists && previous != entry {return .Operation_Failed}
			if len(hidden_proxies) >= 256 && id not_in hidden_proxies {return .Operation_Failed}
			hidden_proxies[id] = entry
		}
		transaction := SLSTransactionCreate(g.cid)
		if transaction == nil {dock.note_native_failure(diagnostic, .Transaction_Create, -1);return .Operation_Failed};defer m.CFRelease(transaction)
		for _ in 0 ..< count {
			id := dock.unpack(r, u32);if id == 0 {continue}
			if op ==
			   .Window_Order_In {
				SLSTransactionOrderWindowGroup(transaction, id, 1, 0)
			} else {
				proxy := dock.unpack(r, u32)
				if op == .Proxy_In {
					SLSTransactionOrderWindowGroup(transaction, proxy, 1, id)
					SLSTransactionSetWindowSystemAlpha(transaction, id, 0)
				} else {
					SLSTransactionSetWindowSystemAlpha(transaction, id, 1)
					if proxy != 0 {
						SLSTransactionOrderWindowGroup(transaction, proxy, 0, id)
					}
				}
			}
		}
		SLSTransactionCommit(transaction, 0)
		if op == .Proxy_Out {for id in ids {delete_key(&hidden_proxies, id)}}
		return .OK
	}
	id := dock.unpack(r, u32)
	if id == 0 {return .Invalid_Message}
	#partial switch op {
	case .Window_Move:
		x := dock.unpack(r, i32);y := dock.unpack(r, i32);point := m.Point{f64(x), f64(y)}
		code := SLSMoveWindowWithGroup(g.cid, id, &point)
		array := array_u64([]u64{u64(id)});defer m.CFRelease(array)
		SLSReassociateWindowsSpacesByGeometry(g.cid, array)
		return status(code)
	case .Window_Opacity, .Window_Opacity_Fade:
		alpha := dock.unpack(r, f32);duration: f32
		if op == .Window_Opacity_Fade {duration = dock.unpack(r, f32)}
		if math.is_nan(alpha) ||
		   math.is_nan(duration) ||
		   alpha < 0 ||
		   alpha > 1 ||
		   duration < 0 ||
		   duration > 3600 {return .Invalid_Message}
		if duration ==
		   0 {delete_key(&fades, id);return status(SLSSetWindowAlpha(g.cid, id, alpha))}
		start: f32
		if m.SLSGetWindowAlpha(g.cid, id, &start) != 0 {return .Operation_Failed}
		fades[id] = Fade{start, alpha, time.now(), f64(duration)}
		return .OK
	case .Window_Layer:
		layer, valid := dock.normalize_window_layer_key(dock.unpack(r, i32))
		if !valid {return .Invalid_Message}
		return status(SLSSetWindowSubLevel(g.cid, id, CGWindowLevelForKey(layer)))
	case .Window_Sticky, .Window_Shadow:
		enabled := dock.unpack(r, u8)
		if enabled > 1 {return .Invalid_Message}
		tags: u64 = 1 << 11;set := enabled == 1
		if op == .Window_Shadow {tags = 1 << 3;set = !set}
		if set {return status(SLSSetWindowTags(g.cid, id, &tags, 64))}
		return status(SLSClearWindowTags(g.cid, id, &tags, 64))
	case .Window_Conceal:
		conceal := dock.unpack(r, u8)
		if conceal > 1 {return .Invalid_Message}
		return conceal_request(id, conceal == 1, client, diagnostic)
	case .Window_Focus:
		if g.focus == nil || dock.focus_target_blocked(g.version) {return .Unsupported}
		owner: i32;psn: PSN
		if SLSGetWindowOwner(g.cid, id, &owner) != 0 ||
		   SLSGetConnectionPSN(owner, &psn) != 0 {return .Operation_Failed}
		(cast(proc "c" (_: PSN, _: u32))g.focus)(psn, id)
		return .OK
	case .Window_Order:
		order := dock.unpack(r, i32);relative := dock.unpack(r, u32)
		if order < -1 || order > 1 {return .Invalid_Message}
		// Commit group ordering explicitly; the ordinary setter can acknowledge
		// without publishing the new order for windows owned by another app.
		transaction := SLSTransactionCreate(g.cid)
		if transaction == nil {dock.note_native_failure(diagnostic, .Transaction_Create, -1);return .Operation_Failed}
		defer m.CFRelease(transaction)
		SLSTransactionOrderWindowGroup(transaction, id, order, relative)
		SLSTransactionCommit(transaction, 1)
		return .OK
	case .Window_Scale:
		x := dock.unpack(r, f32);y := dock.unpack(r, f32);width := dock.unpack(r, f32)
		height := dock.unpack(r, f32)
		if math.is_nan(x) ||
		   math.is_nan(y) ||
		   math.is_nan(width) ||
		   math.is_nan(height) ||
		   math.is_inf(x) ||
		   math.is_inf(y) ||
		   math.is_inf(width) ||
		   math.is_inf(height) ||
		   width < 4 ||
		   height <= 0 {return .Invalid_Message}
		frame: m.Rect
		current: Transform
		if m.SLSGetWindowBounds(g.cid, id, &frame) != 0 ||
		   SLSGetWindowTransform(g.cid, id, &current) != 0 ||
		   frame.w <= 0 ||
		   frame.h <= 0 {return .Operation_Failed}
		original := Transform {
			a  = 1,
			d  = 1,
			tx = -frame.x,
			ty = -frame.y,
		}
		if current == original {
			target_width := math.floor(f64(width) / 4)
			target_height := max(1, math.floor(target_width / (frame.w / frame.h)))
			sx, sy := frame.w / target_width, frame.h / target_height
			transform := Transform {
				a  = sx,
				d  = sy,
				tx = (-(f64(x) + f64(width)) + frame.w / sx) * sx,
				ty = -f64(y) * sy,
			}
			return status(SLSSetWindowTransform(g.cid, id, transform))
		}
		return status(SLSSetWindowTransform(g.cid, id, original))
	case:
		return .Invalid_Message
	}
}

// Payload server
// ------------------------------------------------------------------------

Request :: struct {
	op:     dock.Opcode,
	bytes:  []u8,
	result: dock.Status,
	tick:   bool,
	ctx:    runtime.Context,
	native_failure: dock.Native_Failure,
	created_space: u64,
	// Process ID of the requesting client (LOCAL_PEERPID), 0 if unknown.
	client: i32,
}
main_request :: proc "c" (user: rawptr) {
	req := (^Request)(user);context = req.ctx
	pool := m.pool_push();defer m.pool_pop(pool)
	if req.tick {tick_fades();tick_proxy_recovery();tick_concealed();return}
	if !dock.validate(req.op, req.bytes) {req.result = .Invalid_Message;return}
	if req.op == .Handshake {req.result = .OK;return}
	r := dock.reader(req.bytes)
	if (req.op >= .Space_Focus && req.op <= .Space_Move) || req.op == .Space_Create_Tracked {
		req.result = space_action(req.op, &r, &req.created_space)
	} else {req.result = window_action(req.op, &r, &req.native_failure, req.client)}
}
initialize_payload :: proc "c" (unused: rawptr) {
	context = runtime.default_context()
	pool := m.pool_push();defer m.pool_pop(pool)
	discover();g.caps += {.Transaction_Diagnostics, .Window_Layer_Keys, .Space_Transaction, .Window_Conceal};if g.add != nil {g.caps += {.Tracked_Space_Create}}
	fades = make(map[u32]Fade);hidden_proxies = make(map[u32]dock.Entry)
	concealed = make(map[u32]Concealed)
}
listen_fd: i32 = -1
serve :: proc "c" (unused: rawptr) -> rawptr {
	context = runtime.default_context()
	dispatch_sync_f(dispatch_get_main_queue(), nil, sign_c(initialize_payload))
	for {
		scratch: mem.Dynamic_Arena;mem.dynamic_arena_init(&scratch)
		{
			context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
			ready := m.Poll_FD {
				fd     = listen_fd,
				events = 1,
			}
			if m.poll(&ready, 1, 8) > 0 && ready.revents & 1 != 0 {
				fd := m.accept(listen_fd, nil, nil)
				if fd >= 0 {serve_one(fd)}
			}
			req := Request {
				tick = true,
				ctx  = context,
			}
			dispatch_sync_f(dispatch_get_main_queue(), &req, sign_c(main_request))
		}
		mem.dynamic_arena_destroy(&scratch)
	}
}
serve_one :: proc(fd: i32) {
	defer m.close(fd);m.prepare_socket(fd)
	deadline := time.time_add(time.now(), 2 * time.Second)
	uid, gid: u32
	if m.getpeereid(fd, &uid, &gid) != 0 || uid != m.getuid() {return}
	header: [2]u8
	if !m.read_exact(fd, header[:], deadline) {return}
	count := int(header[0]) | int(header[1]) << 8
	if count < 1 ||
	   count >
		   dock.MAX_PACKET -
			   2 {reply := [1]u8{u8(dock.Status.Invalid_Message)};m.write_all(fd, reply[:]);return}
	buffer: [dock.MAX_PACKET]u8
	if !m.read_exact(fd, buffer[:count], deadline) {return}
	req := Request {
		op     = dock.Opcode(buffer[0]),
		bytes  = buffer[1:count],
		ctx    = context,
		client = peer_pid(fd),
	}
	dispatch_sync_f(dispatch_get_main_queue(), &req, sign_c(main_request))
	if req.result != .OK && req.native_failure.stage != .None {
		reply := dock.Packet{valid = true}
		dock.pack(&reply, dock.Status.Native_Error)
		dock.pack(&reply, req.native_failure.stage)
		dock.pack(&reply, req.native_failure.code)
		m.write_all(fd, reply.data[:reply.count]);return
	}
	response := [1]u8{u8(req.result)}
	if !m.write_all(fd, response[:]) || req.result != .OK {return}
	if req.op == .Space_Create_Tracked {
		reply := dock.Packet{valid = true};dock.pack(&reply, req.created_space)
		m.write_all(fd, reply.data[:reply.count]);return
	}
	if req.op != .Handshake {return}
	p := dock.Packet {
		valid = true,
	}
	version := string(dock.VERSION)
	for byte in transmute([]u8)version {dock.pack(&p, byte)}
	dock.pack(&p, u8(0));dock.pack(&p, g.caps)
	m.write_all(fd, p.data[:p.count])
}
load_payload :: proc "c" () {
	context = runtime.default_context()
	pool := m.pool_push();defer m.pool_pop(pool)
	path := fmt.tprintf("/tmp/shoji-sa_%d.socket", m.getuid())
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	// A previous loaded copy must not lose its endpoint on repeated dlopen.
	existing := m.connect_socket(path)
	if existing >= 0 {m.close(existing);return}
	fd := m.socket(1, 1, 0);if fd < 0 {return}
	m.prepare_socket(fd);m.unlink(cpath)
	addr, ok := m.address(path)
	if !ok ||
	   m.bind(fd, &addr, size_of(addr)) != 0 ||
	   m.chmod(cpath, 0o600) != 0 ||
	   m.listen(fd, 64) != 0 {m.close(fd);return}
	listen_fd = fd
	thread: posix.pthread_t
	if posix.pthread_create(&thread, nil, sign_c(serve), nil) !=
	   nil {m.close(fd);m.unlink(cpath);return}
	posix.pthread_detach(thread)
}

@(export)
shoji_sa_start :: proc "c" () {load_payload()}

@(link_section = "__DATA,__mod_init_func", linkage = "strong", require)
shoji_sa_init: proc "c" () = shoji_sa_start

sign_c :: proc(p: $P) -> P {
	return transmute(P)uintptr(inject.sign_function(u64(uintptr(transmute(rawptr)p))))
}
