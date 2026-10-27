package main

import s "../../src/support"
import tc "../common"
import "core:fmt"
import "core:mem"
import "core:os"
import d "inspect"

HELP :: `Usage: inspector COMMAND [OPTIONS]
  normalize-arm64e BINARY   Validate and normalize arm64e ABI metadata
  check-bootstrap BINARY…  Inspect copied bootstrap relocation independence
  check-archive ARCHIVE     Validate release members and SHA-256 checksums`
run :: proc() -> int {
	s.configure_signals()
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	args := os.args[1:]
	if len(args) == 0 {
		fmt.println(HELP); return 0
	}
	for arg in args {
		if arg == "--help" {
			fmt.println(HELP); return 0
		}
	}
	c := tc.Context {
		root = tc.project_root(),
	}
	err: string
	switch args[0] {
	case "normalize-arm64e":
		if len(args) != 2 {
			err = "normalize-arm64e expects one binary"
		} else {
			err = d.normalize_arm64e(args[1])
		}
	case "check-bootstrap":
		err = d.check_bootstrap(c, args[1:])
	case "check-archive":
		if len(args) != 2 {
			err = "check-archive expects one archive"
		} else {
			err = d.verify_archive(c, args[1])
		}
	case:
		err = s.cat("unknown command: ", args[0])
	}
	if err != "" {
		fmt.eprintln("inspector:", err)
		return s.interrupted() ? 130 : 1
	}
	return 0
}
main :: proc() { os.exit(run()) }
