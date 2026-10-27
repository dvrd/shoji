package harness

import s "../../../src/support"
import tc "../../common"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:time"

Live_Rect :: struct {
	x, y, w, h: f64,
}
Live_Window :: struct {
	id: u32,
	pid: int,
	space: u32,
	frame: Live_Rect,
	focused: bool `json:"has-focus"`,
	floating: bool `json:"is-floating"`,
	minimized: bool `json:"is-minimized"`,
	visible: bool `json:"is-visible"`,
}
Desktop_Check :: enum {
	Ready,
	Frames,
	Focus,
	Floating,
	Minimized,
	Restored,
	Closed,
	Empty,
}
desktop_guard :: proc(c: tc.Context) -> string {
	r := s.run(
		c.executor,
		[]string{tc.binary(c, "shoji"), "-m", "query", "--windows"},
		timeout = 10 * time.Second,
	)
	return(
		r.code == 0 \
			? "a Shoji daemon is already running; refusing to replace it" \
			: "" \
	)
}
owned_windows :: proc(l: ^Live, pid: int) -> ([]Live_Window, string) {
	text, err := live_client(l, "query", "--windows"); if err != "" {
		return nil, err
	}
	values: []Live_Window
	if e := json.unmarshal(transmute([]u8)text, &values, .JSON); e != nil {
		return nil, "invalid window query JSON"
	}
	for window in values {
		if window.pid != pid {
			return nil,
				"validation daemon observed an application outside its fixture"
		}
	}
	return values, ""
}
wait_desktop :: proc(
	l: ^Live,
	pid: int,
	first, second: u32,
	check: Desktop_Check,
	daemon: ^Child,
) -> string {
	start := time.tick_now()
	for time.tick_since(start) < 8 * time.Second {
		if !child_alive(daemon) {
			return "validation daemon exited; see daemon.stderr"
		}
		windows, err := owned_windows(l, pid)
		if err != "" {
			if check == .Ready {
				time.sleep(100 * time.Millisecond); continue
			}; return err
		}
		a, b: Live_Window; has_a, has_b := false, false
		for window in windows {
			if window.id == first {
				a = window; has_a = true
			}; if window.id == second {
				b = window; has_b = true
			}
		}
		passed := false
		switch check {
		case .Ready:
			passed = len(windows) == 2 && has_a && has_b
		case .Focus:
			passed = has_a && a.focused
		case .Floating:
			passed = has_a && a.floating
		case .Minimized:
			passed = has_a && a.minimized
		case .Restored:
			passed = has_a && !a.minimized
		case .Closed:
			passed = !has_b || !b.visible && !b.minimized
		case .Empty:
			passed = len(windows) == 0
		case .Frames:
			passed = len(windows) > 0
			for window in windows {
				if window.frame.w <= 20 || window.frame.h <= 20 {
					passed = false; break
				}
				text, e := live_helper(
					l,
					"frame",
					fmt.tprintf("%d", window.id),
				); if e != "" {
					return e
				}
				actual: Live_Rect
				if j := json.unmarshal(transmute([]u8)text, &actual, .JSON);
				   j != nil {
					return "invalid native-frame JSON"
				}
				if math.abs(actual.x - window.frame.x) > 3 ||
				   math.abs(actual.y - window.frame.y) > 3 ||
				   math.abs(actual.w - window.frame.w) > 3 ||
				   math.abs(actual.h - window.frame.h) > 3 {
					passed = false
				}
			}
		}
		if passed {
			return ""
		}; time.sleep(100 * time.Millisecond)
	}
	return fmt.tprintf("timed out waiting for desktop fixture check %v", check)
}
live_desktop :: proc(c: tc.Context) -> string {
	l: Live
	err := live_desktop_run(c, &l)
	return finish_live(&l, err)
}
live_desktop_run :: proc(c: tc.Context, l: ^Live) -> (err: string) {
	prepared, e := prepare_live(c, "shoji-desktop"); if e != "" {
		return e
	}
	l^ = prepared
	if err = desktop_guard(c); err != "" {
		return err
	}
	if _, err = live_command(l, []string{tc.binary(c, "shoji"), "--inspect"});
	   err != "" {
		return err
	}
	if err = build_live_helper(c); err != "" {
		return err
	}
	fixture, e1 := start_child(
		l,
		[]string {
			tc.binary(c, "shoji-harness-fixture"),
			"desktop",
			os.base(l.evidence),
		},
		"fixture",
	); if e1 != "" {
		return e1
	}; defer record_cleanup(l, "fixture", stop_child(&fixture))
	line, e2 := first_line(&fixture); if e2 != "" {
		return e2
	}
	owned: struct {
		pid: int,
		windows: []u32,
	}
	if j := json.unmarshal(transmute([]u8)line, &owned, .JSON); j != nil {
		return "fixture did not identify two owned windows"
	}
	if owned.pid != fixture.process.pid ||
	   len(owned.windows) != 2 ||
	   owned.windows[0] == 0 ||
	   owned.windows[1] == 0 ||
	   owned.windows[0] == owned.windows[1] {
		return "invalid fixture ownership"
	}
	l.report.fixture_pid = owned.pid
	config := s.join(l.evidence, "shojirc")
	if err = s.write(
		config,
		"# Empty fixture configuration; all operations are PID-scoped.\n",
	); err != "" {
		return err
	}
	if err = desktop_guard(c); err != "" {
		return err
	}
	daemon, e3 := start_child(
		l,
		[]string {
			tc.binary(c, "shoji"),
			"-c",
			config,
			"--validation-pid",
			fmt.tprintf("%d", owned.pid),
		},
		"daemon",
	); if e3 != "" {
		return e3
	}; defer record_cleanup(l, "daemon", stop_child(&daemon))
	first, second := owned.windows[0], owned.windows[1]
	first_id, second_id := fmt.tprintf("%d", first), fmt.tprintf("%d", second)
	if err = wait_desktop(l, owned.pid, first, second, .Ready, &daemon);
	   err != "" {
		return err
	}
	configs := [][]string {
		{"config", "window_animation_duration", "0"},
		{"config", "mouse_follows_focus", "off"},
		{"config", "layout", "bsp"},
	}
	for args in configs {
		if _, err = live_client(l, ..args); err != "" {
			return err
		}
	}
	if err = wait_desktop(l, owned.pid, first, second, .Frames, &daemon);
	   err != "" {
		return err
	}
	if _, err = live_client(l, "window", first_id, "--focus"); err != "" {
		return err
	}
	if err = wait_desktop(l, owned.pid, first, second, .Focus, &daemon);
	   err != "" {
		return err
	}
	if _, err = live_client(l, "window", first_id, "--swap", second_id);
	   err != "" {
		return err
	}
	windows, e4 := owned_windows(l, owned.pid); if e4 != "" {
		return e4
	}
	space := u32(0); for window in windows {
		if window.id == first {
			space = window.space
		}
	}
	if space == 0 {
		return "fixture Space was not identified"
	}
	space_id := fmt.tprintf("%d", space)
	operations := [][]string {
		{"space", space_id, "--rotate", "90"},
		{"space", space_id, "--balance"},
		{"window", first_id, "--toggle", "float", "--grid", "4:4:1:1:2:2"},
	}
	for args in operations {
		if _, err = live_client(l, ..args); err != "" {
			return err
		}
	}
	if err = wait_desktop(l, owned.pid, first, second, .Floating, &daemon);
	   err != "" {
		return err
	}
	if err = wait_desktop(l, owned.pid, first, second, .Frames, &daemon);
	   err != "" {
		return err
	}
	if _, err = live_client(l, "window", first_id, "--resize", "right:20:0");
	   err != "" {
		return err
	}
	if _, err = live_client(l, "window", first_id, "--minimize"); err != "" {
		return err
	}
	if err = wait_desktop(l, owned.pid, first, second, .Minimized, &daemon);
	   err != "" {
		return err
	}
	if _, err = live_client(l, "window", first_id, "--deminimize"); err != "" {
		return err
	}
	if err = wait_desktop(l, owned.pid, first, second, .Restored, &daemon);
	   err != "" {
		return err
	}
	finishing := [][]string {
		{"window", first_id, "--toggle", "float"},
		{"config", "layout", "stack"},
		{"config", "layout", "bsp"},
		{"window", second_id, "--close"},
	}
	for args in finishing {
		if _, err = live_client(l, ..args); err != "" {
			return err
		}
	}
	if err = wait_desktop(l, owned.pid, first, second, .Closed, &daemon);
	   err != "" {
		return err
	}
	if cleanup_error := stop_child(&fixture); cleanup_error != "" {
		return s.cat("fixture cleanup: ", cleanup_error)
	}
	if err = wait_desktop(l, owned.pid, first, second, .Empty, &daemon);
	   err != "" {
		return err
	}
	fmt.println(
		"PASS: owned-window tiling, focus, swap, transforms, float/grid, resize, minimize/restore, stack and close",
	)
	return ""
}
live_cli :: proc(c: tc.Context, args: []string) -> string {
	if len(args) == 0 {
		return "live expects desktop|spaces|animation"
	}
	if os.get_euid() == 0 {
		return "run live validation as the logged-in user, not root"
	}
	o, err := s.parse(
		args[1:],
		nil,
		[]string{"load-payload", "reload-payload", "dock-restart"},
	); if err != "" {
		return err
	}; if len(o.positionals) != 0 {
		return "unexpected live-validation argument"
	}
	switch args[0] {
	case "desktop":
		if len(o.flags) != 0 {
			return "desktop does not accept payload/Dock flags"
		}; return live_desktop(c)
	case "spaces":
		if o.flags["reload-payload"] || o.flags["dock-restart"] {
			return "spaces never restarts Dock"
		}; return live_spaces(c, o.flags["load-payload"])
	case "animation":
		if o.flags["load-payload"] {
			return "animation expects --reload-payload"
		}
		return live_animation(
			c,
			o.flags["reload-payload"],
			o.flags["dock-restart"],
		)
	}
	return "unknown live-validation command"
}
