package main

import loader "addition/loader"
import "core:fmt"
import "core:os"
import mac "macos"

main :: proc() {
	args := os.args[1:]
	if len(args) > 0 {
		switch args[0] {
		case "--load-sa":
			if len(args) !=
			   2 {fmt.eprintln("--load-sa requires the payload dylib path");os.exit(1)}
			if err := loader.inject(args[1]); err != "" {fmt.eprintln(err);os.exit(1)}
			fmt.println(
				"Dock loaded the payload. Run --check-sa as your desktop user to inspect capabilities.",
			)
			return
		case "--check-sa":
			caps, err := mac.addition_check();if err != "" {fmt.eprintln(err);os.exit(1)}
			fmt.printf("Dock scripting addition: %v\n", caps);return
		case "--version", "-v":
			fmt.println("shoji 0.1.0-dev (Odin port of yabai dd84572)")
			return
		case "--help", "-h":
			fmt.println(
				`Usage: shoji [-c CONFIG]
       shoji -m DOMAIN [ARGUMENTS...]
       shoji --load-sa PATH_TO_DYLIB
       shoji --check-sa
       shoji --inspect
       shoji --version

Run without arguments to start the window manager.
-c, --config FILE   Execute FILE through /bin/sh after the socket starts.
-m, --message      Send a command to the running shoji daemon.
--inspect          Print a read-only macOS window/display/space snapshot.

Domains: config, query, window, space, display, rule, signal.
Default layout is float. Use: shoji -m config layout bsp`,
			)
			return
		case "-m", "--message":
			os.exit(mac.client(args[1:]))
		case "--inspect":
			if len(args) != 1 {
				fmt.eprintln("--inspect takes no arguments")
				os.exit(1)
			}
			os.exit(mac.inspect())
		case "-c", "--config":
			if len(args) != 2 {
				fmt.eprintln("--config requires a file")
				os.exit(1)
			}
			os.exit(mac.run(args[1]))
		case:
			fmt.eprintf("shoji: unknown option '%s'\n", args[0])
			os.exit(1)
		}
	}
	os.exit(mac.run(""))
}
