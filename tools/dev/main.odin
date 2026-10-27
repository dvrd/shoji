package main

import s "../../src/support"
import tc "../common"
import "core:fmt"
import "core:mem"
import "core:os"
import d "dev"

HELP :: `Usage: dev COMMAND [OPTIONS]
  signing setup|check|sign   Persistent identity and verified installation
  toolchain                 Prepare or patch the pinned Odin toolchain
  build-arm64e SOURCE       Build the isolated arm64e compiler
  package --version VERSION [--binaries DIR] [--output DIR]
  clean [--dry-run]         Remove known rebuildable outputs`
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
	case "signing":
		err = d.signing_cli(c, args[1:])
	case "toolchain":
		err = d.toolchain_cli(c, args[1:])
	case "build-arm64e":
		err = d.build_arm64e(c, args[1:])
	case "package":
		err = d.package_cli(c, args[1:])
	case "clean":
		o, e := s.parse(args[1:], nil, []string{"dry-run"}); err = e
		if err == "" {
			if len(o.positionals) != 0 {
				err = "unexpected cleanup argument"
			} else {
				err = d.clean(c, o.flags["dry-run"])
			}
		}
	case:
		err = s.cat("unknown command: ", args[0])
	}
	if err != "" {
		fmt.eprintln("dev:", err)
		return s.interrupted() ? 130 : 1
	}
	return 0
}
main :: proc() { os.exit(run()) }
