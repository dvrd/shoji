package main

import loader "addition/loader"
import "core:fmt"
import "core:os"
import "core:strconv"
import mac "macos"

HELP_MESSAGE :: `
Usage: shoji [-c CONFIG] [--sa PATH_TO_DYLIB]
       shoji -m DOMAIN [ARGUMENTS...]
       shoji --load-sa PATH_TO_DYLIB
       shoji --check-sa
       shoji --inspect
       shoji --version

Run without arguments to start the window manager.
-c, --config FILE   Execute FILE through /bin/sh after the socket starts.
--sa FILE          Load/reload the Dock payload using noninteractive sudo.
-m, --message      Send a command to the running shoji daemon.
--inspect          Print a read-only macOS window/display/space snapshot.
--validation-pid N Limit a test daemon to process N; requires an explicit -c file.
--validate-sizes N Validate two named disposable size-fixture windows in process N.

Domains: config, query, window, space, display, rule, signal, debug.
Default layout is float. Use: shoji -m config layout bsp`


main :: proc() {
	args := os.args[1:]
	if len(args) > 0 &&
	   (args[0] == "-c" ||
			   args[0] == "--config" ||
			   args[0] == "--sa" ||
			   args[0] == "--validation-pid") {
		config, payload: string
		validation_pid: i32

		for i := 0; i < len(args); i += 2 {
			if i + 1 >= len(args) || args[i + 1] == "" {
        fmt.eprintln("daemon options require a path");
        os.exit(1)
      }

			switch args[i] {
			case "-c", "--config":
				if config != "" {
          fmt.eprintln("duplicate config option")
          os.exit(1)
        }
				config = args[i + 1]
			case "--sa":
				if payload != "" {
          fmt.eprintln("duplicate --sa option")
          os.exit(1)
        }
				payload = args[i + 1]
			case "--validation-pid":
				pid, ok := strconv.parse_u64(args[i + 1])
				if !ok || pid == 0 || pid > 0x7fffffff || validation_pid != 0 {
					fmt.eprintln("--validation-pid requires one positive process ID")
          os.exit(1)
				}
				validation_pid = i32(pid)
			case:
				fmt.eprintf("unknown daemon option: %s\n", args[i]); os.exit(1)
			}
		}

		if validation_pid != 0 && config == "" {
			fmt.eprintln("--validation-pid requires an explicit -c configuration")
      os.exit(1)
		}

		os.exit(mac.run(config, payload, validation_pid))
	}

	if len(args) > 0 {
		switch args[0] {
		case "--validate-sizes":
			if len(args) != 2 {fmt.eprintln("--validate-sizes requires a fixture process ID"); os.exit(2)}
			pid, valid := strconv.parse_u64(args[1])
			if !valid || pid == 0 || pid > 0x7fffffff {os.exit(2)}
			os.exit(mac.validate_window_sizes(i32(pid)))
		case "--load-sa":
			if len(args) != 2 {
        fmt.eprintln("--load-sa requires the payload dylib path")
        os.exit(1)
      }

			if err := loader.inject(args[1]); err != "" {
        fmt.eprintln(err)
        os.exit(1)
      }

			fmt.println(
				"Dock loaded the payload. Run --check-sa as your desktop user to inspect capabilities.",
			)
			return
		case "--check-sa":
			caps, err := mac.addition_check()
      if err != "" {
        fmt.eprintln(err)
        os.exit(1)
      }
			fmt.printf("Dock scripting addition: %v\n", caps)
      return
		case "--version", "-v":
			fmt.println("shoji 0.1.0-dev")
			return
		case "--help", "-h":
			fmt.println(HELP_MESSAGE)
			return
		case "-m", "--message":
			os.exit(mac.client(args[1:]))
		case "--inspect":
			if len(args) != 1 {
				fmt.eprintln("--inspect takes no arguments")
				os.exit(1)
			}
			os.exit(mac.inspect())
		case:
			fmt.eprintf("shoji: unknown option '%s'\n", args[0])
			os.exit(1)
		}
	}
	os.exit(mac.run(""))
}
