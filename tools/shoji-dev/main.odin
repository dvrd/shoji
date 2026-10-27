package main

import service "../../src/service"
import s "../../src/support"
import "core:fmt"
import "core:mem"
import "core:os"
import d "tooling"

HELP :: `Usage: shoji-dev COMMAND [OPTIONS]
  signing setup|check|sign    Persistent signing and atomic binary installation
  service COMMAND           Native per-user launchd service control
  toolchain                 Prepare/patch pinned Odin [--source PATH] [--patch-only] [--build-compiler]
  build-arm64e SOURCE       Build the isolated loader compiler
  normalize-arm64e BINARY    Normalize a thin arm64e Mach-O ABI
  check-asm                 Compiler regressions [--compiler PATH] [--library-root PATH] [--target TARGET]
  check-bootstrap BINARY…   Verify copied bootstrap relocation independence
  package                   Release archive --version VERSION [--binaries DIR] [--output DIR]
  package --verify ARCHIVE  Verify members, permissions and SHA-256 manifest
  clean [--dry-run]         Remove rebuildable outputs; preserve runtime and artifacts
  validate                  Record automated/desktop evidence [--preflight-only] [--live-animation]
  live desktop              PID-scoped disposable-window checks; refuses an existing daemon
  live spaces               Tracked disposable-Space checks [--load-payload]
  live animation            Owned-window crash recovery [--reload-payload] [--dock-restart]

Live checks mutate only their explicit fixtures. Dock restart requires an explicit flag.
All process arguments are passed literally, without shell evaluation.`
run :: proc() -> int {
	s.configure_signals()
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	args := os.args[1:]
	c := d.Context {
		root = d.project_root(),
	}
	if len(args) == 0 || args[0] == "--help" {
		fmt.println(HELP); return 0
	}
	for arg in args[1:] {
		if arg == "--help" {
			fmt.println(HELP); return 0
		}
	}
	err: string
	switch args[0] {
	case "signing":
		err = d.signing_cli(c, args[1:])
	case "service":
		return service.cli(args[1:], d.binary(c, "shoji"))
	case "toolchain":
		err = d.toolchain_cli(c, args[1:])
	case "build-arm64e":
		err = d.build_arm64e(c, args[1:])
	case "normalize-arm64e":
		if len(args) != 2 {
			err = "normalize-arm64e expects one binary"
		} else {
			err = d.normalize_arm64e(args[1])
		}
	case "check-asm":
		err = d.check_asm(c, args[1:])
	case "check-bootstrap":
		err = d.check_bootstrap(c, args[1:])
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
	case "validate":
		err = d.validation_cli(c, args[1:])
	case "live":
		err = d.live_cli(c, args[1:])
	case:
		err = s.cat("unknown command: ", args[0])
	}
	if err != "" {
		if s.interrupted() { fmt.eprintln("shoji-dev: interrupted; cleanup completed"); return 130 }
		return d.fail(err)
	}; return 0
}
main :: proc() { os.exit(run()) }
