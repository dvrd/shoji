package main

import loader "../dock"
import "core:fmt"
import "core:os"
import "core:strconv"

main :: proc() {
	when ODIN_ARCH == .arm64 {
		#assert(#config(SHOJI_ODIN_LOADER, false))
		if loader._dyld_get_image_header(0).subtype != 0x80000002 {
			fmt.eprintln("loader requires an arm64e ABI v0 executable; use the patched compiler")
			os.exit(1)
		}
	}
	if len(os.args) != 2 && !(len(os.args) == 4 && os.args[1] == "--windowserver") {
		fmt.eprintln("usage: shoji-loader PAYLOAD | --self-test | --windowserver PID PAYLOAD")
		os.exit(2)
	}
	err: string
	if len(os.args) == 2 && os.args[1] == "--self-test" {
		err = loader.self_test()
	} else if len(os.args) == 4 {
		pid, ok := strconv.parse_i64(os.args[2])
		if !ok || pid <= 0 || pid > 0x7fffffff {
			fmt.eprintln("--windowserver requires a positive process ID")
			os.exit(2)
		}
		err = loader.inject_windowserver(os.args[3], i32(pid))
	} else {
		err = loader.inject(os.args[1])
	}
	if err != "" { fmt.eprintln(err); os.exit(1) }
	fmt.println("Odin loader completed")
}
