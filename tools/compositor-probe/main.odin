package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

host_supported :: proc() -> bool {
	state, out, errout, err := os.process_exec(
		{command = []string{"/usr/bin/sw_vers", "-buildVersion"}},
		context.allocator,
	)
	defer delete(out); defer delete(errout)
	return(
		err == nil &&
		state.success &&
		strings.trim_space(string(out)) == "24G84" \
	)
}

main :: proc() {
	posix.signal(.SIGPIPE, (proc "c" (signal: posix.Signal))(posix.SIG_IGN))
	status := 64
	if len(os.args) >= 2 &&
	   (os.args[1] == "--run" || os.args[1] == "--fixture") &&
	   !host_supported() {
		fmt.eprintln(
			"This diagnostic is pinned to macOS 15.6 / 24G84; inspect the ABI before porting.",
		)
		os.exit(3)
	}
	if len(os.args) == 2 && os.args[1] == "--run" {
		status = run()
	} else if len(os.args) == 3 && os.args[1] == "--fixture" {
		parent, ok := strconv.parse_int(os.args[2])
		if ok && parent == os.get_ppid() {
			status = fixture(parent)
		}
	} else {
		fmt.eprintln(
			"Usage: shoji-compositor-probe --run\nCreates disposable windows for a ~25-second clipping experiment. No injection, Space operations, or user-window IDs are accepted.",
		)
	}
	os.exit(status)
}
