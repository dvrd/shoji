package dock

// Explicit register reads keep implicit ABI inputs visible to the template checker.
// All volatile registers are clobbered, including SIMD registers.
// Dock's Swift entry points receive their implicit context in x20.
call_add :: asm(object, owner, function: rawptr) [
	object = %x0, owner = %x20, function = %x16,
	#clobber %x30,
	#clobber %x1,
	#clobber %x2,
	#clobber %x3,
	#clobber %x4,
	#clobber %x5,
	#clobber %x6,
	#clobber %x7,
	#clobber %x8,
	#clobber %x9,
	#clobber %x10,
	#clobber %x11,
	#clobber %x12,
	#clobber %x13,
	#clobber %x14,
	#clobber %x15,
	#clobber %x17,
	#clobber %x0,
	#clobber %x16,
	#clobber %v0,
	#clobber %v1,
	#clobber %v2,
	#clobber %v3,
	#clobber %v4,
	#clobber %v5,
	#clobber %v6,
	#clobber %v7,
	#clobber %v16,
	#clobber %v17,
	#clobber %v18,
	#clobber %v19,
	#clobber %v20,
	#clobber %v21,
	#clobber %v22,
	#clobber %v23,
	#clobber %v24,
	#clobber %v25,
	#clobber %v26,
	#clobber %v27,
	#clobber %v28,
	#clobber %v29,
	#clobber %v30,
	#clobber %v31,
	#clobber %v8,
	#clobber %v9,
	#clobber %v10,
	#clobber %v11,
	#clobber %v12,
	#clobber %v13,
	#clobber %v14,
	#clobber %v15,
	#clobber memory,
	#volatile,
] {
	cmp object, object;
	cmp owner, owner;
	cbz function, .done;
	blr function;
	.done:
	nop;
}
call_move :: asm(source, destination, uuid, owner, function: rawptr) [
	source = %x0, destination = %x1, uuid = %x2, owner = %x20, function = %x16,
	#clobber %x30,
	#clobber %x3,
	#clobber %x4,
	#clobber %x5,
	#clobber %x6,
	#clobber %x7,
	#clobber %x8,
	#clobber %x9,
	#clobber %x10,
	#clobber %x11,
	#clobber %x12,
	#clobber %x13,
	#clobber %x14,
	#clobber %x15,
	#clobber %x17,
	#clobber %x0,
	#clobber %x16,
	#clobber %x1,
	#clobber %x2,
	#clobber %v0,
	#clobber %v1,
	#clobber %v2,
	#clobber %v3,
	#clobber %v4,
	#clobber %v5,
	#clobber %v6,
	#clobber %v7,
	#clobber %v16,
	#clobber %v17,
	#clobber %v18,
	#clobber %v19,
	#clobber %v20,
	#clobber %v21,
	#clobber %v22,
	#clobber %v23,
	#clobber %v24,
	#clobber %v25,
	#clobber %v26,
	#clobber %v27,
	#clobber %v28,
	#clobber %v29,
	#clobber %v30,
	#clobber %v31,
	#clobber %v8,
	#clobber %v9,
	#clobber %v10,
	#clobber %v11,
	#clobber %v12,
	#clobber %v13,
	#clobber %v14,
	#clobber %v15,
	#clobber memory,
	#volatile,
] {
	cmp source, source;
	cmp destination, destination;
	cmp uuid, uuid;
	cmp owner, owner;
	cbz function, .done;
	blr function;
	.done:
	nop;
}
@(enable_target_feature="pauth")
sign_function :: asm(p: u64) -> (r: u64) { mov r, p;
	paciza r;
}
@(enable_target_feature="pauth")
strip_function :: asm(p: u64) -> (r: u64) { mov r, p;
	xpaci r;
}
