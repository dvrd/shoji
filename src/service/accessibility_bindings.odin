package service

// The Accessibility trust checks `service start` waits on before launching
// the daemon. The daemon's own bindings live in the root package's backend.

import "../native"

foreign import accessibility_ax "system:ApplicationServices.framework"
foreign import accessibility_cf "system:CoreFoundation.framework"

@(default_calling_convention = "c")
foreign accessibility_ax {
	AXIsProcessTrusted :: proc() -> bool ---
	AXIsProcessTrustedWithOptions :: proc(options: native.Ref) -> bool ---
	kAXTrustedCheckOptionPrompt: native.Ref
}

@(default_calling_convention = "c")
foreign accessibility_cf {
	CFDictionaryCreate :: proc(
		allocator: native.Ref,
		keys, values: [^]native.Ref,
		count: int,
		key_callbacks, value_callbacks: native.Ref,
	) -> native.Ref ---
	kCFBooleanTrue: native.Ref
}
