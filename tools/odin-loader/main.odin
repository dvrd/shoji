package main

import loader "../../src/addition/loader"
import "core:fmt"
import "core:os"

main :: proc() {
	when ODIN_ARCH == .arm64 {
		#assert(#config(SHOJI_ODIN_LOADER, false))
		if loader._dyld_get_image_header(0).subtype != 0x80000002 {
			fmt.eprintln("loader requires an arm64e ABI v0 executable; use the patched compiler")
			os.exit(1)
		}
	}
	if len(os.args) != 2 {
		fmt.eprintln("usage: shoji-loader PAYLOAD | --self-test")
		os.exit(2)
	}
	err: string
	if os.args[1] == "--self-test" {
		err = loader.self_test()
	} else {
		err = loader.inject(os.args[1])
	}
	if err != "" { fmt.eprintln(err); os.exit(1) }
	fmt.println("Odin loader completed")
}
