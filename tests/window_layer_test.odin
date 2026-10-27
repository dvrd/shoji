package tests

import wire "../src/addition/protocol"
import "core:testing"

foreign import layer_cg "system:CoreGraphics.framework"
foreign layer_cg {CGWindowLevelForKey :: proc "c" (key: i32) -> i32 ---}

@(test)
native_window_layer_keys_order_documents_below_utility_panels :: proc(t: ^testing.T) {
	caps := wire.Capabilities{.Window_Layer_Keys}
	below := CGWindowLevelForKey(wire.window_layer_key(-1, caps))
	normal := CGWindowLevelForKey(wire.window_layer_key(0, caps))
	above := CGWindowLevelForKey(wire.window_layer_key(1, caps))
	testing.expect(t, below < normal && normal < above)
	testing.expect_value(t, below, i32(-20))
	testing.expect_value(t, normal, i32(0))
	testing.expect_value(t, above, i32(3))
}

@(test)
loaded_legacy_payload_uses_normal_documents_instead_of_the_broken_below_key :: proc(
	t: ^testing.T,
) {
	below_key := wire.window_layer_key(-1, {})
	above_key := wire.window_layer_key(1, {})
	testing.expect_value(t, below_key, i32(4))
	testing.expect_value(t, above_key, i32(6))
	testing.expect(t, CGWindowLevelForKey(below_key) < CGWindowLevelForKey(above_key))
}

@(test)
payload_corrects_legacy_layer_keys_and_rejects_unknown_values :: proc(t: ^testing.T) {
	for pair in ([5][2]i32{{1, 3}, {3, 3}, {4, 4}, {5, 5}, {6, 5}}) {
		key, ok := wire.normalize_window_layer_key(pair[0])
		testing.expect(t, ok)
		testing.expect_value(t, key, pair[1])
	}
	for invalid in ([]i32{-1, 0, 2, 7, 1000}) {
		_, ok := wire.normalize_window_layer_key(invalid)
		testing.expect(t, !ok)
	}
}
