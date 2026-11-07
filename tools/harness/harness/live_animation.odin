package harness

import s "../../../src"
import tc "../../common"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

user_dock :: proc(c: tc.Context, uid: int) -> (int, string) {
	text, err := tc.run(c, []string{"/bin/ps", "-axo", "pid,uid,comm"})
	if err != "" {
		return 0, err
	}
	found, count := 0, 0
	for line in strings.split_lines(text) {
		f := strings.fields(line); if len(f) < 3 {
			continue
		}; user, ok := strconv.parse_int(f[1]); if !ok || user != uid {
			continue
		}
		if strings.join(f[2:], " ") !=
		   "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock" {
			continue
		}; pid, pid_ok := strconv.parse_int(f[0]); if pid_ok && pid > 0 {
			found = pid; count += 1
		}
	}
	if count != 1 {
		return 0, "cannot identify the current user's unique Dock process"
	}; return found, ""
}
restart_dock :: proc(
	c: tc.Context,
	uid: int,
	timeout: time.Duration = 15 * time.Second,
) -> (
	err: string,
) {
	// --load-sa takes no path; shoji loads the payload beside itself.
	exe := tc.binary(c, "shoji")
	if _, err = tc.run(c, []string{"sudo", "-n", "-l", "--", exe, "--load-sa"});
	   err != "" {
		return err
	}
	target := fmt.tprintf("gui/%d/com.apple.Dock.agent", uid)
	if _, err = tc.run(c, []string{"/bin/launchctl", "print", target});
	   err != "" {
		return err
	}
	before, e := user_dock(c, uid); if e != "" {
		return e
	}
	replaced := false
	defer {
		s.begin_cleanup()
		defer s.end_cleanup()
		if !replaced {
			_ = s.process_run(
				c.executor,
				[]string{"/bin/launchctl", "kickstart", target},
				timeout = 15 * time.Second,
			)
		}
	}
	if _, err = tc.run(
		c,
		[]string{"/bin/launchctl", "kickstart", "-k", target},
	); err != "" {
		return err
	}
	began := time.tick_now()
	for time.tick_since(began) < timeout {
		if s.cancelled() {
			return "interrupted"
		}
		current, current_error := user_dock(c, uid)
		if current_error == "" && current != before {
			replaced = true; break
		}
		time.sleep(100 * time.Millisecond)
	}
	if !replaced {
		return(
			"Dock restart was not observed; recovery was requested without loading the payload" \
		)
	}
	if _, err = tc.run(c, []string{"sudo", "-n", exe, "--load-sa"});
	   err != "" {
		return err
	}
	_, err = tc.run(c, []string{exe, "--check-sa"}); return err
}
start_animation_fixture :: proc(
	l: ^Live,
	args: []string,
	name: string,
) -> (
	Child,
	u32,
	string,
) {
	cmd := make([dynamic]string)
	append(&cmd, tc.binary(l.c, "harness-fixture")); append(&cmd, ..args)
	child, err := start_child(l, cmd[:], name); if err != "" {
		return {}, 0, err
	}
	line, e := first_line(&child); if e != "" {
		return {}, 0, tc.with_error(e, "fixture cleanup", stop_child(&child))
	}
	id, id_error := parse_id(line); if id_error != "" || id > 0xffffffff {
		cleanup_error := stop_child(&child)
		diagnostic, _ := s.read(child.stderr)
		reason := s.cat(
			"fixture could not create an owned window: ",
			diagnostic,
			line,
		)
		return {}, 0, tc.with_error(reason, "fixture cleanup", cleanup_error)
	}
	return child, u32(id), ""
}
replay_journal :: proc(l: ^Live, journal: string, window: u32) -> string {
	if _, err := live_helper(l, "recover", journal); err != "" {
		return err
	}
	alpha, e := query_alpha(l, window); if e != "" {
		return e
	}; if alpha < .99 {
		return "journal did not restore owned-window opacity"
	}
	text, err := s.read(journal); if err != "" {
		return err
	}
	value: json.Value
	if j := json.unmarshal(transmute([]u8)text, &value, .JSON); j != nil {
		return "invalid recovery journal"
	}
	object, ok := value.(json.Object); if !ok {
		return "journal is not an object"
	}
	entries, valid := object["entries"].(json.Array)
	if !valid || len(entries) != 0 {
		return "journal restoration did not clear entries"
	}
	return ""
}
live_animation :: proc(
	c: tc.Context,
	reload_payload, dock_restart: bool,
	prebuilt: bool = false,
) -> string {
	l: Live
	err := live_animation_run(c, reload_payload, dock_restart, &l, prebuilt)
	return finish_live(&l, err)
}
live_animation_run :: proc(
	c: tc.Context,
	reload_payload, dock_restart: bool,
	l: ^Live,
	prebuilt: bool = false,
) -> (
	err: string,
) {
	if reload_payload {
		if err = restart_dock(c, os.get_uid()); err != "" {
			return err
		}
	}
	if _, err = tc.run(c, []string{tc.binary(c, "shoji"), "--check-sa"});
	   err != "" {
		return err
	}
	if err = build_live_helper(c, prebuilt); err != "" {
		return err
	}
	prepared, e := prepare_live(c, "shoji-live-crash"); if e != "" {
		return e
	}
	l^ = prepared
	l.report.dock_restart = dock_restart || reload_payload

	real, window, e1 := start_animation_fixture(l, []string{"real"}, "real")
	if e1 != "" {
		return e1
	}; defer record_cleanup(l, "real window", stop_child(&real))
	l.report.fixture_pid = real.process.pid
	baseline, e2 := query_alpha(l, window); if e2 != "" {
		return e2
	}; if baseline < .99 {
		return "owned-window baseline opacity is not one"
	}
	journal := s.join(l.evidence, "watchdog.json")
	proxy, _, e3 := start_animation_fixture(
		l,
		[]string{"proxy", fmt.tprintf("%d", window), journal},
		"watchdog-proxy",
	); if e3 != "" {
		return e3
	}; defer record_cleanup(l, "proxy", stop_child(&proxy))
	hidden, e4 := query_alpha(l, window); if e4 != "" {
		return e4
	}; if hidden > .01 {
		return "fixture did not hide its owned real window"
	}
	if cleanup_error := stop_child(&proxy, true); cleanup_error != "" {
		return s.cat("proxy cleanup: ", cleanup_error)
	}
	start := time.tick_now(); restored := false
	for time.tick_since(start) < 5 * time.Second {
		alpha, alpha_error := query_alpha(l, window); if alpha_error != "" {
			return alpha_error
		}; if alpha >= .99 {
			restored = true; break
		}; time.sleep(50 * time.Millisecond)
	}
	if !restored {
		return "payload watchdog did not restore the owned real window"
	}
	if err = replay_journal(l, journal, window); err != "" {
		return err
	}
	fmt.println("PASS: owned-window SIGKILL watchdog restoration")
	journal = s.join(l.evidence, "replay.json")
	second, _, e5 := start_animation_fixture(
		l,
		[]string{"proxy", fmt.tprintf("%d", window), journal},
		"replay-proxy",
	); if e5 != "" {
		return e5
	}; defer record_cleanup(l, "replay", stop_child(&second))
	second_alpha, e6 := query_alpha(l, window); if e6 != "" {
		return e6
	}; if second_alpha > .01 {
		return "second fixture did not prove its hide"
	}
	if err = replay_journal(l, journal, window); err != "" {
		return err
	}
	if cleanup_error := stop_child(&second); cleanup_error != "" {
		return s.cat("replay cleanup: ", cleanup_error)
	}
	fmt.println("PASS: fresh-process journal replay")
	if dock_restart {
		journal = s.join(l.evidence, "dock.json")
		third, _, e7 := start_animation_fixture(
			l,
			[]string{"proxy", fmt.tprintf("%d", window), journal},
			"dock-proxy",
		); if e7 != "" {
			return e7
		}; defer record_cleanup(l, "restart fixture", stop_child(&third))
		third_alpha, e8 := query_alpha(l, window); if e8 != "" {
			return e8
		}; if third_alpha > .01 {
			return "Dock-restart fixture did not prove its hide"
		}
		if err = restart_dock(c, os.get_uid()); err != "" {
			return err
		}
		if err = replay_journal(l, journal, window); err != "" {
			return err
		}
		fmt.println("PASS: journal recovery after explicit Dock restart")
	}
	return ""
}
