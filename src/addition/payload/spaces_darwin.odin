package payload

import m "../../macos"
import b "../bridge"
import wire "../protocol"
import objc "core:sys/darwin/Foundation"

@(objc_class = "ManagedSpace")
Managed_Space :: struct {
	using _: objc.Object,
}
@(objc_class = "Dock.ManagedSpace")
Legacy_Space :: struct {
	using _: objc.Object,
}
focus_space :: proc(id: u64) -> wire.Status {
	if g.dock == nil {return .Unsupported}
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
space_action :: proc(op: wire.Opcode, r: ^wire.Reader, created_space: ^u64) -> wire.Status {
	id := wire.unpack(r, u64)
	if g.dock == nil || id == 0 {return .Unsupported}
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
		b.call_add(rawptr(fresh), rawptr(display), g.add)
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
		function(object, display, g.dock, id, id)
		current := m.SLSManagedDisplayGetCurrentSpace(g.cid, uuid)
		set_ivar(display, "_currentSpace", space_object(uuid, current))
	case .Space_Move:
		destination := wire.unpack(r, u64);previous := wire.unpack(r, u64)
		follow_byte := wire.unpack(r, u8)
		if follow_byte > 1 {return .Invalid_Message}
		follow := follow_byte == 1
		if g.move == nil || g.pictures == nil {return .Unsupported}
		target_uuid := SLSCopyManagedDisplayForSpace(g.cid, destination)
		if target_uuid == nil {return .Operation_Failed}
		defer m.CFRelease(target_uuid)
		target := space_object(target_uuid, destination)
		target_display := display_object(target_uuid)
		if target == nil || target_display == nil || id == destination {return .Operation_Failed}
		display_id := send(u32, g.dock, "displayIDForSpace:", target)
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
		b.call_move(rawptr(object), rawptr(target), target_uuid, rawptr(g.dock), g.move)
		send(nil, g.pictures, "moveSpace:toDisplay:displayUUID:", object, display_id, target_uuid)
		if follow {return focus_space(id)}
	case:
		return .Invalid_Message
	}
	return .OK
}

alternate_user_space :: proc(uuid: m.Ref, excluded: u64) -> u64 {
	list := send(Object, g.dock, "spacesForDisplay:", uuid)
	for i in 0 ..< send(uint, list, "count") {
		space := send(Object, list, "objectAtIndex:", i)
		id := send(u64, space, "spid")
		if id != excluded && SLSSpaceGetType(g.cid, id) == 0 {return id}
	}
	return 0
}
