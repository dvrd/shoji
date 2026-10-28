package main

import "core:fmt"
import "core:os"
import bridge "../../../src/addition/bridge"

foreign import fixture "../../../bin/shoji-ws-abi-native.o"

Ordering_Callback :: proc "c" (connection: rawptr, ids: [^]u32, operations: [^]i32, relative: [^]u32, count: u32, flag: bool) -> i32

foreign fixture {
	shoji_abi_original :: proc "c" (connection: rawptr, ids: [^]u32, operations: [^]i32, relative: [^]u32, count: u32, flag: bool) -> i32 ---
	shoji_abi_run :: proc "c" (callback: Ordering_Callback) -> i32 ---
}

forward :: proc "c" (connection: rawptr, ids: [^]u32, operations: [^]i32, relative: [^]u32, count: u32, flag: bool) -> i32 {
	if trampoline_original != nil {
		return trampoline_original(connection, ids, operations, relative, count, flag)
	}
	return shoji_abi_original(connection, ids, operations, relative, count, flag)
}

main :: proc() {
	// The native compiler authenticates C function pointers. The Odin callback
	// itself is a raw procedure value in this project's arm64e compiler.
	callback := transmute(Ordering_Callback)uintptr(bridge.sign_function(u64(uintptr(rawptr(forward)))))
	if len(os.args) == 2 && os.args[1] == "--trampoline" {
		run_trampoline(callback)
		return
	}
	code := shoji_abi_run(callback)
	if code != 0 {
		fmt.eprintf("FAIL: owned C/Odin six-argument ABI fixture (%d)\n", code)
		os.exit(1)
	}
	fmt.println("PASS: C -> Odin -> C; three pointer arrays, count, both booleans, null arrays, signed and wide returns")
}
