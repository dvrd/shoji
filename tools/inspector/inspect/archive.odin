package inspector

import s "../../../src/support"
import tc "../../common"
import "core:os"
import "core:strings"

verify_archive :: proc(c: tc.Context, archive: string) -> string {
	names, err := tc.run(c, []string{"/usr/bin/tar", "-tzf", archive})
	if err != "" {
		return err
	}
	verbose, e := tc.run(c, []string{"/usr/bin/tar", "-tvzf", archive})
	if e != "" {
		return e
	}
	for line in strings.split_lines(verbose) {
		if line != "" && line[0] != '-' && line[0] != 'd' {
			return "release contains a symlink, hardlink or special file"
		}
	}
	entries := make(map[string]bool); prefix := ""
	required := tc.release_files()
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
		if relative != "SHA256SUMS" && !tc.contains(required, relative) {
			return "release contains an unexpected or unsafe path"
		}
	}
	if prefix == "" || !entries[s.cat(prefix, "/SHA256SUMS")] {
		return "release is missing its checksum manifest"
	}
	stage, temp_error := s.temp("shoji-release-check"); if temp_error != "" {
		return temp_error
	}; defer os.remove_all(stage)
	if _, err = tc.run(
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
		if !tc.contains(required, relative) || verified[relative] {
			return "unexpected or duplicate checksum entry"
		}
		path := s.join(s.join(stage, prefix), relative)
		if !s.regular(path) {
			return "release input is not a regular file"
		}
		hash, hash_error := tc.digest(c, path); if hash_error != "" {
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
