package development

import s "../../../src/support"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

CLEAN_KEEP := []string {
	"shoji",
	"shoji-loader",
	"shoji-sa.dylib",
	"odin-arm64e",
	"shoji-dev",
}
contains :: proc(values: []string, value: string) -> bool {
	for v in values {
		if v == value {
			return true
		}
	}; return false
}
clean_outputs :: proc(c: Context) -> ([]string, string) {
	directory := root_file(c, "bin")
	if s.kind(directory) == .Symlink {
		return nil, "refusing to clean a symlinked bin directory"
	}
	if !s.exists(directory) {
		return nil, ""
	}
	files, err := os.read_directory_by_path(directory, -1, context.allocator)
	if err != nil {
		return nil, fmt.tprintf("cannot list build directory: %v", err)
	}
	found := make([dynamic]string)
	for entry in files {
		if contains(CLEAN_KEEP, entry.name) || entry.type == .Symlink {
			continue
		}
		path := s.join(directory, entry.name)
		if entry.type == .Directory {
			if strings.has_suffix(entry.name, ".dSYM") ||
			   contains(
				   []string {
					   "ShojiAlphaProbe.app",
					   "ShojiScrollProbe.app",
					   "raven",
				   },
				   entry.name,
			   ) {
				append(&found, path)
			}
		} else if entry.type == .Regular {
			f, e := os.open(path); if e != nil {
				return nil, fmt.tprintf("cannot inspect output: %v", e)
			}
			header: [8]u8; n, _ := os.read(f, header[:]); os.close(f)
			magic := n >= 4 ? le32(header[:4]) : 0
			macho :=
				magic == 0xfeedfacf ||
				magic == 0xfeedface ||
				magic == 0xcffaedfe ||
				magic == 0xcefaedfe ||
				magic == 0xbebafeca ||
				magic == 0xcafebabe
			if strings.has_prefix(entry.name, "shoji-") && macho ||
			   entry.name == "libshoji-raven.a" &&
				   n == 8 &&
				   string(header[:]) == "!<arch>\n" {
				append(&found, path)
			}
		}
	}
	return found[:], ""
}
clean :: proc(c: Context, dry_run: bool) -> string {
	paths, err := clean_outputs(c); if err != "" {
		return err
	}
	for path in paths {
		fmt.println(dry_run ? "Would remove:" : "Removing:", path)
		if !dry_run {
			if e := remove_output(path); e != nil {
				return fmt.tprintf("cannot remove output: %v", e)
			}
		}
	}
	fmt.printf(
		"%s %d rebuildable outputs; installed runtime, native tooling, compiler and artifacts preserved.\n",
		dry_run ? "Found" : "Removed",
		len(paths),
	); return ""
}
RELEASE_BINARIES := []string {
	"shoji",
	"shoji-loader",
	"shoji-sa.dylib",
	"shoji-dev",
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
package_release :: proc(
	c: Context,
	binaries, output, version: string,
) -> (
	string,
	string,
) {
	if !s.safe_name(version) {
		return "",
			"version must contain only letters, numbers, dots, hyphens and underscores"
	}
	archive := s.join(
		s.abs(output),
		fmt.tprintf("shoji-%s-macos.tar.gz", version),
	)
	if s.exists(archive) {
		return "", "release already exists"
	}
	if err := s.mkdir(s.abs(output)); err != "" {
		return "", err
	}
	stage, err := s.temp("shoji-release"); if err != "" {
		return "", err
	}; defer os.remove_all(stage)
	prefix := s.cat("shoji-", version); bundle := s.join(stage, prefix)
	if err = s.mkdir(s.join(bundle, "bin")); err != "" {
		return "", err
	}
	manifest := strings.builder_make(context.allocator)
	for relative in release_files() {
		source := root_file(c, relative)
		if strings.has_prefix(relative, "bin/") {
			source = s.join(binaries, filepath.base(relative))
		}
		if !s.regular(source) {
			return "", s.cat("missing release input: ", source)
		}
		destination := s.join(bundle, relative)
		if err = s.copy(destination, source); err != "" {
			return "", err
		}
		hash, e := digest(c, destination); if e != "" {
			return "", e
		}
		strings.write_string(
			&manifest,
			fmt.tprintf("%s  %s\n", hash, relative),
		)
	}
	if err = s.write(
		s.join(bundle, "SHA256SUMS"),
		strings.to_string(manifest),
	); err != "" {
		return "", err
	}
	if _, err = run(
		c,
		[]string{"/usr/bin/tar", "-czf", archive, "-C", stage, prefix},
		"",
		"",
		env = s.environment("COPYFILE_DISABLE", "1"),
	); err != "" {
		_ = os.remove(archive); return "", err
	}
	return archive, ""
}
verify_archive :: proc(c: Context, archive: string) -> string {
	names, err := run(c, []string{"/usr/bin/tar", "-tzf", archive})
	if err != "" {
		return err
	}
	verbose, e := run(c, []string{"/usr/bin/tar", "-tvzf", archive})
	if e != "" {
		return e
	}
	for line in strings.split_lines(verbose) {
		if line != "" && line[0] != '-' && line[0] != 'd' {
			return "release contains a symlink, hardlink or special file"
		}
	}
	entries := make(map[string]bool); prefix := ""
	required := release_files()
	for line in strings.split_lines(names) {
		if line == "" {
			continue
		}
		if strings.has_prefix(line, "/") {
			return "release contains an absolute path"
		}
		parts := strings.split(line, "/")
		if len(parts) == 0 || !s.safe_name(parts[0]) {
			return "invalid release prefix"
		}
		if prefix == "" {
			prefix = parts[0]
		}; if parts[0] != prefix {
			return "release has multiple roots"
		}
		name := strings.trim_suffix(line, "/")
		if entries[name] {
			return "release contains duplicate members"
		}; entries[name] = true
		if name == prefix || name == s.cat(prefix, "/bin") {
			continue
		}
		relative := strings.trim_prefix(name, s.cat(prefix, "/"))
		if relative != "SHA256SUMS" && !contains(required, relative) {
			return "release contains an unexpected or unsafe path"
		}
	}
	if prefix == "" || !entries[s.cat(prefix, "/SHA256SUMS")] {
		return "release is missing its checksum manifest"
	}
	stage, temp_error := s.temp("shoji-release-check"); if temp_error != "" {
		return temp_error
	}; defer os.remove_all(stage)
	if _, err = run(
		c,
		[]string {
			"/usr/bin/tar",
			"-xzf",
			s.abs(archive),
			"-C",
			stage,
			"--no-same-owner",
			"--no-same-permissions",
		},
	); err != "" {
		return err
	}
	text, read_error := s.read(s.join(s.join(stage, prefix), "SHA256SUMS"))
	if read_error != "" {
		return read_error
	}
	verified := make(map[string]bool)
	for line in strings.split_lines(text) {
		if line == "" {
			continue
		}
		if len(line) < 67 ||
		   line[64:66] != "  " ||
		   !s.hexadecimal(line[:64], 64) {
			return "invalid checksum manifest"
		}
		relative := line[66:]
		if !contains(required, relative) || verified[relative] {
			return "unexpected or duplicate checksum entry"
		}
		path := s.join(s.join(stage, prefix), relative)
		if !s.regular(path) {
			return "release input is not a regular file"
		}
		hash, hash_error := digest(c, path); if hash_error != "" {
			return hash_error
		}
		if hash != strings.to_lower(line[:64]) {
			return "release checksum mismatch"
		}
		if strings.has_prefix(relative, "bin/") {
			info, _ := os.stat(path, context.allocator)
			if info.mode & {.Execute_User, .Execute_Group, .Execute_Other} ==
			   nil {
				return "release binary is not executable"
			}
		}
		verified[relative] = true
	}
	for relative in required {
		if !verified[relative] || !entries[s.cat(prefix, "/", relative)] {
			return "release is missing required files"
		}
	}
	return ""
}
package_cli :: proc(c: Context, args: []string) -> string {
	o, err := s.parse(
		args,
		[]string{"version", "binaries", "output"},
		[]string{"verify"},
	); if err != "" {
		return err
	}
	if o.flags["verify"] {
		if len(o.positionals) != 1 {
			return "package --verify expects an archive"
		}; return verify_archive(c, o.positionals[0])
	}
	if len(o.positionals) != 0 || s.get(o, "version") == "" {
		return "package requires --version"
	}
	archive, e := package_release(
		c,
		s.get(o, "binaries", binary(c, "universal")),
		s.get(o, "output", root_file(c, "dist")),
		s.get(o, "version"),
	); if e != "" {
		return e
	}
	if err = verify_archive(c, archive); err != "" {
		return err
	}; fmt.println(archive); return ""
}
remove_output :: proc(path: string) -> os.Error {
	if s.kind(path) == .Directory {
		return os.remove_all(path)
	}; return os.remove(path)
}
