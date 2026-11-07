package shoji

import loader "dock"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

HELP_MESSAGE :: `
Usage: shoji [-c CONFIG] [--sa]
       shoji -m DOMAIN [ARGUMENTS...]
       shoji --load-sa
       shoji --check-sa
       shoji --ws-attach
       shoji --check-ws
       shoji --inspect
       shoji --version
       shoji service install|start|stop|restart|status|uninstall

Run without arguments to start the window manager.
-c, --config FILE   Execute FILE through /bin/sh after the socket starts.
--sa FILE          Load/reload the Dock payload using noninteractive sudo.
-m, --message      Send a command to the running shoji daemon.
--inspect          Print a read-only macOS window/display/space snapshot.
--ws-attach        Load the WindowServer gate and hand it to the caller (root).
--check-ws         Check the experimental WindowServer probe handshake.
--ws-report [DIR]        WindowServer payload install report; with DIR, export the event ring (bin + JSON).
--ws-space-move W S X Y  Experimental (SHOJI_WS_ADAPTER=1): gated move of window W to Space S landing at X,Y.
--validation-pid N Limit a test daemon to process N; requires an explicit -c file.
--validate-sizes N Validate two named disposable size-fixture windows in process N.
--validate-swipe N Measure native swipe spacing with two named disposable fixture windows.

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
		for i := 0; i < len(args); i += 1 {
			if args[i] == "--sa" {
				if payload != "" {fmt.eprintln("duplicate --sa option"); os.exit(1)}
				resolved, err := addition_payload_path()
				if err != "" {fmt.eprintln(err); os.exit(1)}
				payload = resolved
				// Plists written before --sa took no value still carry a path.
				if i + 1 < len(args) && !strings.has_prefix(args[i + 1], "-") {i += 1}
				continue
			}
			if i + 1 >= len(args) || args[i + 1] == "" {
				fmt.eprintln("daemon options require a value"); os.exit(1)
			}
			switch args[i] {
			case "-c", "--config":
				if config != "" {fmt.eprintln("duplicate config option"); os.exit(1)}
				config = args[i + 1]
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
			i += 1
		}

		if validation_pid != 0 && config == "" {
			fmt.eprintln("--validation-pid requires an explicit -c configuration")
      os.exit(1)
		}

		os.exit(run(config, payload, validation_pid))
	}

	if len(args) > 0 {
		switch args[0] {
		case "service":
			binary, _ := os.get_executable_path(context.allocator)
			os.exit(service_cli(args[1:], binary))
		case "--validate-sizes", "--validate-swipe":
			if len(args) != 2 {fmt.eprintln("validation requires a fixture process ID"); os.exit(2)}
			pid, valid := strconv.parse_u64(args[1])
			if !valid || pid == 0 || pid > 0x7fffffff {os.exit(2)}
			os.exit(validate_window_sizes(i32(pid), args[0] == "--validate-swipe"))
		case "--load-sa":
			if len(args) != 1 {
				fmt.eprintln("--load-sa takes no arguments; it loads the payload beside shoji")
				os.exit(2)
			}
			payload, payload_err := addition_payload_path()
			if payload_err != "" {fmt.eprintln(payload_err); os.exit(1)}
			if err := loader.inject(payload); err != "" {
        fmt.eprintln(err)
        os.exit(1)
      }

			fmt.println(
				"Dock loaded the payload. Run --check-sa as your desktop user to inspect capabilities.",
			)
			return
		case "--check-sa":
			caps, err := addition_check()
      if err != "" {
        fmt.eprintln(err)
        os.exit(1)
      }
			fmt.printf("Dock scripting addition: %v\n", caps)
      return
		case "--ws-attach":
			os.exit(ws_attach_cli(args[1:]))
		case "--ws-space-move":
			if len(args) != 5 {
				fmt.eprintln("--ws-space-move takes WINDOW SPACE X Y")
				os.exit(2)
			}
			os.exit(ws_space_move_cli(args[1:]))
		case "--ws-report":
			if len(args) > 2 {
				fmt.eprintln("--ws-report takes [DIR]")
				os.exit(2)
			}
			os.exit(ws_report_cli(args[1:]))
		case "--check-ws":
			if len(args) != 1 {
				fmt.eprintln("--check-ws takes no arguments")
				os.exit(2)
			}
			probe := ws_gate_probe()
			fmt.printf("WindowServer gate: %v (%s)\n", probe.level, probe.detail)
			if probe.level == .Serving {
				fmt.printf("  owner pid %d, %d forwarded calls recorded\n", probe.owner_pid, probe.calls)
			}
			if probe.level == .Absent {os.exit(1)}
			return
		case "--version", "-v":
			fmt.println("shoji 0.1.0-dev")
			return
		case "--help", "-h":
			fmt.println(HELP_MESSAGE)
			return
		case "-m", "--message":
			os.exit(client(args[1:]))
		case "--inspect":
			if len(args) != 1 {
				fmt.eprintln("--inspect takes no arguments")
				os.exit(1)
			}
			os.exit(inspect())
		case:
			fmt.eprintf("shoji: unknown option '%s'\n", args[0])
			os.exit(1)
		}
	}
	os.exit(run(""))
}
