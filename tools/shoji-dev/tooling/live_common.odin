package development

import s "../../../src/support"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import posix "core:sys/posix"
import "core:time"

Recorded_Command :: struct {
	command: []string,
	exit_code: int,
	stdout, stderr: string,
}
Live_Report :: struct {
	status, error: string,
	fixture_pid: int,
	created_space: u64,
	dock_restart, mouse_event_tap: bool,
	binary_sha256: string,
}
Live :: struct {
	c: Context,
	evidence: string,
	commands: [dynamic]Recorded_Command,
	report: Live_Report,
	cleanup_error: string,
}
Child :: struct {
	process: os.Process,
	stdout, stderr: string,
	active: bool,
	group: posix.pid_t,
}
live_command :: proc(l: ^Live, args: []string) -> (string, string) {
	r := s.run(l.c.executor, args, timeout = 30 * time.Second)
	append(
		&l.commands,
		Recorded_Command{s.clone_args(args), r.code, r.out, r.diagnostic},
	); if r.code != 0 {
		return r.out, s.cat(
			"command failed: ",
			args[0],
			": ",
			r.diagnostic,
			r.out,
		)
	}; return s.trim(r.out), ""
}
live_client :: proc(l: ^Live, args: ..string) -> (string, string) {
	cmd := make([dynamic]string); append(&cmd, binary(l.c, "shoji"), "-m")
	append(&cmd, ..args); return live_command(l, cmd[:])
}
live_helper :: proc(l: ^Live, args: ..string) -> (string, string) {
	cmd := make([dynamic]string)
	append(&cmd, binary(l.c, "shoji-live-animation")); append(&cmd, ..args)
	return live_command(l, cmd[:])
}
record_cleanup :: proc(l: ^Live, operation, err: string) {
	l.cleanup_error = with_error(l.cleanup_error, operation, err)
}
// Odin captures return values before defers. Finalize only after the workflow
// returns so evidence and cleanup failures can determine the actual exit status.
finish_live :: proc(l: ^Live, err: string) -> string {
	if l.evidence == "" {
		return err
	}
	final: string
	save_live(l, err, &final)
	return final
}
save_live :: proc(l: ^Live, err: string, final: ^string) {
	final^ = with_error(err, "cleanup", l.cleanup_error)
	final^ = with_error(
		final^,
		"command evidence",
		s.write_json(s.join(l.evidence, "commands.json"), l.commands[:]),
	)
	l.report.status = final^ == "" ? "passed" : "failed"
	l.report.error = final^
	report_error := s.write_json(s.join(l.evidence, "report.json"), l.report)
	final^ = with_error(final^, "report evidence", report_error)
	if report_error != "" {
		l.report.status = "failed"; l.report.error = final^
		fmt.eprintln("Live evidence incomplete:", final^)
	} else {
		fmt.println("Evidence:", l.evidence)
	}
}
prepare_live :: proc(c: Context, prefix: string) -> (Live, string) {
	stage, err := s.temp(prefix); if err != "" {
		return {}, err
	}; l := Live {
		c = c,
		evidence = stage,
		report = {status = "running"},
	}; hash, hash_error := digest(c, binary(c, "shoji"))
	if hash_error != "" {
		err := with_error("", "binary evidence", hash_error)
		save_live(&l, err, &err)
		return l, err
	}
	l.report.binary_sha256 = hash
	return l, ""
}
build_live_helper :: proc(c: Context) -> string {
	if err := s.mkdir(root_file(c, "bin")); err != "" {
		return err
	}
	args := make([dynamic]string)
	append(
		&args,
		compiler(c),
		"build",
		"-warnings-as-errors",
		root_file(c, "tools/live-animation"),
		s.cat("-out:", binary(c, "shoji-live-animation")),
		"-extra-linker-flags:-F/System/Library/PrivateFrameworks",
	)
	when ODIN_ARCH == .arm64 { append(&args, "-target-features:pauth") }
	_, err := run(c, args[:], c.root, "", 120 * time.Second, compiler_env(c))
	return err
}
start_child :: proc(
	l: ^Live,
	args: []string,
	name: string,
) -> (
	Child,
	string,
) {
	if s.cancelled() {
		return {}, "interrupted"
	}
	outpath, errpath :=
		s.join(l.evidence, s.cat(name, ".stdout")),
		s.join(l.evidence, s.cat(name, ".stderr"))
	out, a := os.create(outpath); if a != nil {
		return {}, "cannot create child stdout"
	}; defer os.close(out)
	stderr, b := os.create(errpath); if b != nil {
		return {}, "cannot create child stderr"
	}; defer os.close(stderr)
	child, group, err := s.start(
		{command = args, stdout = out, stderr = stderr},
	)
	if err != nil {
		return {}, fmt.tprintf("cannot start fixture: %v", err)
	}
	return {child, outpath, errpath, true, group}, ""
}
child_alive :: proc(child: ^Child) -> bool {
	if !child.active {
		return false
	}
	_, err := os.process_wait(child.process, 0)
	if err == .Timeout {
		return true
	}
	child.active = false; return false
}
stop_child :: proc(child: ^Child, kill: bool = false) -> string {
	alive := child_alive(child)
	if kill && alive {
		_ = os.process_kill(child.process)
	}
	err := s.stop_tree(child.process, child.group, !alive)
	child.active = false
	child.group = 0
	return err
}
first_line :: proc(child: ^Child) -> (string, string) {
	start := time.tick_now()
	for time.tick_since(start) < 8 * time.Second {
		if s.cancelled() {
			return "", "interrupted"
		}
		text, _ := s.read(child.stdout)
		if at := strings.index(text, "\n"); at >= 0 {
			return s.trim(text[:at]), ""
		}
		if !child_alive(child) {
			diagnostic, _ := s.read(child.stderr)
			return "", s.cat("fixture exited before startup: ", diagnostic)
		}
		time.sleep(50 * time.Millisecond)
	}
	return "", "fixture startup timed out"
}
parse_alpha :: proc(text: string, window: u32) -> (f64, string) {
	value: json.Value
	if err := json.unmarshal(transmute([]u8)text, &value, .JSON); err != nil {
		return 0, s.cat("invalid alpha JSON: ", text)
	}
	obj, ok := value.(json.Object); if !ok {
		return 0, "alpha observation is not an object"
	}
	id, id_ok := obj["window"].(json.Integer)
	if !id_ok || u64(id) != u64(window) {
		return 0, "alpha observation identifies a different window"
	}
	alpha: f64
	#partial switch v in obj["query_alpha"] {case json.Float:
		alpha = f64(v); case json.Integer:
		alpha = f64(v); case:
		return 0, "missing or nonnumeric query_alpha"
	}
	if math.is_nan(alpha) || math.is_inf(alpha) || alpha < 0 || alpha > 1 {
		return 0, "query_alpha must be finite and between zero and one"
	}
	return alpha, ""
}
query_alpha :: proc(l: ^Live, id: u32) -> (f64, string) {
	text, err := live_helper(l, "query", fmt.tprintf("%d", id)); if err != "" {
		return 0, err
	}; return parse_alpha(text, id)
}
Space :: struct {
	id: u64,
	visible: bool `json:"is-visible"`,
	focus: bool `json:"has-focus"`,
	fullscreen: bool `json:"is-native-fullscreen"`,
}
Space_Snapshot :: struct {
	spaces: []Space,
}
space_snapshot :: proc(l: ^Live) -> (Space_Snapshot, string) {
	text, err := live_helper(l, "spaces"); if err != "" {
		return {}, err
	}; snapshot: Space_Snapshot
	if e := json.unmarshal(transmute([]u8)text, &snapshot, .JSON); e != nil {
		return {}, "invalid Space snapshot"
	}; return snapshot, ""
}
space_ids :: proc(snapshot: Space_Snapshot) -> []u64 {
	ids := make([dynamic]u64)
	for space in snapshot.spaces { append(&ids, space.id) }; return ids[:]
}
contains_space :: proc(ids: []u64, id: u64) -> bool {
	for v in ids {
		if v == id {
			return true
		}
	}; return false
}
space_cleanup_allowed :: proc(
	created, original: u64,
	protected, current: []u64,
) -> (
	bool,
	string,
) {
	if created == 0 ||
	   created == original ||
	   contains_space(protected, created) {
		return false, "refusing to destroy a pre-existing Space"
	}
	if !contains_space(current, created) {
		return false, ""
	}
	if !contains_space(current, original) {
		return false, "original Space disappeared; refusing automatic cleanup"
	}
	return true, ""
}
restore_space :: proc(
	l: ^Live,
	created, original: u64,
	protected: []u64,
) -> string {
	state, err := space_snapshot(l); if err != "" {
		return err
	}
	should, guard := space_cleanup_allowed(
		created,
		original,
		protected,
		space_ids(state),
	); if guard != "" {
		return guard
	}; if !should {
		return ""
	}
	if _, err = live_helper(l, "space-focus", fmt.tprintf("%d", original));
	   err != "" {
		return err
	}
	_, err = live_helper(l, "space-destroy", fmt.tprintf("%d", created))
	return err
}
wait_space :: proc(l: ^Live, id: u64, present, visible: bool) -> string {
	start := time.tick_now()
	for time.tick_since(start) < 8 * time.Second {
		state, err := space_snapshot(l); if err != "" {
			return err
		}
		found := false; shown := false
		for space in state.spaces {
			if space.id == id {
				found = true; shown = space.visible
			}
		}
		if found == present && (!visible || shown) {
			return ""
		}
		time.sleep(100 * time.Millisecond)
	}
	return "timed out waiting for disposable Space state"
}
parse_id :: proc(text: string) -> (u64, string) {
	id, ok := strconv.parse_u64(s.trim(text)); if !ok || id == 0 {
		return 0, "fixture did not return a positive owned ID"
	}; return id, ""
}
