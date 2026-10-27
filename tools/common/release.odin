package tool_common

import s "../../src/support"

contains :: proc(values: []string, value: string) -> bool {
	for v in values {
		if v == value {
			return true
		}
	}; return false
}
RELEASE_BINARIES := []string {
	"shoji",
	"shoji-loader",
	"shoji-sa.dylib",
	"shoji-dev",
	"shoji-inspector",
	"shoji-harness",
}
RELEASE_DOCUMENTS := []string {
	"README.md",
	"PORTING.md",
	"VALIDATION.md",
	"SETUP.md",
	"LICENSE",
}
release_files :: proc() -> []string {
	result := make([dynamic]string)
	for name in RELEASE_BINARIES { append(&result, s.cat("bin/", name)) }
	append(&result, ..RELEASE_DOCUMENTS); return result[:]
}
