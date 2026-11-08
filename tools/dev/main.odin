package main

import tc "../common"
import "core:os"
import d "dev"
import support "../../src/support"

HELP :: `Usage: dev COMMAND [OPTIONS]
  signing setup|check|sign   Persistent identity and verified installation
  toolchain                 Keep the pinned compiler, core, and base
  build-arm64e [SOURCE]     Fetch, patch, and build the arm64e compiler
  package --version VERSION [--binaries DIR] [--output DIR]
  clean [--dry-run]         Remove known rebuildable outputs`
dispatch :: proc(c: tc.Context, args: []string) -> string {
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
		o, e := support.parse(args[1:], nil, []string{"dry-run"}); err = e
		if err == "" {
			if len(o.positionals) != 0 {
				err = "unexpected cleanup argument"
			} else {
				err = d.clean(c, o.flags["dry-run"])
			}
		}
	case:
		err = support.cat("unknown command: ", args[0])
	}
	return err
}
main :: proc() { os.exit(tc.cli_main("dev", HELP, dispatch)) }
