package payload

import m "../../macos"
import "base:intrinsics"
import objc "core:sys/darwin/Foundation"

Object :: ^objc.Object
send :: intrinsics.objc_send
foreign import sls "system:SkyLight.framework"
foreign import sys "system:System"
foreign import cg "system:CoreGraphics.framework"
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
	SLSReassociateWindowsSpacesByGeometry :: proc(cid: i32, windows: m.Ref) -> i32 ---
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
	SLSTransactionCommit :: proc(transaction: m.Ref, synchronous: i32) -> i32 ---
	SLSTransactionOrderWindowGroup :: proc(transaction: m.Ref, wid: u32, order: i32, relative: u32) -> i32 ---
	SLSTransactionSetWindowSystemAlpha :: proc(transaction: m.Ref, wid: u32, alpha: f32) -> i32 ---
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
