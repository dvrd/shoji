package main

import tc "../common"
import "core:os"
import d "harness"
import support "../../src/support"

HELP :: `Usage: harness COMMAND [OPTIONS]
  check-asm                 Compiler diagnostic regression fixtures
  validate [--preflight-only] [--live-animation] [--dock-restart]
  live desktop [--prebuilt-fixture]   Owned-window validation; refuses an existing daemon
  live spaces [--load-payload] [--prebuilt-fixture]
  live animation [--reload-payload] [--dock-restart] [--prebuilt-fixture]
  live windowserver [--move-space] [--prebuilt-fixture]   WindowServer gate acceptance

Dock restart and live desktop mutations require explicit live options.`
dispatch :: proc(c: tc.Context, args: []string) -> string {
	err: string
	switch args[0] {
	case "check-asm":
		err = d.check_asm(c, args[1:])
	case "validate":
		err = d.validation_cli(c, args[1:])
	case "live":
		err = d.live_cli(c, args[1:])
	case:
		err = support.cat("unknown command: ", args[0])
	}
	return err
}
main :: proc() { os.exit(tc.cli_main("harness", HELP, dispatch)) }
