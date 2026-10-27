package tests

import mac "../src/macos"
import "core:testing"

@(test)
accessory_polling_requires_an_on_screen_window_or_frontmost_application :: proc(t: ^testing.T) {
	owners := make(map[i32]bool)
	defer delete(owners)
	owners[42] = true
	testing.expect(t, mac.poll_application_windows(42, 1, 43, owners, true))
	testing.expect(t, mac.poll_application_windows(43, 1, 43, owners, true))
	testing.expect(t, !mac.poll_application_windows(44, 1, 43, owners, true))
	// Regular apps retain background window/tab reconciliation.
	testing.expect(t, mac.poll_application_windows(44, 0, 43, owners, true))
	testing.expect(t, !mac.poll_application_windows(42, 2, 43, owners, true))
	// Failed WindowServer discovery must not suppress accessory discovery.
	testing.expect(t, mac.poll_application_windows(44, 1, 43, owners, false))
}
