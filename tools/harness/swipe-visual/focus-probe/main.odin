package main

import e "../../../../src/engine"
import mac "../../../../src/macos"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
foreign import system "system:System"
foreign system {proc_pidpath :: proc "c" (pid: i32, buffer: rawptr, size: u32) -> i32 ---}
main :: proc() {
	if len(os.args) != 3 {os.exit(2)}
	pid_value, p_ok := strconv.parse_i64(os.args[1]); id_value, i_ok := strconv.parse_u64(os.args[2])
	if !p_ok || !i_ok || pid_value<=0 || pid_value>0x7fffffff || id_value==0 || id_value>0xffffffff {os.exit(2)}
	pid,id := i32(pid_value),u32(id_value)
	path: [4096]u8
	if proc_pidpath(pid,&path[0],u32(len(path)))<=0 || !strings.has_suffix(string(cstring(&path[0])),"/VirtualBuddy.app/Contents/MacOS/VirtualBuddy") {fmt.eprintln("unexpected application");os.exit(1)}
	if !mac.AXIsProcessTrusted() {fmt.eprintln("Accessibility permission unavailable");os.exit(1)}
	pool := mac.pool_push(); defer mac.pool_pop(pool)
	state: mac.State; mac.state_init(&state); defer mac.state_destroy(&state)
	state.validation_pid = pid
	owner, known := mac.animation_recovery_query_owner(state.connection,id); actual: i32
	if !known || mac.SLSConnectionGetPID(owner,&actual)!=0 || actual!=pid {fmt.eprintln("window owner mismatch");os.exit(1)}
	app := mac.AXUIElementCreateApplication(pid); if app==nil {os.exit(1)}
	state.applications[pid] = {element=app,name=strings.clone("VirtualBuddy")}
	windows := mac.attribute(app,"AXWindows"); if windows==nil {fmt.eprintln("AXWindows unavailable");os.exit(1)}; defer mac.CFRelease(windows)
	for i in 0..<mac.CFArrayGetCount(windows) {
		el := mac.CFArrayGetValueAtIndex(windows,i); candidate: u32
		if mac._AXUIElementGetWindow(el,&candidate)==0 && candidate==id {
			state.windows[id] = mac.CFRetain(el); break
		}
	}
	if state.windows[id]==nil {fmt.eprintln("fixture window unavailable");os.exit(1)}
	e.add_window(&state.manager,{id=id,pid=pid,role="AXWindow",subrole="AXStandardWindow"})
	if err := mac.perform(&state,{kind=.Focus,window=id}); err!="" {fmt.eprintln(err);os.exit(1)}
	if !mac.native_focus_verified(&state,pid,id) {fmt.eprintln("focus did not verify");os.exit(1)}
	fmt.printf("verified target window %d is focused\n",id)
}
