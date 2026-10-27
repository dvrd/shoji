package development

import s "../../../src/support"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

Asm_Case :: struct {
	name, source, diagnostic: string,
}
ASM_CASES := []Asm_Case {
	{
		"conditional_call",
		`package probe
invoke :: asm(f: rawptr) [f = %x19, #clobber %x30, #volatile] {
 cbz f, .done;
 blr f;
.done:
 nop;
}
`,
		"",
	},
	{
		"sequential_calls",
		`package probe
invoke :: asm(f: rawptr) [f = %x19, #clobber %x30, #volatile] {
 blr f;
 blr f;
}
`,
		"",
	},
	{
		"output_after_call",
		`package probe
invoke :: asm(f: rawptr) -> (r: u64) [f = %x19, #clobber %x30, #volatile] {
 blr f;
 mov r, 1;
}
`,
		"",
	},
	{
		"authenticated_calls",
		`package probe
@(enable_target_feature="pauth")
invoke :: asm(f: rawptr) [f = %x19, #clobber %x30, #volatile] {
 blraaz f;
 blrabz f;
}
`,
		"",
	},
	{
		"direct_call",
		`package probe
invoke :: asm() [#clobber %x30, #volatile] {
 bl .callee;
 b .done;
.callee:
 ret;
.done:
 nop;
}
`,
		"",
	},
	{
		"dead_write_after_call",
		`package probe
invoke :: asm(f: rawptr, n: u64) [f = %x19, n = %x20, #clobber %x30, #volatile] {
 blr f;
 mov %x30, n;
 mov %x30, n;
}
`,
		"never read before being overwritten",
	},
	{
		"dead_link_write",
		`package probe
unused :: asm(n: u64) [n = %x0, #clobber %x30] {
 mov %x30, n;
 mov %x30, n;
}
`,
		"never read before being overwritten",
	},
	{
		"tail_branch_does_not_return",
		`package probe
jump :: asm(f: rawptr) [f = %x19, #volatile] {
 br f;
}
`,
		"no reachable path",
	},
}
check_asm :: proc(c: Context, args: []string) -> string {
	o, err := s.parse(
		args,
		[]string{"compiler", "library-root", "target"},
		nil,
	); if err != "" {
		return err
	}; if len(o.positionals) != 0 {
		return "unexpected check-asm arguments"
	}
	odin := s.get(o, "compiler", compiler(c))
	libs := s.get(o, "library-root", library_root(c))
	target := s.get(o, "target", "darwin_arm64")
	stage, e := s.temp("shoji-asm-check"); if e != "" {
		return e
	}; defer os.remove_all(stage)
	failed := false
	for item in ASM_CASES {
		dir := s.join(stage, item.name); if err = s.mkdir(dir); err != "" {
			return err
		}
		if err = s.write(s.join(dir, "probe.odin"), item.source); err != "" {
			return err
		}
		r := s.run(
			c.executor,
			[]string {
				odin,
				"check",
				dir,
				"-no-entry-point",
				"-warnings-as-errors",
				s.cat("-target:", target),
			},
			"",
			"",
			30 * time.Second,
			s.environment("ODIN_ROOT", s.abs(libs)),
		)
		output := s.cat(r.out, r.diagnostic)
		passed :=
			item.diagnostic == "" \
				? r.code == 0 \
				: r.code != 0 && strings.contains(output, item.diagnostic)
		if !passed {
			failed = true; fmt.println("FAIL", item.name, output)
		} else {
			fmt.println("PASS", item.name)
		}
	}
	return failed ? "compiler regression checks failed" : ""
}
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
check_bootstrap :: proc(c: Context, args: []string) -> string {
	if len(args) == 0 {
		return "check-bootstrap expects one or more binaries"
	}
	for path in args {
		metadata, err := run(c, []string{"/usr/bin/otool", "-l", path})
		if err != "" {
			return err
		}
		code, e := run(
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
