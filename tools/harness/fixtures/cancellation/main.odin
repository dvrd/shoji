package main

import s "../../../../src"
import "core:fmt"
import "core:os"
import posix "core:sys/posix"
import "core:time"

main :: proc() {
	s.configure_signals()
	if len(os.args) == 3 &&
	   (os.args[1] == "worker" || os.args[1] == "worker-stubborn") {
		script := `sleep 30 & kid=$!; trap 'kill "$kid" 2>/dev/null; wait "$kid"; exit 143' TERM; echo "$kid" > "$1"; wait`
		if os.args[1] == "worker-stubborn" {
			script = `trap '' TERM; sleep 30 & echo "$!" > "$1"; wait`
		}
		r := s.process_run(
			{},
			[]string{"/bin/sh", "-c", script, "owned-fixture", os.args[2]},
		)
		os.exit(r.code)
	}
	// Model an interactive root CLI even when this test runs under native validation.
	// The worker branch above preserves the marker and exercises nested ownership.
	_ = posix.unsetenv(s.COMMAND_GROUP_ENV)
	fmt.println("ready")
	args := []string{"/bin/sleep", "30"}
	timeout := 30 * time.Second
	if len(os.args) == 3 {
		args = []string{os.args[0], "worker", os.args[2]}
		if os.args[1] == "stubborn" {
			args[1] = "worker-stubborn"
		}
		if os.args[1] != "interrupt" {
			timeout = time.Second
		}
	}
	result := s.process_run({}, args, timeout = timeout)
	if len(os.args) == 3 && os.args[1] != "interrupt" {
		if !result.timed_out {
			os.exit(3)
		}
	} else if !s.interrupted() || result.code != 130 {
		os.exit(1)
	}
	s.begin_cleanup()
	cleanup := s.process_run({}, []string{"/usr/bin/true"})
	s.end_cleanup()
	if cleanup.code != 0 {
		os.exit(2)
	}
	fmt.println("cleanup completed")
	os.exit(130)
}
