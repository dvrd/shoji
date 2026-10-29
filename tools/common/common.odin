package tool_common

import s "../../src"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

// Tool context
// ------------------------------------------------------------------------

// Keep each tool's command dispatch local; share allocation and exit handling.
cli_main :: proc(name, help: string, dispatch: proc(Context, []string) -> string) -> int {
	s.configure_signals()
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	args := os.args[1:]
	if len(args) == 0 {
		fmt.println(help)
		return 0
	}
	for arg in args {
		if arg == "--help" {
			fmt.println(help)
			return 0
		}
	}
	if err := dispatch(Context{root = project_root()}, args); err != "" {
		fmt.eprintf("%s: %s\n", name, err)
		return s.interrupted() ? 130 : 1
	}
	return 0
}

Context :: struct {
	root: string,
	executor: s.Executor,
}
run :: proc(
	c: Context,
	args: []string,
	dir: string = "",
	input: string = "",
	timeout: time.Duration = 300 * time.Second,
	env: []string = nil,
) -> (
	string,
	string,
) { return s.checked(c.executor, args, dir, input, timeout, env) }
root_file :: proc(c: Context, path: string) -> string {
	return s.join(c.root, path)
}
binary :: proc(c: Context, name: string) -> string {
	return root_file(c, s.cat("bin/", name))
}
compiler :: proc(c: Context) -> string {
	if value := os.get_env("ODIN", context.allocator); value != "" {
		return value
	}; p := root_file(c, ".toolchain/Odin/odin")
	return s.regular(p) ? p : "odin"
}
library_root :: proc(c: Context) -> string {
	return root_file(c, ".toolchain/Odin")
}
compiler_env :: proc(c: Context) -> []string {
	if s.kind(s.join(library_root(c), "core")) == .Directory {
		return s.environment("ODIN_ROOT", library_root(c))
	}; return nil
}
digest :: proc(c: Context, path: string) -> (string, string) {
	text, err := run(c, []string{"/usr/bin/shasum", "-a", "256", path})
	if err != "" {
		return "", err
	}; fields := strings.fields(text)
	if len(fields) < 1 || !s.hexadecimal(fields[0], 64) {
		return "", "invalid SHA-256 output"
	}; return fields[0], ""
}
read_json :: proc(path: string, value: ^$T) -> string {
	return s.read_json(path, value)
}
copy_tree :: proc(c: Context, dst, src: string) -> string {
	_, err := run(c, []string{"/bin/cp", "-R", src, dst}); return err
}
project_root :: proc() -> string {
	cwd, _ := os.get_working_directory(context.allocator)
	if s.regular(s.join(cwd, "Taskfile.yml")) {
		return cwd
	}; exe, _ := os.get_executable_path(context.allocator)
	return filepath.dir(filepath.dir(exe))
}
with_error :: proc(primary, operation, failure: string) -> string {
	if failure == "" {
		return primary
	}
	extra := s.cat(operation, ": ", failure)
	return primary == "" ? extra : s.cat(primary, "; ", extra)
}

le32 :: proc(b: []u8) -> u32 {
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}

// Release artifacts
// ------------------------------------------------------------------------

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
	"dev",
	"inspector",
	"harness",
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
