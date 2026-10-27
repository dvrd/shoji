package development

import s "../../../src/support"
import "core:fmt"
import "core:time"

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
	c: Context,
	args: []string,
	directory, name: string,
	timeout: time.Duration = 300 * time.Second,
) -> Validation_Check {
	r := s.run(
		c.executor,
		args,
		c.root,
		timeout = timeout,
		env = compiler_env(c),
	)
	log := s.join(directory, s.cat(name, ".log"))
	err := s.write(log, s.cat(r.out, r.diagnostic))
	if err != "" {
		return {s.clone_args(args), -1, "fail", log, err}
	}
	return {s.clone_args(args), r.code, r.code == 0 ? "pass" : "fail", log, ""}
}
validation_cli :: proc(c: Context, args: []string) -> (err: string) {
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
	report.recorded_at = fmt.tprintf("%v", time.now())
	version, ev := run(c, []string{"/usr/bin/sw_vers", "-productVersion"})
	if ev != "" {
		return ev
	}
	build, eb := run(c, []string{"/usr/bin/sw_vers", "-buildVersion"})
	if eb != "" {
		return eb
	}
	arch, ea := run(c, []string{"/usr/bin/uname", "-m"}); if ea != "" {
		return ea
	}
	report.actual = {s.trim(version), s.trim(build), s.trim(arch)}
	report.matches_target = report.actual == report.target
	report.head, _ = run(c, []string{"git", "rev-parse", "HEAD"}, c.root)
	report.working_tree, _ = run(
		c,
		[]string{"git", "status", "--porcelain"},
		c.root,
	)
	path := s.join(directory, "report.json")
	defer {
		if err != "" && report.status == "running" {
			report.status = "failed"
		}
		_ = s.write_json(path, report)
		fmt.printf("%s; evidence: %s\n", report.status, path)
	}
	_ = s.write_json(path, report)
	if !o.flags["preflight-only"] {
		tasks := []string {
			"test:compiler",
			"check",
			"test",
			"test:tooling",
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
			_ = s.write_json(path, report)
			if report.checks[task].status != "pass" {
				return s.cat("validation task failed: ", task)
			}
		}
		dev := binary(c, "shoji-dev")
		report.checks["loader-self-test"] = validation_execute(
			c,
			[]string{binary(c, "shoji-loader"), "--self-test"},
			directory,
			"loader-self-test",
		)
		report.checks["bootstrap-relocation"] = validation_execute(
			c,
			[]string {
				dev,
				"check-bootstrap",
				binary(c, "shoji-amd64"),
				binary(c, "shoji-loader"),
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
			verification := verify_archive(
				c,
				s.join(directory, "shoji-validation-macos.tar.gz"),
			)
			report.checks["archive-checksums"] = {
				status = verification == "" ? "pass" : "fail",
				reason = verification,
			}
		}
	}
	for name in RELEASE_BINARIES {
		if s.regular(binary(c, name)) {
			report.artifacts[name], _ = digest(c, binary(c, name))
		}
	}
	report.desktop["inspection"] = validation_execute(
		c,
		[]string{binary(c, "shoji"), "--inspect"},
		directory,
		"inspection",
		15 * time.Second,
	)
	report.desktop["payload"] = validation_execute(
		c,
		[]string{binary(c, "shoji"), "--check-sa"},
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
			append(&command, binary(c, "shoji-dev"), "live", "animation")
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
