package main

import "core:fmt"
import "core:os"
import "base:intrinsics"
import inject "../../../../src/inject"

foreign import fixture "../../../../bin/shoji-ws-abi-native.o"

Ordering_Callback :: proc "c" (connection: rawptr, ids: [^]u32, operations: [^]i32, relative: [^]u32, count: u32, flag: bool) -> i32
Raw_Ordering_Callback :: proc "c" (connection: rawptr, ids: [^]u32, operations: [^]i32, relative: [^]u32, count: u32, flag: u32) -> i32

foreign fixture {
	shoji_abi_placement_address :: proc "c" (which: u32) -> rawptr ---
	shoji_abi_original :: proc "c" (connection: rawptr, ids: [^]u32, operations: [^]i32, relative: [^]u32, count: u32, flag: bool) -> i32 ---
	shoji_abi_run :: proc "c" (callback: Ordering_Callback) -> i32 ---
	shoji_abi_raw_original :: proc "c" (connection: rawptr, ids: [^]u32, operations: [^]i32, relative: [^]u32, count: u32, flag: u32) -> i32 ---
	shoji_abi_raw_run :: proc "c" (callback: Raw_Ordering_Callback) -> i32 ---
}

forward_calls: u64

forward :: proc "c" (connection: rawptr, ids: [^]u32, operations: [^]i32, relative: [^]u32, count: u32, flag: bool) -> i32 {
	intrinsics.atomic_add_explicit(&forward_calls, 1, .Relaxed)
	if trampoline_original != nil {
		return trampoline_original(connection, ids, operations, relative, count, flag)
	}
	return shoji_abi_original(connection, ids, operations, relative, count, flag)
}

raw_forward :: proc "c" (connection: rawptr, ids: [^]u32, operations: [^]i32, relative: [^]u32, count: u32, flag: u32) -> i32 {
	return shoji_abi_raw_original(connection, ids, operations, relative, count, flag)
}

main :: proc() {
	// Regression for the 2026-11-04 signed-pointer/BLR failure. This exercises
	// lookup, four-double C struct return and pointer+double movement ABI using
	// owned C data, before any optional trampoline experiments.
	Rect :: struct {x, y, w, h: f64}
	lookup := transmute(proc "c" (wid: u32) -> rawptr)shoji_abi_placement_address(0)
	bounds := transmute(proc "c" (window: rawptr) -> Rect)shoji_abi_placement_address(1)
	move := transmute(proc "c" (connection, window, options: rawptr, dx, dy: f64))shoji_abi_placement_address(2)
	window := lookup(42)
	if window == nil {fmt.eprintln("FAIL: placement lookup ABI"); os.exit(1)}
	before := bounds(window)
	move(rawptr(uintptr(0x1234)), window, nil, 600 - before.x, 400 - before.y)
	after := bounds(window)
	if after.x != 600 || after.y != 400 || after.w != 320 || after.h != 232 {
		fmt.eprintln("FAIL: placement C ABI"); os.exit(1)
	}
	fmt.println("PASS: raw-address placement ABI; lookup, CGRect HFA return, three pointers + two doubles")
	// The native compiler authenticates C function pointers. The Odin callback
	// itself is a raw procedure value in this project's arm64e compiler.
	callback := transmute(Ordering_Callback)uintptr(inject.sign_function(u64(uintptr(rawptr(forward)))))
	if len(os.args) == 2 && os.args[1] == "--trampoline" {
		run_trampoline(callback)
		return
	}
	if len(os.args) == 2 && os.args[1] == "--inline-trampoline" {
		run_inline_trampoline(callback)
		return
	}
	code := shoji_abi_run(callback)
	if code != 0 {
		fmt.eprintf("FAIL: owned C/Odin six-argument ABI fixture (%d)\n", code)
		os.exit(1)
	}
	raw_callback := transmute(Raw_Ordering_Callback)uintptr(inject.sign_function(u64(uintptr(rawptr(raw_forward)))))
	if code := shoji_abi_raw_run(raw_callback); code != 0 {
		fmt.eprintf("FAIL: owned C/Odin raw flag fixture (%d)\n", code)
		os.exit(1)
	}
	fmt.println("PASS: C -> Odin -> C; pointer arrays, count, canonical booleans, raw flag 2, null arrays, signed and wide returns")
}
