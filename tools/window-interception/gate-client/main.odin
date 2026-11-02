package main

// Mach gate client (B1). Sends versioned commands to the payload's Mach
// service inside WindowServer and prints the reply. The payload accepts
// commands only from the registered owner process (first HELLO wins).
import "core:fmt"
import "core:os"
import "core:strconv"
import hook "../../../src/experimental/window_server"

foreign import system "system:System"

@(default_calling_convention = "c")
foreign system {
	@(link_name = "mach_task_self") client_mach_task_self :: proc "c" () -> u32 ---
	dlopen :: proc "c" (path: cstring, mode: i32) -> rawptr ---
	dlsym :: proc "c" (handle: rawptr, symbol: cstring) -> rawptr ---
}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: shoji-gate-client hello | arm WID [SCOPE] | release | status | dump")
		os.exit(2)
	}
	command: hook.Gate_Command
	arg0, arg1: u64
	switch os.args[1] {
	case "hello":
		command = .Hello
		arg0 = 0x53484f4a
	case "arm":
		if len(os.args) < 3 {
			fmt.eprintln("arm requires a window id")
			os.exit(2)
		}
		wid, ok := strconv.parse_u64(os.args[2])
		if !ok || wid == 0 {
			fmt.eprintln("arm requires a decimal window id")
			os.exit(2)
		}
		command = .Arm
		arg0 = wid
		arg1 = 3
		if len(os.args) > 3 {
			scope, sok := strconv.parse_u64(os.args[3])
			if sok {arg1 = scope}
		}
	case "release":
		command = .Release
	case "status":
		command = .Status
	case "dump":
		command = .Dump
	case:
		fmt.eprintf("unknown command %q\n", os.args[1])
		os.exit(2)
	}

	bootstrap := dlopen("/usr/lib/system/libsystem_bootstrap.dylib", 2)
	if bootstrap == nil {
		fmt.eprintln("FAIL: dlopen libsystem_bootstrap")
		os.exit(1)
	}
	bp_ptr := (^u32)(dlsym(bootstrap, "bootstrap_port"))
	if bp_ptr == nil {
		fmt.eprintln("FAIL: dlsym bootstrap_port")
		os.exit(1)
	}
	service: u32
	if code := hook.gate_bootstrap_look_up(bp_ptr^, hook.GATE_SERVICE_NAME, &service); code != 0 {
		fmt.eprintf("FAIL: service lookup %s (%d)\n", hook.GATE_SERVICE_NAME, code)
		os.exit(1)
	}
	task := client_mach_task_self()
	reply: u32
	if code := hook.gate_mach_port_allocate(task, hook.MACH_PORT_RIGHT_RECEIVE, &reply); code != 0 {
		fmt.eprintf("FAIL: reply port allocate (%d)\n", code)
		os.exit(1)
	}
	defer hook.gate_mach_port_deallocate(task, reply)

	msg: [128]u8
	put32 :: proc(msg: ^[128]u8, off: uintptr, value: u32) {(^u32)(uintptr(msg) + off)^ = value}
	put64 :: proc(msg: ^[128]u8, off: uintptr, value: u64) {(^u64)(uintptr(msg) + off)^ = value}
	put32(&msg, 0, hook.MACH_MSG_TYPE_COPY_SEND | (hook.MACH_MSG_TYPE_MAKE_SEND_ONCE << 8))
	put32(&msg, 4, hook.GATE_MSG_SIZE)
	put32(&msg, 8, service)
	put32(&msg, 12, reply)
	put32(&msg, 16, 0)
	put32(&msg, 20, 1)
	put32(&msg, hook.GATE_OFF_MAGIC, hook.GATE_MAGIC)
	put32(&msg, hook.GATE_OFF_VERSION, hook.GATE_VERSION)
	put32(&msg, hook.GATE_OFF_COMMAND, u32(command))
	put64(&msg, hook.GATE_OFF_ARG0, arg0)
	put64(&msg, hook.GATE_OFF_ARG1, arg1)

	options := u32(hook.MACH_MSG_SEND) | u32(hook.MACH_MSG_RECEIVE)
	code := hook.gate_mach_msg(&msg[0], options, hook.GATE_MSG_SIZE, len(msg), reply, 1000, 0)
	if code != 0 {
		fmt.eprintf("FAIL: mach_msg (%#x)\n", u32(code))
		os.exit(1)
	}
	rmagic := (^u32)(uintptr(&msg[0]) + hook.GATE_OFF_MAGIC)^
	rstatus := (^i32)(uintptr(&msg[0]) + hook.GATE_OFF_COMMAND + 4)^
	data0 := (^u64)(uintptr(&msg[0]) + hook.GATE_OFF_ARG0)^
	data1 := (^u64)(uintptr(&msg[0]) + hook.GATE_OFF_ARG1)^
	fmt.printf("reply: magic=%#x version=%d command=%d status=%d data0=%#x data1=%#x\n",
		rmagic,
		(^u32)(uintptr(&msg[0]) + hook.GATE_OFF_VERSION)^,
		(^u32)(uintptr(&msg[0]) + hook.GATE_OFF_COMMAND)^,
		rstatus, data0, data1)
	if rmagic != hook.GATE_REPLY_MAGIC || rstatus != 0 {
		os.exit(1)
	}
}
