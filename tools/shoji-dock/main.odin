package main

import d "scanner"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

HELP :: `Usage:
  shoji-dock snapshot --out DIR [--binary FILE --version VERSION --build BUILD]
  shoji-dock fetch --build BUILD --out DIR [--catalog APPLE_URL]
                   [--package LOCAL_INSTALLASSISTANT | --url APPLE_PACKAGE_URL | --extracted DIR] [--no-progress]
  shoji-dock scan SNAPSHOT_OR_BINARY [--profile VERSION] [--out REPORT.json]
  shoji-dock compare BASELINE TARGET --out DIR [--profile VERSION]
                     [--baseline-select TARGET=0xADDRESS ...]
  shoji-dock propose ANALYSIS --select TARGET=candidate-N [--select ...] --out FILE.patch

Public downloads only. Fetch extracts packages without running installers.
Snapshot, scan, and compare do not inject or contact Dock's running process.
Unknown target versions use the 26.6 scan profile unless --profile is supplied.
Compare defaults to the baseline's profile. Reports provide static evidence,
not runtime compatibility certification. Patches require explicit selections
and do not change the supported-OS gate.
`

main :: proc() {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	args := os.args[1:]
	if len(args) == 0 || args[0] == "--help" || args[0] == "help" {
		fmt.print(HELP); return
	}
	code := execute(args)
	if code != 0 {
		os.exit(code)
	}
}
execute :: proc(args: []string) -> int {
	flags := make(map[string]string); pos := make([dynamic]string)
	selections := make([dynamic]string)
	baseline_selections := make([dynamic]string)
	for i := 1; i < len(args); i += 1 {
		arg := args[i]
		if strings.has_prefix(arg, "--") {
			if arg == "--no-progress" {
				flags[arg] = "1"; continue
			}
			switch arg {
			case "--out",
			     "--binary",
			     "--version",
			     "--build",
			     "--profile",
			     "--catalog",
			     "--package",
			     "--extracted",
			     "--url",
			     "--select",
			     "--baseline-select":
			case:
				fmt.eprintf("Unknown option: %s\n", arg); return 2
			}
			if i + 1 >= len(args) ||
			   strings.has_prefix(args[i + 1], "--") ||
			   args[i + 1] == "" {
				fmt.eprintf("%s needs a value\n", arg); return 2
			}
			i += 1
			if arg == "--select" {
				append(&selections, args[i])
			} else if arg == "--baseline-select" {
				append(&baseline_selections, args[i])
			} else {
				if _, exists := flags[arg]; exists {
					fmt.eprintf("Duplicate option: %s\n", arg); return 2
				}; flags[arg] = args[i]
			}
		} else {
			append(&pos, arg)
		}
	}
	allowed: string
	switch args[0] {
	case "snapshot":
		allowed = " --out --binary --version --build "
	case "fetch":
		allowed = " --out --build --catalog --package --url --extracted --no-progress "
	case "scan", "compare":
		allowed = " --out --profile "
	case "propose":
		allowed = " --out "
	case:
		fmt.eprintf("Unknown command: %s\n", args[0]); return 2
	}
	for key in flags {
		if !strings.contains(allowed, fmt.tprintf(" %s ", key)) {
			fmt.eprintf("%s is not valid for %s\n", key, args[0]); return 2
		}
	}
	if len(selections) > 0 && args[0] != "propose" {
		fmt.eprintln("--select is only valid for propose"); return 2
	}
	if len(baseline_selections) > 0 && args[0] != "compare" {
		fmt.eprintln("--baseline-select is only valid for compare"); return 2
	}
	err: string
	out := flags["--out"]
	switch args[0] {
	case "snapshot":
		if len(pos) != 0 || out == "" {
			fmt.eprintln("snapshot requires --out DIR"); return 2
		}
		binary := flags["--binary"]; version := flags["--version"]
		build := flags["--build"]
		if binary == "" {
			binary = "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"
			if version == "" {
				version, err = d.plist_field(
					"/System/Library/CoreServices/SystemVersion.plist",
					"ProductVersion",
				)
				if err != "" {
					break
				}
			}
			if build == "" {
				build, err = d.plist_field(
					"/System/Library/CoreServices/SystemVersion.plist",
					"ProductBuildVersion",
				)
				if err != "" {
					break
				}
			}
		}
		origin := d.Manifest{}
		if flags["--binary"] == "" &&
		   flags["--version"] == "" &&
		   flags["--build"] == "" {
			origin.metadata_source = "installed_system_plist"
		}
		err = d.snapshot(binary, version, build, out, origin)
	case "fetch":
		if len(pos) != 0 || out == "" || flags["--build"] == "" {
			fmt.eprintln("fetch requires --build BUILD --out DIR"); return 2
		}
		if flags["--package"] != "" && flags["--url"] != "" {
			fmt.eprintln("choose --package or --url"); return 2
		}
		if flags["--extracted"] != "" &&
		   (flags["--package"] != "" ||
				   flags["--url"] != "" ||
				   flags["--catalog"] != "") {
			fmt.eprintln(
				"--extracted cannot be combined with --package, --url or --catalog",
			); return 2
		}
		catalog := flags["--catalog"]; if catalog == "" {
			catalog = d.DEFAULT_CATALOG
		}
		err = d.fetch(
			flags["--build"],
			out,
			catalog,
			flags["--package"],
			flags["--url"],
			flags["--no-progress"] == "",
			flags["--extracted"],
		)
	case "scan":
		if len(pos) != 1 {
			fmt.eprintln("scan requires one snapshot or binary"); return 2
		}
		bundle, error := d.load_bundle(pos[0]); if error != "" {
			err = error; break
		}
		report, error2 := d.scan(
			bundle,
			d.choose_profile(bundle, flags["--profile"]),
		); if error2 != "" {
			err = error2; break
		}
		d.print_scan(report)
		if out != "" {
			err = d.write_json(out, report)
		}
		if err == "" {
			for t in report.targets {
				if t.status != "matched" && t.status != "moved" {
					return 1
				}
			}
		}
	case "compare":
		if len(pos) != 2 || out == "" {
			fmt.eprintln("compare requires BASELINE TARGET --out DIR")
			return 2
		}
		baseline, error := d.load_bundle(pos[0]); if error != "" {
			err = error; break
		}
		target, error2 := d.load_bundle(pos[1]); if error2 != "" {
			err = error2; break
		}
		report, error3 := d.compare(
			baseline,
			target,
			d.choose_profile(baseline, flags["--profile"]),
			baseline_selections[:],
		); if error3 != "" {
			err = error3; break
		}
		err = d.write_analysis(report, out)
		if err == "" {
			fmt.printf("Comparison report: %s\n", d.join(out, "report.md"))
		}
	case "propose":
		if len(pos) != 1 || out == "" {
			fmt.eprintln(
				"propose requires ANALYSIS --select TARGET=candidate-N --out FILE.patch",
			)
			return 2
		}
		err = d.propose(pos[0], selections[:], out)
	}
	if err != "" {
		fmt.eprintf("shoji-dock: %s\n", err); return 2
	}
	return 0
}
