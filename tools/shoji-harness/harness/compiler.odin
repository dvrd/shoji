package harness

import s "../../../src/support"
import tc "../../common"
import "core:fmt"
import "core:os"
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
check_asm :: proc(c: tc.Context, args: []string) -> string {
	o, err := s.parse(
		args,
		[]string{"compiler", "library-root", "target"},
		nil,
	); if err != "" {
		return err
	}; if len(o.positionals) != 0 {
		return "unexpected check-asm arguments"
	}
	odin := s.get(o, "compiler", tc.compiler(c))
	libs := s.get(o, "library-root", tc.library_root(c))
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
