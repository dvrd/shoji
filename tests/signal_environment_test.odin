package tests

import e "../src/engine"
import mac "../src/macos"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
signal_shell_receives_shoji_event_identifiers :: proc(t: ^testing.T) {
	file, err := os.create_temp_file("", "shoji-signal-*")
	if !testing.expect(t, err == nil) {return}
	path := strings.clone(os.name(file))
	os.close(file)
	defer delete(path)
	defer os.remove(path)

	state: mac.State
	e.manager_init(&state.manager)
	defer e.manager_destroy(&state.manager)
	action := fmt.tprintf(
		`action=printf '%%s:%%s:%%s:%%s:%%s:%%s:%%s' "$SHOJI_WINDOW_ID" "$SHOJI_RECENT_WINDOW_ID" "$SHOJI_PROCESS_ID" "$SHOJI_SPACE_ID" "$SHOJI_RECENT_SPACE_ID" "$SHOJI_DISPLAY_ID" "$SHOJI_RECENT_DISPLAY_ID" > '%s'`,
		path,
	)
	response := e.execute(&state.manager, {"signal", "--add", "event=window_focused", action})
	if !testing.expect(t, !response.failed, response.text) {return}
	mac.emit(&state, {
		name = "window_focused", window = 21, recent_window = 22, pid = 23,
		space = 24, recent_space = 25, display = 26, recent_display = 27,
	})
	deadline := time.time_add(time.now(), 2 * time.Second)
	for time.diff(time.now(), deadline) > 0 {
		data, read_err := os.read_entire_file(path, context.allocator)
		matches := read_err == nil && string(data) == "21:22:23:24:25:26:27"
		delete(data)
		if matches {return}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, false, "signal shell did not receive the event identifiers")
}
