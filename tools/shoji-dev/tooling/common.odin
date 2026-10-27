package development

import s "../../../src/support"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

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
fail :: proc(err: string) -> int { fmt.eprintln("shoji-dev:", err); return 1 }
with_error :: proc(primary, operation, failure: string) -> string {
	if failure == "" {
		return primary
	}
	extra := s.cat(operation, ": ", failure)
	return primary == "" ? extra : s.cat(primary, "; ", extra)
}
