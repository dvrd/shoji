package main

import s "../../src/support"
import tc "../common"
import "core:os"
import d "harness"

HELP :: `Usage: harness COMMAND [OPTIONS]
  check-asm                 Compiler diagnostic regression fixtures
  validate [--preflight-only] [--live-animation] [--dock-restart]
  live desktop              Owned-window validation; refuses an existing daemon
  live spaces [--load-payload]
  live animation [--reload-payload] [--dock-restart]

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
		err = s.cat("unknown command: ", args[0])
	}
	return err
}
main :: proc() { os.exit(tc.cli_main("harness", HELP, dispatch)) }
