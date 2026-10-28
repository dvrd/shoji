package main

import s "../../src/support"
import tc "../common"
import "core:os"
import d "inspect"

HELP :: `Usage: inspector COMMAND [OPTIONS]
  normalize-arm64e BINARY   Validate and normalize arm64e ABI metadata
  check-bootstrap BINARY…  Inspect copied bootstrap relocation independence
  check-archive ARCHIVE     Validate release members and SHA-256 checksums`
dispatch :: proc(c: tc.Context, args: []string) -> string {
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
	return err
}
main :: proc() { os.exit(tc.cli_main("inspector", HELP, dispatch)) }
