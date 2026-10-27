package tests

import tc "../../common"
import s "../../../src/support"
import "core:fmt"
import "core:strings"

Tool_Recorder :: struct {
	calls: [dynamic]s.Request,
	loaded, fail_verify, policy_fail, dock_stuck, shoji_running: bool,
	identity: string,
	dock_queries: int,
}
tool_execute :: proc(user: rawptr, request: s.Request) -> s.Result {
	r := (^Tool_Recorder)(user); a := request.args; snapshot := request
	snapshot.args = make([]string, len(a)); copy(snapshot.args, a)
	append(&r.calls, snapshot)
	switch a[0] {
	case "/bin/launchctl":
		if a[1] == "print" {
			if strings.contains(a[2], "com.apple.Dock.agent") {
				return {0, "", "", false}
			}; return {r.loaded ? 0 : 1, "", "", false}
		}
		if a[1] == "bootstrap" {
			r.loaded = true
		}; if a[1] == "bootout" {
			r.loaded = false
		}; return {}
	case "/usr/bin/security":
		return {0, r.identity, "", false}
	case "/usr/bin/codesign":
		return {
			r.fail_verify && a[1] == "--verify" ? 1 : 0,
			"",
			"signature rejected",
			false,
		}
	case "sudo":
		return {r.policy_fail ? 1 : 0, "", "sudo policy denied", false}
	case "/bin/ps":
		r.dock_queries += 1
		pid := r.dock_queries == 1 || r.dock_stuck ? 10 : 11
		return {
			0,
			fmt.tprintf(
				"%d 501 /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock\n20 502 /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock\n",
				pid,
			),
			"",
			false,
		}
	}
	if strings.has_suffix(a[0], "shoji-harness-fixture") {
		if a[1] == "spaces" {
			return {
				0,
				`{"spaces":[{"id":1},{"id":2},{"id":3},{"id":4}]}`,
				"",
				false,
			}
		}
		return {0, "ok", "", false}
	}
	if strings.has_suffix(a[0], "shoji") &&
	   (r.shoji_running || a[1] == "--check-sa") {
		return {0, "[]", "", false}
	}
	return s.run(
		{},
		a,
		request.dir,
		request.input,
		request.timeout,
		request.env,
	)
}
tool_context :: proc(root: string, r: ^Tool_Recorder) -> tc.Context {
	return{root = root, executor = {r, tool_execute}}
}
