package inspector

import s "../../../src/support"
import tc "../../common"
import "core:fmt"
import "core:strconv"
import "core:strings"

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
