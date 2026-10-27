package main

import s "../../../../src/support"
import "core:fmt"
import "core:os"

main :: proc() {
	s.configure_signals()
	fmt.println("ready")
	result := s.run({}, []string{"/bin/sleep", "30"})
	if !s.interrupted() || result.code != 130 { os.exit(1) }
	s.begin_cleanup()
	cleanup := s.run({}, []string{"/usr/bin/true"})
	s.end_cleanup()
	if cleanup.code != 0 { os.exit(2) }
	fmt.println("cleanup completed")
	os.exit(130)
}
