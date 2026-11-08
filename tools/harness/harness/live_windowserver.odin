package harness

import tc "../../common"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import support "../../../src/support"

// Live WindowServer gate acceptance (C1 swap, C2 focus, C4 Space move).
// --------------------------------------------------------------------------
// Runs the production path: an isolated daemon (the Shoji.app binary, which
// holds Accessibility approval and the sudoers rule) with `windowserver_gate
// on`, which attaches itself through `sudo -n shoji --ws-attach`. Every check
// compares the daemon's Accessibility frame with WindowServer's own bounds
// (the fixture's SLSGetWindowBounds), so a layout that landed in one place
// only is reported as DESYNC. The ring is exported through the daemon at the
// end. Requires the payload installed and resident for this macOS build.

WS_ATTACH_WAIT :: 20 * time.Second
WS_SETTLE :: 1200 * time.Millisecond
// WindowServer bounds and the AX frame are both integral points; one point
// covers rounding of fractional layouts.
WS_SYNC_TOLERANCE :: 1.0

Ws_Check :: struct {
	name:    string,
	window:  u32,
	verdict: string,
	ax:      Live_Rect,
	ws:      Live_Rect,
}
Ws_Live :: struct {
	l:      ^Live,
	daemon: ^Child,
	pid:    int,
	checks: [dynamic]Ws_Check,
}

live_windowserver :: proc(c: tc.Context, move_space: bool, prebuilt: bool = false) -> string {
	l: Live
	err := live_windowserver_run(c, &l, move_space, prebuilt)
	return finish_live(&l, err)
}

live_windowserver_run :: proc(
	c: tc.Context,
	l: ^Live,
	move_space: bool,
	prebuilt: bool,
) -> (
	err: string,
) {
	prepared, e := prepare_live(c, "shoji-windowserver"); if e != "" {return e}
	l^ = prepared
	app := tc.root_file(c, "bin/Shoji.app/Contents/MacOS/shoji")
	if !support.regular(app) {return "bin/Shoji.app is missing; run task build:app"}
	if err = desktop_guard(c); err != "" {return err}
	if _, err = live_command(l, []string{app, "--ws-report"}); err != "" {
		return support.cat("WindowServer payload is not ready: ", err)
	}
	if err = build_live_helper(c, prebuilt); err != "" {return err}
	fixture, pid, first, second, e1 := ws_start_fixture(l)
	if e1 != "" {return e1}
	defer record_cleanup(l, "fixture", stop_child(&fixture))
	config := support.join(l.evidence, "shojirc")
	if err = support.write(config, "# Empty fixture configuration.\n"); err != "" {return err}
	if err = desktop_guard(c); err != "" {return err}
	daemon, e2 := start_child(
		l,
		[]string{app, "-c", config, "--validation-pid", fmt.tprintf("%d", pid)},
		"daemon",
	); if e2 != "" {return e2}
	defer record_cleanup(l, "daemon", stop_child(&daemon))
	ws := Ws_Live{l = l, daemon = &daemon, pid = pid}
	defer {
		record_cleanup(l, "check evidence", support.write_json(
			support.join(l.evidence, "ws-checks.json"), ws.checks[:]))
	}
	if err = wait_desktop(l, pid, first, second, .Ready, &daemon); err != "" {return err}
	if err = ws_attach(&ws); err != "" {return err}
	if err = ws_checks(&ws, first, second, move_space); err != "" {return err}
	if _, err = live_command(l, []string{app, "--ws-report", support.join(l.evidence, "ring")});
	   err != "" {return err}
	fmt.println("PASS: gate attached; C1 swap, C2 focus",
		move_space ? "and C4 Space move" : "(C4 skipped; pass --move-space)",
		"agree with WindowServer")
	return ""
}

ws_start_fixture :: proc(l: ^Live) -> (fixture: Child, pid: int, first, second: u32, err: string) {
	fixture, err = start_child(
		l,
		[]string{tc.binary(l.c, "harness-fixture"), "desktop", os.base(l.evidence)},
		"fixture",
	); if err != "" {return}
	line: string
	if line, err = first_line(&fixture); err != "" {
		record_cleanup(l, "fixture", stop_child(&fixture)); return
	}
	owned: struct {
		pid:     int,
		windows: []u32,
	}
	if json.unmarshal(transmute([]u8)line, &owned, .JSON) != nil ||
	   owned.pid != fixture.process.pid || len(owned.windows) != 2 ||
	   owned.windows[0] == 0 || owned.windows[0] == owned.windows[1] {
		record_cleanup(l, "fixture", stop_child(&fixture))
		err = "fixture did not identify two owned windows"; return
	}
	l.report.fixture_pid = owned.pid
	return fixture, owned.pid, owned.windows[0], owned.windows[1], ""
}

// Turns the gate on and waits for the daemon's own attach to serve.
ws_attach :: proc(ws: ^Ws_Live) -> string {
	settings := [][]string {
		{"config", "window_animation_duration", "0"},
		{"config", "mouse_follows_focus", "off"},
		{"config", "layout", "bsp"},
		{"config", "windowserver_gate", "on"},
	}
	for args in settings {
		if _, err := live_client(ws.l, ..args); err != "" {return err}
	}
	start := time.tick_now()
	for time.tick_since(start) < WS_ATTACH_WAIT {
		if !child_alive(ws.daemon) {return "validation daemon exited; see daemon.stderr"}
		status, _ := live_client(ws.l, "debug", "ws", "status")
		if strings.contains(status, "adapter serving") {return ""}
		time.sleep(250 * time.Millisecond)
	}
	return "gate never served; check the --ws-attach sudoers rule and daemon.stderr"
}

