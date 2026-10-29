package inspector

import s "../../../src"
import tc "../../common"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:os"

// Bootstrap inspection
// ------------------------------------------------------------------------

Instruction :: struct {
	address: u64,
	op, operands: string,
}
parse_disassembly :: proc(text: string) -> []Instruction {
	result := make([dynamic]Instruction)
	for line in strings.split_lines(text) {
		f := strings.fields(line)
		if len(f) < 3 || !strings.has_suffix(f[0], ":") {
			continue
		}
		addr, ok := strconv.parse_u64(f[0][:len(f[0]) - 1], 16); if !ok {
			continue
		}
		i := 1
		for i < len(f) &&
		    (len(f[i]) == 2 || len(f[i]) == 8) &&
		    s.hexadecimal(f[i], len(f[i])) { i += 1 }
		if i >= len(f) {
			continue
		}
		operands := strings.join(f[i + 1:], " ")
		for delimiter in ([]string{"<", ";"}) {
			if at := strings.index(operands, delimiter); at >= 0 {
				operands = operands[:at]
			}
		}
		append(&result, Instruction{addr, f[i], operands})
	}
	return result[:]
}
validate_bootstrap :: proc(metadata, disassembly: string) -> string {
	count := 0; pure := false
	for block in strings.split(metadata, "Section") {
		fields := strings.fields(block); found := false
		for v, i in fields {
			if v == "sectname" &&
			   i + 1 < len(fields) &&
			   fields[i + 1] == "__shoji_boot" {
				found = true
			}
		}
		if !found {
			continue
		}; count += 1
		for v, i in fields {
			if v == "flags" && i + 1 < len(fields) {
				flags, ok := strconv.parse_u64(fields[i + 1])
				pure = ok && flags & 0x80000000 != 0
			}
		}
	}
	if count != 1 || !pure {
		return "expected one pure-instruction __shoji_boot section"
	}
	if !strings.contains(disassembly, "remote_worker") ||
	   !strings.contains(disassembly, "remote_entry") {
		return "missing bootstrap entry/worker symbols"
	}
	instructions := parse_disassembly(disassembly)
	if len(instructions) == 0 {
		return "missing bootstrap instructions"
	}
	addresses := make(map[u64]bool)
	for item in instructions { addresses[item.address] = true }
	for item in instructions {
		if strings.contains(item.operands, "%rip") ||
		   item.op == "adr" ||
		   item.op == "adrp" {
			return "bootstrap contains PC-relative data"
		}
		branch :=
			item.op == "b" ||
			item.op == "bl" ||
			item.op == "cbz" ||
			item.op == "cbnz" ||
			item.op == "tbz" ||
			item.op == "tbnz" ||
			strings.has_prefix(item.op, "b.") ||
			strings.has_prefix(item.op, "j") ||
			strings.has_prefix(item.op, "call")
		if branch && !strings.has_prefix(s.trim(item.operands), "*") {
			rest := item.operands
			for {
				at := strings.index(rest, "0x"); if at < 0 {
					break
				}; rest = rest[at + 2:]; n := 0
				for n < len(rest) && s.hexadecimal(rest[n:n + 1], 1) { n += 1 }
				if n == 0 {
					break
				}; target, ok := strconv.parse_u64(rest[:n], 16)
				if !ok || !addresses[target] {
					return "bootstrap branch leaves its copied section"
				}; rest = rest[n:]
			}
		}
		if strings.has_prefix(item.op, "ldr") &&
		   strings.contains(item.operands, ", 0x") {
			return "bootstrap contains a literal load"
		}
	}
	return ""
}
check_bootstrap :: proc(c: tc.Context, args: []string) -> string {
	if len(args) == 0 {
		return "check-bootstrap expects one or more binaries"
	}
	for path in args {
		metadata, err := tc.run(c, []string{"/usr/bin/otool", "-l", path})
		if err != "" {
			return err
		}
		code, e := tc.run(
			c,
			[]string {
				"/usr/bin/xcrun",
				"llvm-objdump",
				"--disassemble",
				"--section=__shoji_boot",
				path,
			},
		); if e != "" {
			return e
		}
		if err = validate_bootstrap(metadata, code); err != "" {
			return s.cat(path, ": ", err)
		}
		fmt.println(
			path,
			": relocation-independent bootstrap instructions checked",
		)
	}
	return ""
}

// Mach-O normalization
// ------------------------------------------------------------------------

normalize_bytes :: proc(bytes: []u8) -> string {
	if len(bytes) < 32 {
		return "truncated Mach-O header"
	}
	if tc.le32(bytes[:4]) != 0xfeedfacf || tc.le32(bytes[4:8]) != 0x0100000c {
		return "expected a thin arm64 Mach-O binary"
	}
	subtype := tc.le32(bytes[8:12])
	if subtype == 0x80000002 {
		return ""
	}
	if subtype != 0x81000002 {
		return fmt.tprintf(
			"expected arm64e ABI v1; found subtype 0x%08x",
			subtype,
		)
	}
	bytes[8], bytes[9], bytes[10], bytes[11] = 2, 0, 0, 0x80; return ""
}
normalize_arm64e :: proc(path: string) -> string {
	if !s.regular(path) {
		return "ABI input must be a regular, non-symlink file"
	}
	b, err := os.read_entire_file(path, context.allocator); if err != nil {
		return fmt.tprintf("cannot read binary: %v", err)
	}
	if e := normalize_bytes(b); e != "" {
		return e
	}
	if e := os.write_entire_file(path, b); e != nil {
		return fmt.tprintf("cannot normalize binary: %v", e)
	}
	return ""
}

// Release archive inspection
// ------------------------------------------------------------------------

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
