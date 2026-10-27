package payload

import recovery "../recovery"
import e "../../engine"
import m "../../macos"
import wire "../protocol"
import "core:math"
import "core:time"

Fade :: struct {
	start, end: f32,
	began:      time.Time,
	duration:   f64,
}
hidden_proxies: map[u32]recovery.Entry
payload_recovery_owner :: proc(user: rawptr, window: u32) -> (i32, bool) {
	owner: i32
	code := SLSGetWindowOwner(g.cid, window, &owner)
	return owner, code == 0
}
payload_recovery_restore :: proc(user: rawptr, entry: recovery.Entry, proxy_valid: bool) -> bool {
	transaction := SLSTransactionCreate(g.cid)
	if transaction == nil {return false}; defer m.CFRelease(transaction)
	SLSTransactionSetWindowSystemAlpha(transaction, entry.window, 1)
	if proxy_valid {SLSTransactionOrderWindowGroup(transaction, entry.proxy, 0, entry.window)}
	SLSTransactionCommit(transaction, 0)
	// This acknowledges a restoration request, not a pixel-level observation.
	// Ownership was checked by recovery.restore before this callback.
	return true
}
tick_proxy_recovery :: proc() {
	done := make([dynamic]u32, context.temp_allocator)
	backend := recovery.Backend {payload_recovery_owner, payload_recovery_restore, nil}
	for window, entry in hidden_proxies {
		result := recovery.restore(entry, backend, true)
		if result == .Restored || result == .Gone {append(&done, window)}
	}
	for window in done {delete_key(&hidden_proxies, window)}
}
fades: map[u32]Fade
status :: proc(code: i32) -> wire.Status {return code == 0 ? .OK : .Operation_Failed}
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
window_action :: proc(op: wire.Opcode, r: ^wire.Reader, diagnostic: ^wire.Native_Failure) -> wire.Status {
	if op == .Window_To_Space || op == .Window_List_To_Space {
		sid := wire.unpack(r, u64);if sid == 0 {return .Invalid_Message}
		values := make([dynamic]u64, 0, 8, context.temp_allocator)
		if op == .Window_To_Space {append(&values, u64(wire.unpack(r, u32)))} else {
			count := wire.unpack(r, i32)
			for _ in 0 ..< count {append(&values, u64(wire.unpack(r, u32)))}
		}
		for id in values {if id == 0 {return .Invalid_Message}}
		array := array_u64(values[:]);defer m.CFRelease(array)
		SLSMoveWindowsToManagedSpace(g.cid, array, sid)
		return .OK
	}
	if op == .Proxy_In || op == .Proxy_Out || op == .Window_Order_In {
		count := wire.unpack(r, i32)
		// Register every window before any transaction can hide it, including
		// transactions whose commit reports an ambiguous failure.
		check := r^
		ids := make([dynamic]u32, context.temp_allocator)
		for _ in 0..<count {
			id := wire.unpack(&check, u32)
			if id == 0 {continue}
			append(&ids, id)
			if op == .Window_Order_In {continue}
			proxy := wire.unpack(&check, u32)
			if op != .Proxy_In {continue}
			owner, real_ok := payload_recovery_owner(nil, id)
			proxy_owner, proxy_ok := payload_recovery_owner(nil, proxy)
			if !real_ok || !proxy_ok || proxy == 0 || id == proxy {return .Invalid_Message}
			entry := recovery.Entry {id, proxy, owner, proxy_owner}
			if previous, exists := hidden_proxies[id]; exists && previous != entry {return .Operation_Failed}
			if len(hidden_proxies) >= 256 && id not_in hidden_proxies {return .Operation_Failed}
			hidden_proxies[id] = entry
		}
		transaction := SLSTransactionCreate(g.cid)
		if transaction == nil {wire.note_native_failure(diagnostic, .Transaction_Create, -1);return .Operation_Failed};defer m.CFRelease(transaction)
		for _ in 0 ..< count {
			id := wire.unpack(r, u32);if id == 0 {continue}
			if op ==
			   .Window_Order_In {
				SLSTransactionOrderWindowGroup(transaction, id, 1, 0)
			} else {
				proxy := wire.unpack(r, u32)
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
	id := wire.unpack(r, u32)
	if id == 0 {return .Invalid_Message}
	#partial switch op {
	case .Window_Move:
		x := wire.unpack(r, i32);y := wire.unpack(r, i32);point := m.Point{f64(x), f64(y)}
		code := SLSMoveWindowWithGroup(g.cid, id, &point)
		array := array_u64([]u64{u64(id)});defer m.CFRelease(array)
		code |= SLSReassociateWindowsSpacesByGeometry(g.cid, array)
		return status(code)
	case .Window_Opacity, .Window_Opacity_Fade:
		alpha := wire.unpack(r, f32);duration: f32
		if op == .Window_Opacity_Fade {duration = wire.unpack(r, f32)}
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
		layer, valid := wire.normalize_window_layer_key(wire.unpack(r, i32))
		if !valid {return .Invalid_Message}
		return status(SLSSetWindowSubLevel(g.cid, id, CGWindowLevelForKey(layer)))
	case .Window_Sticky, .Window_Shadow:
		enabled := wire.unpack(r, u8)
		if enabled > 1 {return .Invalid_Message}
		tags: u64 = 1 << 11;set := enabled == 1
		if op == .Window_Shadow {tags = 1 << 3;set = !set}
		if set {return status(SLSSetWindowTags(g.cid, id, &tags, 64))}
		return status(SLSClearWindowTags(g.cid, id, &tags, 64))
	case .Window_Focus:
		if g.focus == nil {return .Unsupported}
		owner: i32;psn: PSN
		if SLSGetWindowOwner(g.cid, id, &owner) != 0 ||
		   SLSGetConnectionPSN(owner, &psn) != 0 {return .Operation_Failed}
		(cast(proc "c" (_: PSN, _: u32))g.focus)(psn, id)
		return .OK
	case .Window_Order:
		order := wire.unpack(r, i32);relative := wire.unpack(r, u32)
		if order < -1 || order > 1 {return .Invalid_Message}
		// Commit group ordering explicitly; the ordinary setter can acknowledge
		// without publishing the new order for windows owned by another app.
		transaction := SLSTransactionCreate(g.cid)
		if transaction == nil {wire.note_native_failure(diagnostic, .Transaction_Create, -1);return .Operation_Failed}
		defer m.CFRelease(transaction)
		SLSTransactionOrderWindowGroup(transaction, id, order, relative)
		SLSTransactionCommit(transaction, 1)
		return .OK
	case .Window_Scale:
		x := wire.unpack(r, f32);y := wire.unpack(r, f32);width := wire.unpack(r, f32)
		height := wire.unpack(r, f32)
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
		frame: e.Rect
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
