package loader

// Darwin's setters for a fresh (zero-flags) arm64e thread state use distinct
// discriminators, not the zero discriminator used for ordinary function pointers.
// Values verified against the SDK's ptrauth_string_discriminator("pc"/"sp").
sign_thread_pc :: proc(p: u64) -> u64 { return sign_code(p, 29825) }
sign_thread_sp :: proc(p: u64) -> u64 { return sign_data(p, 52205) }

@(link_section = "__TEXT,__shoji_boot", no_instrumentation)
@(enable_target_feature="pauth")
sign_worker :: asm(p: u64) -> (r: u64) {
	mov r, p;
	paciza r;
}

@(enable_target_feature="pauth")
sign_code :: asm(p, discriminator: u64) -> (r: u64) {
	mov r, p;
	pacia r, discriminator;
}
@(enable_target_feature="pauth")
sign_data :: asm(p, discriminator: u64) -> (r: u64) {
	mov r, p;
	pacda r, discriminator;
}
