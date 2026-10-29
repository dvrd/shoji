package harness

import s "../../../src"
import tc "../../common"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import i "../../inspector/inspect"

// Compiler regression checks
// ------------------------------------------------------------------------

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
		r := s.process_run(
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

// Target validation
// ------------------------------------------------------------------------

Validation_Check :: struct {
	command: []string,
	exit_code: int,
	status, log, reason: string,
}
Validation_Target :: struct {
	version, build, architecture: string,
}
VALIDATION_TARGET := Validation_Target{"15.6", "24G84", "arm64"}
Validation_Report :: struct {
	recorded_at: string,
	target, actual: Validation_Target,
	matches_target: bool,
	head, working_tree: string,
	checks, desktop: map[string]Validation_Check,
	artifacts: map[string]string,
	status, scope: string,
}
finish_validation :: proc(
	report: ^Validation_Report,
	path, err: string,
	final: ^string,
) {
	if err != "" &&
	   report.status != "desktop-blocked" &&
	   report.status != "target-mismatch" {
		report.status = "failed"
	}
	write_error := s.write_json(path, report^)
	final^ = tc.with_error(err, "report evidence", write_error)
	if write_error != "" {
		report.status = "failed"
		fmt.eprintln("Validation evidence incomplete:", final^)
	} else {
		fmt.printf("%s; evidence: %s\n", report.status, path)
	}
}
validation_summary :: proc(
	checks, desktop: map[string]Validation_Check,
	live: bool,
) -> string {
	for _, check in checks {
		if check.status != "pass" {
			return "failed"
		}
	}
	for _, check in desktop {
		if check.status != "pass" {
			return "desktop-blocked"
		}
	}
	return(
		live \
			? "selected-live-checks-passed" \
			: "automated-checks-passed-live-pending" \
	)
}
validation_execute :: proc(
	c: tc.Context,
	args: []string,
	directory, name: string,
	timeout: time.Duration = 300 * time.Second,
) -> Validation_Check {
	r := s.process_run(
		c.executor,
		args,
		c.root,
		timeout = timeout,
		env = tc.compiler_env(c),
	)
	log := s.join(directory, s.cat(name, ".log"))
	err := s.write(log, s.cat(r.out, r.diagnostic))
	if err != "" {
		return {s.clone_args(args), -1, "fail", log, err}
	}
	return {s.clone_args(args), r.code, r.code == 0 ? "pass" : "fail", log, ""}
}
validation_cli :: proc(c: tc.Context, args: []string) -> string {
	report: Validation_Report
	path: string
	err := validation_run(c, args, &report, &path)
	if path == "" {
		return err
	}
	final: string
	finish_validation(&report, path, err, &final)
	return final
}
validation_run :: proc(
	c: tc.Context,
	args: []string,
	report_out: ^Validation_Report,
	path_out: ^string,
) -> (
	err: string,
) {
	o, e := s.parse(
		args,
		nil,
		[]string{"preflight-only", "live-animation", "dock-restart"},
	); if e != "" {
		return e
	}; if len(o.positionals) != 0 {
		return "unexpected validation argument"
	}
	if o.flags["dock-restart"] && !o.flags["live-animation"] {
		return "--dock-restart requires --live-animation"
	}
	directory, temp_error := s.temp("shoji-validation"); if temp_error != "" {
		return temp_error
	}
	report := Validation_Report {
		target    = VALIDATION_TARGET,
		status    = "running",
		scope     = "Selected automated checks only; this report does not certify all desktop behavior.",
		checks    = make(map[string]Validation_Check),
		desktop   = make(map[string]Validation_Check),
		artifacts = make(map[string]string),
	}
	defer report_out^ = report
	path := s.join(directory, "report.json")
	path_out^ = path
	report.recorded_at = fmt.tprintf("%v", time.now())
	version, ev := tc.run(c, []string{"/usr/bin/sw_vers", "-productVersion"})
	if ev != "" {
		return ev
	}
	build, eb := tc.run(c, []string{"/usr/bin/sw_vers", "-buildVersion"})
	if eb != "" {
		return eb
	}
	arch, ea := tc.run(c, []string{"/usr/bin/uname", "-m"}); if ea != "" {
		return ea
	}
	report.actual = {s.trim(version), s.trim(build), s.trim(arch)}
	report.matches_target = report.actual == report.target
	if report.head, err = tc.run(
		c,
		[]string{"git", "rev-parse", "HEAD"},
		c.root,
	); err != "" {
		return err
	}
	if report.working_tree, err = tc.run(
		c,
		[]string{"git", "status", "--porcelain"},
		c.root,
	); err != "" {
		return err
	}
	if err = s.write_json(path, report); err != "" {
		return err
	}
	if !o.flags["preflight-only"] {
		tasks := []string {
			"test:compiler",
			"check",
			"test",
			"test:harness",
			"test:amd64",
			"build:universal",
		}
		for task in tasks {
			fmt.println("Running", task, "…")
			report.checks[task] = validation_execute(
				c,
				[]string{"task", task},
				directory,
				task,
				1800 * time.Second,
			)
			if write_error := s.write_json(path, report); write_error != "" {
				original :=
					report.checks[task].status == "pass" \
						? "" \
						: s.cat("validation task failed: ", task)
				return tc.with_error(original, "report evidence", write_error)
			}
			if report.checks[task].status != "pass" {
				return s.cat("validation task failed: ", task)
			}
		}
		dev := tc.binary(c, "dev")
		report.checks["loader-self-test"] = validation_execute(
			c,
			[]string{tc.binary(c, "shoji-loader"), "--self-test"},
			directory,
			"loader-self-test",
		)
		report.checks["bootstrap-relocation"] = validation_execute(
			c,
			[]string {
				tc.binary(c, "inspector"),
				"check-bootstrap",
				tc.binary(c, "shoji-amd64"),
				tc.binary(c, "shoji-loader"),
			},
			directory,
			"bootstrap-relocation",
		)
		report.checks["package"] = validation_execute(
			c,
			[]string {
				dev,
				"package",
				"--version",
				"validation",
				"--output",
				directory,
			},
			directory,
			"package",
		)
		if report.checks["package"].status == "pass" {
			verification := i.verify_archive(
				c,
				s.join(directory, "shoji-validation-macos.tar.gz"),
			)
			report.checks["archive-checksums"] = {
				status = verification == "" ? "pass" : "fail",
				reason = verification,
			}
		}
	}
	for name in tc.RELEASE_BINARIES {
		if s.regular(tc.binary(c, name)) {
			if report.artifacts[name], err = tc.digest(c, tc.binary(c, name));
			   err != "" {
				return s.cat("binary evidence: ", err)
			}
		}
	}
	report.desktop["inspection"] = validation_execute(
		c,
		[]string{tc.binary(c, "shoji"), "--inspect"},
		directory,
		"inspection",
		15 * time.Second,
	)
	report.desktop["payload"] = validation_execute(
		c,
		[]string{tc.binary(c, "shoji"), "--check-sa"},
		directory,
		"payload",
		15 * time.Second,
	)
	if o.flags["live-animation"] {
		ready := true; for _, check in report.desktop {
			if check.status != "pass" {
				ready = false
			}
		}
		if ready {
			command := make([dynamic]string)
			append(
				&command,
				tc.binary(c, "harness"),
				"live",
				"animation",
			)
			if o.flags["dock-restart"] {
				append(&command, "--dock-restart")
			}
			report.desktop["animation"] = validation_execute(
				c,
				command[:],
				directory,
				"animation",
			)
		} else {
			report.desktop["animation"] = {
				status = "blocked",
				reason = "desktop preflight failed",
			}
		}
	}
	report.status = validation_summary(
		report.checks,
		report.desktop,
		o.flags["live-animation"],
	)
	if !report.matches_target {
		report.status = "target-mismatch"
	}
	if o.flags["preflight-only"] &&
	   report.status == "automated-checks-passed-live-pending" {
		report.status = "desktop-preflight-passed"
	}
	if report.status != "automated-checks-passed-live-pending" &&
	   report.status != "selected-live-checks-passed" &&
	   report.status != "desktop-preflight-passed" {
		return s.cat("validation: ", report.status)
	}
	return ""
}
