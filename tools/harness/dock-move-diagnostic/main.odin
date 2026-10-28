package main

import mac "../../../src/macos"
import e "../../../src/engine"
import wire "../../../src/addition/protocol"
import "core:fmt"
import "core:os"
import "core:strconv"
foreign import system "system:System"
foreign system {proc_pidpath :: proc "c" (pid: i32, buffer: rawptr, size: u32) -> i32 ---}

main :: proc() {
	if len(os.args) != 3 {fmt.eprintln("expected fixture PID and window ID"); os.exit(2)}
	pid_value, pid_ok := strconv.parse_i64(os.args[1]); wid_value, wid_ok := strconv.parse_u64(os.args[2])
	if !pid_ok || !wid_ok || pid_value <= 0 || pid_value > 0x7fffffff || wid_value == 0 || wid_value > 0xffffffff {os.exit(2)}
	pid, wid := i32(pid_value), u32(wid_value)
	path: [4096]u8
	if proc_pidpath(pid,&path[0],u32(len(path))) <= 0 || string(cstring(&path[0])) != "/private/tmp/shoji-dock-move-vm/fixture" {fmt.eprintln("fixture executable mismatch"); os.exit(1)}
	pool := mac.pool_push(); defer mac.pool_pop(pool)
	mac.NSApplicationLoad()
	cid := mac.SLSMainConnectionID(); if cid == 0 {fmt.eprintln("WindowServer unavailable"); os.exit(1)}
	owner, known := mac.animation_recovery_query_owner(cid, wid); actual: i32
	if !known || mac.SLSConnectionGetPID(owner, &actual) != 0 || actual != pid {fmt.eprintln("fixture owner mismatch"); os.exit(1)}
	before: e.Rect
	if mac.SLSGetWindowBounds(cid,wid,&before)!=0 {fmt.eprintln("cannot read fixture bounds"); os.exit(1)}
	packet := wire.begin(.Window_Move)
	wire.pack(&packet,wid); wire.pack(&packet,i32(before.x)-20); wire.pack(&packet,i32(before.y))
	_, err := mac.addition_exchange(&packet)
	after: e.Rect; code := mac.SLSGetWindowBounds(cid,wid,&after)
	fmt.printf("window=%d requested_x=%d before=%v after=%v readback_status=%d response=%s\n",wid,i32(before.x)-20,before,after,code,err)
	if code != 0 {os.exit(1)}
}
