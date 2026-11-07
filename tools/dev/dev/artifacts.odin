package development

import tc "../../common"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import support "../../../src/support"

// Build artifact management
// ------------------------------------------------------------------------

CLEAN_KEEP := []string {
	"shoji",
	"shoji-loader",
	"shoji-sa.dylib",
	"odin-arm64e",
	"dev",
	"inspector",
	"harness",
}
macho_header :: proc(header: []u8) -> bool {
	if len(header) < 4 {
		return false
	}
	magic := tc.le32(header[:4])
	return(
		magic == 0xfeedfacf ||
		magic == 0xfeedface ||
		magic == 0xcffaedfe ||
		magic == 0xcefaedfe ||
		magic == 0xbebafeca ||
		magic == 0xcafebabe \
	)
}
generated_directory :: proc(path, name: string) -> (bool, string) {
	allowed: []string
	switch name {
	case "universal":
		allowed = []string {
			"shoji",
			"shoji.new",
			"shoji-loader",
			"shoji-sa.dylib",
			"dev",
			"inspector",
			"harness",
		}
	case:
		return false, ""
	}
	entries, err := os.read_directory_by_path(path, -1, context.allocator)
	if err != nil {
		return false, fmt.tprintf(
			"cannot inspect generated directory %s: %v",
			path,
			err,
		)
	}
	for entry in entries {
		// A backup, evidence file, subdirectory or symlink makes this a retained input.
		if entry.type != .Regular || !tc.contains(allowed, entry.name) {
			return false, ""
		}
		file, open_error := os.open(support.join(path, entry.name))
		if open_error != nil {
			return false, fmt.tprintf(
				"cannot inspect generated output: %v",
				open_error,
			)
		}
		header: [4]u8; n, _ := os.read(file, header[:]); os.close(file)
		if !macho_header(header[:n]) {
			return false, ""
		}
	}
	return true, ""
}
clean_outputs :: proc(c: tc.Context) -> ([]string, string) {
	directory := tc.root_file(c, "bin")
	if support.kind(directory) == .Symlink {
		return nil, "refusing to clean a symlinked bin directory"
	}
	if !support.exists(directory) {
		return nil, ""
	}
	files, err := os.read_directory_by_path(directory, -1, context.allocator)
	if err != nil {
		return nil, fmt.tprintf("cannot list build directory: %v", err)
	}
	found := make([dynamic]string)
	for entry in files {
		if tc.contains(CLEAN_KEEP, entry.name) || entry.type == .Symlink {
			continue
		}
		path := support.join(directory, entry.name)
		if entry.type == .Directory {
			generated, inspect_error := generated_directory(path, entry.name)
			if inspect_error != "" {
				return nil, inspect_error
			}
			if generated {
				append(&found, path); continue
			}
			if strings.has_suffix(entry.name, ".dSYM") ||
			   tc.contains(
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
			macho := macho_header(header[:n])
			tool_output := tc.contains([]string{"dev-amd64", "inspector-amd64", "harness-amd64", "harness-fixture", "harness-tests"}, entry.name)
			if (strings.has_prefix(entry.name, "shoji-") || tool_output) && macho ||
			   entry.name == "libshoji-raven.a" &&
				   n == 8 &&
				   string(header[:]) == "!<arch>\n" {
				append(&found, path)
			}
		}
	}
	return found[:], ""
}
clean :: proc(c: tc.Context, dry_run: bool) -> string {
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
package_release :: proc(
	c: tc.Context,
	binaries, output, version: string,
) -> (
	string,
	string,
) {
	if !support.safe_name(version) {
		return "",
			"version must contain only letters, numbers, dots, hyphens and underscores"
	}
	archive := support.join(
		support.abs(output),
		fmt.tprintf("shoji-%s-macos.tar.gz", version),
	)
	if support.exists(archive) {
		return "", "release already exists"
	}
	if err := support.mkdir(support.abs(output)); err != "" {
		return "", err
	}
	stage, err := support.temp("shoji-release"); if err != "" {
		return "", err
	}; defer os.remove_all(stage)
	prefix := support.cat("shoji-", version); bundle := support.join(stage, prefix)
	if err = support.mkdir(support.join(bundle, "bin")); err != "" {
		return "", err
	}
	manifest := strings.builder_make(context.allocator)
	for relative in tc.release_files() {
		source := tc.root_file(c, relative)
		if strings.has_prefix(relative, "bin/") {
			source = support.join(binaries, filepath.base(relative))
		}
		if !support.regular(source) {
			return "", support.cat("missing release input: ", source)
		}
		destination := support.join(bundle, relative)
		if err = support.copy_file(destination, source); err != "" {
			return "", err
		}
		hash, e := tc.digest(c, destination); if e != "" {
			return "", e
		}
		strings.write_string(
			&manifest,
			fmt.tprintf("%s  %s\n", hash, relative),
		)
	}
	if err = support.write(
		support.join(bundle, "SHA256SUMS"),
		strings.to_string(manifest),
	); err != "" {
		return "", err
	}
	if _, err = tc.run(
		c,
		[]string{"/usr/bin/tar", "-czf", archive, "-C", stage, prefix},
		"",
		"",
		env = support.environment("COPYFILE_DISABLE", "1"),
	); err != "" {
		_ = os.remove(archive); return "", err
	}
	return archive, ""
}
package_cli :: proc(c: tc.Context, args: []string) -> string {
	o, err := support.parse(args, []string{"version", "binaries", "output"}, nil)
	if err != "" {
		return err
	}
	if len(o.positionals) != 0 || support.get(o, "version") == "" {
		return "package requires --version"
	}
	archive, e := package_release(
		c,
		support.get(o, "binaries", tc.binary(c, "universal")),
		support.get(o, "output", tc.root_file(c, "dist")),
		support.get(o, "version"),
	); if e != "" {
		return e
	}
	fmt.println(archive); return ""
}
remove_output :: proc(path: string) -> os.Error {
	if support.kind(path) == .Directory {
		return os.remove_all(path)
	}; return os.remove(path)
}
