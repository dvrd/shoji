package bridge

// Explicit register reads keep implicit ABI inputs visible to the template checker.
// All volatile registers are clobbered, including SIMD registers.
// Dock's Swift entry points receive their implicit context in r13.
call_add :: asm(object, owner, function: rawptr) [
	object = %rdi, owner = %r13, function = %r11,
	#clobber %rax,
	#clobber %rcx,
	#clobber %rdx,
	#clobber %rsi,
	#clobber %r8,
	#clobber %r9,
	#clobber %r10,
	#clobber %rdi,
	#clobber %r11,
	#clobber %xmm0,
	#clobber %xmm1,
	#clobber %xmm2,
	#clobber %xmm3,
	#clobber %xmm4,
	#clobber %xmm5,
	#clobber %xmm6,
	#clobber %xmm7,
	#clobber %xmm8,
	#clobber %xmm9,
	#clobber %xmm10,
	#clobber %xmm11,
	#clobber %xmm12,
	#clobber %xmm13,
	#clobber %xmm14,
	#clobber %xmm15,
	#clobber memory,
	#align_stack,
	#volatile,
] {
	test object, object;
	test owner, owner;
	test function, function;
	jz .done;
	call function;
	.done:
	nop;
}
call_move :: asm(source, destination, uuid, owner, function: rawptr) [
	source = %rdi, destination = %rsi, uuid = %rdx, owner = %r13, function = %r11,
	#clobber %rax,
	#clobber %rcx,
	#clobber %r8,
	#clobber %r9,
	#clobber %r10,
	#clobber %rdi,
	#clobber %r11,
	#clobber %rsi,
	#clobber %rdx,
	#clobber %xmm0,
	#clobber %xmm1,
	#clobber %xmm2,
	#clobber %xmm3,
	#clobber %xmm4,
	#clobber %xmm5,
	#clobber %xmm6,
	#clobber %xmm7,
	#clobber %xmm8,
	#clobber %xmm9,
	#clobber %xmm10,
	#clobber %xmm11,
	#clobber %xmm12,
	#clobber %xmm13,
	#clobber %xmm14,
	#clobber %xmm15,
	#clobber memory,
	#align_stack,
	#volatile,
] {
	test source, source;
	test destination, destination;
	test uuid, uuid;
	test owner, owner;
	test function, function;
	jz .done;
	call function;
	.done:
	nop;
}
sign_function :: proc "contextless" (p: u64) -> u64 { return p }
strip_function :: proc "contextless" (p: u64) -> u64 { return p }