ws_checks :: proc(ws: ^Ws_Live, first, second: u32, move_space: bool) -> string {
	a, b := fmt.tprintf("%d", first), fmt.tprintf("%d", second)
	if _, err := live_client(ws.l, "window", a, "--swap", b); err != "" {return err}
	if err := ws_sync(ws, "c1-swap", first); err != "" {return err}
	if err := ws_sync(ws, "c1-swap", second); err != "" {return err}
	for id in ([]u32{first, second}) {
		if _, err := live_client(ws.l, "window", fmt.tprintf("%d", id), "--focus"); err != "" {
			return err
		}
		if err := wait_desktop(ws.l, ws.pid, id, id, .Focus, ws.daemon); err != "" {
			append(&ws.checks, Ws_Check{name = "c2-focus", window = id, verdict = "NOFOCUS"})
			return err
		}
		append(&ws.checks, Ws_Check{name = "c2-focus", window = id, verdict = "FOCUS"})
	}
	return move_space ? ws_move_space(ws, first) : ""
}

// Moves the window to a disposable Space and back, checking sync both ways.
ws_move_space :: proc(ws: ^Ws_Live, window: u32) -> (err: string) {
	l := ws.l
	if _, err = live_command(l, []string{tc.binary(l.c, "shoji"), "--check-sa"}); err != "" {
		return support.cat("C4 needs the Dock payload: ", err)
	}
	before, e := space_snapshot(l); if e != "" {return e}
	protected := space_ids(before)
	original: u64
	for space in before.spaces {if space.focus {original = space.id}}
	if original == 0 {return "cannot identify the focused Space"}
	text, e1 := live_helper(l, "space-create-tracked", fmt.tprintf("%d", original))
	if e1 != "" {return e1}
	created, e2 := parse_id(text); if e2 != "" {return e2}
	if contains_space(protected, created) {return "payload returned a pre-existing Space"}
	l.report.created_space = created
	defer if created != 0 {
		record_cleanup(l, "disposable Space", restore_space(l, created, original, protected))
	}
	if err = wait_space(l, created, true, false); err != "" {return err}
	id := fmt.tprintf("%d", window)
	for target in ([]u64{created, original}) {
		index, e3 := ws_space_index(ws, target); if e3 != "" {return e3}
		if _, err = live_client(l, "window", id, "--space", index); err != "" {return err}
		if err = ws_sync(ws, target == created ? "c4-away" : "c4-back", window); err != "" {
			return err
		}
	}
	if err = restore_space(l, created, original, protected); err != "" {return err}
	created = 0
	return ""
}

// Mission Control index of a Space, as `window --space` expects it.
ws_space_index :: proc(ws: ^Ws_Live, id: u64) -> (string, string) {
	start := time.tick_now()
	for time.tick_since(start) < 8 * time.Second {
		text, err := live_client(ws.l, "query", "--spaces"); if err != "" {return "", err}
		spaces: []struct {
			id, index: u64,
		}
		if json.unmarshal(transmute([]u8)text, &spaces, .JSON) != nil {
			return "", "invalid Space query JSON"
		}
		for space in spaces {if space.id == id {return fmt.tprintf("%d", space.index), ""}}
		time.sleep(100 * time.Millisecond)
	}
	return "", fmt.tprintf("daemon never listed Space %d", id)
}

// Compares the daemon's AX frame with WindowServer's bounds after settling.
ws_sync :: proc(ws: ^Ws_Live, name: string, window: u32) -> string {
	time.sleep(WS_SETTLE)
	windows, err := owned_windows(ws.l, ws.pid); if err != "" {return err}
	check := Ws_Check{name = name, window = window, verdict = "DESYNC"}
	found := false
	for w in windows {if w.id == window {check.ax = w.frame; found = true}}
	if !found {return fmt.tprintf("%s: daemon lost window %d", name, window)}
	text, e := live_helper(ws.l, "frame", fmt.tprintf("%d", window)); if e != "" {return e}
	if json.unmarshal(transmute([]u8)text, &check.ws, .JSON) != nil {
		return "invalid native-frame JSON"
	}
	if math.abs(check.ax.x - check.ws.x) <= WS_SYNC_TOLERANCE &&
	   math.abs(check.ax.y - check.ws.y) <= WS_SYNC_TOLERANCE &&
	   math.abs(check.ax.w - check.ws.w) <= WS_SYNC_TOLERANCE &&
	   math.abs(check.ax.h - check.ws.h) <= WS_SYNC_TOLERANCE {
		check.verdict = "SYNC"
	}
	append(&ws.checks, check)
	fmt.printf("%s %s window=%d ax=%v ws=%v\n", check.verdict, name, window, check.ax, check.ws)
	if check.verdict != "SYNC" {return fmt.tprintf("%s: window %d DESYNC", name, window)}
	return ""
}
