package main

import s "../../src/support"
import tc "../common"
import "core:fmt"
import "core:mem"
import "core:os"
import d "harness"

HELP :: `Usage: harness COMMAND [OPTIONS]
  check-asm                 Compiler diagnostic regression fixtures
  validate [--preflight-only] [--live-animation] [--dock-restart]
  live desktop              Owned-window validation; refuses an existing daemon
  live spaces [--load-payload]
  live animation [--reload-payload] [--dock-restart]

Dock restart and live desktop mutations require explicit live options.`
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
	case "check-asm":
		err = d.check_asm(c, args[1:])
	case "validate":
		err = d.validation_cli(c, args[1:])
	case "live":
		err = d.live_cli(c, args[1:])
	case:
		err = s.cat("unknown command: ", args[0])
	}
	if err != "" {
		fmt.eprintln("harness:", err)
		return s.interrupted() ? 130 : 1
	}
	return 0
}
main :: proc() { os.exit(run()) }
