package main

import "core:fmt"
import "core:os"
import "core:strings"

shell_quote :: proc(value: string) -> string {
	replaced, _ := strings.replace_all(value, "'", "'\\''")
	defer delete(replaced)
	return fmt.aprintf("'%s'", replaced)
}

run :: proc(command: string, description: string) {
	args := [?]string{"/bin/sh", "-c", command}
	state, stdout, stderr, err := os.process_exec(
		os.Process_Desc{command = args[:]},
		context.allocator,
	)
	defer delete(stdout)
	defer delete(stderr)
	if len(stdout) > 0 {
		fmt.printf("%s", string(stdout))
	}
	if len(stderr) > 0 {
		fmt.eprintf("%s", string(stderr))
	}
	if err != nil || !state.success || state.exit_code != 0 {
		fmt.eprintf("%s failed (status %d)\n", description, state.exit_code)
		os.exit(1)
	}
}

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln("usage: build_odin_arm64e ODIN_SOURCE")
		os.exit(2)
	}
	source := shell_quote(os.args[1])
	defer delete(source)
	names := [?]string{"src", "base", "core", "vendor", "build_odin.sh"}
	for name in names {
		quoted_name := shell_quote(name)
		command := fmt.aprintf("test -e %s/%s", source, quoted_name)
		delete(quoted_name)
		defer delete(command)
		run(command, "source checkout validation")
	}
	command := fmt.aprintf(
		"set -eu; project=$PWD; build=$(mktemp -d -t shoji-odin-arm64e); trap 'rm -rf \"$build\"' EXIT; " +
		"cp -R %s/src \"$build/src\"; cp %s/build_odin.sh \"$build/\"; " +
		"ln -s %s/base \"$build/base\"; ln -s %s/core \"$build/core\"; ln -s %s/vendor \"$build/vendor\"; " +
		"cd \"$build\"; " +
		"for name in build_settings.cpp linker.cpp llvm_backend_general.cpp; do " +
		"include=--include=src/$name; " +
		"if git apply \"$include\" --check \"$project/tools/odin-arm64e.patch\" >/dev/null 2>&1; then git apply \"$include\" \"$project/tools/odin-arm64e.patch\"; " +
		"elif ! git apply \"$include\" --reverse --check \"$project/tools/odin-arm64e.patch\" >/dev/null 2>&1; then echo \"Cannot apply arm64e patch to $name\" >&2; exit 1; fi; done; " +
		"sh build_odin.sh release; mkdir -p \"$project/bin\"; cp odin \"$project/bin/odin-arm64e\"; " +
		"echo \"Built $project/bin/odin-arm64e; use ODIN_ROOT=%s when invoking it directly.\"",
		source,
		source,
		source,
		source,
		source,
		os.args[1],
	)
	defer delete(command)
	run(command, "arm64e compiler build")
}
