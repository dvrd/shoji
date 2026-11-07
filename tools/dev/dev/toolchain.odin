package development

import tc "../../common"
import "core:fmt"
import "core:os"
import "core:time"
import support "../../../src/support"

ODIN_REVISION :: "37d8ab08f"
patch_assembly :: proc(c: tc.Context, source: string) -> string {
	stage, err := support.temp("shoji-odin-patch"); if err != "" {
		return err
	}; defer os.remove_all(stage)
	if err = support.mkdir(support.join(stage, "src")); err != "" {
		return err
	}
	files := []string{"src/check_asm.cpp", "src/check_asm_cfg.cpp"}
	for name in files {
		if err = support.copy_file(support.join(stage, name), support.join(source, name)); err != "" {
			return err
		}
	}
	patch := tc.root_file(c, "tools/odin-asm-calls.patch")
	r := support.process_run(c.executor, []string{"git", "apply", "--check", patch}, stage)
	if r.code != 0 {
		if reverse := support.process_run(
			c.executor,
			[]string{"git", "apply", "--reverse", "--check", patch},
			stage,
		); reverse.code != 0 {
			return support.cat("cannot apply assembly-call fix: ", r.diagnostic)
		}
		return ""
	}
	if _, err = tc.run(c, []string{"git", "apply", patch}, stage); err != "" {
		return err
	}
	for name in files {
		if err = support.copy_file(support.join(source, name), support.join(stage, name)); err != "" {
			return err
		}
	}
	return ""
}
prepare_toolchain :: proc(
	c: tc.Context,
	source, destination: string,
) -> string {
	if support.exists(destination) {
		return "refusing to overwrite an existing toolchain"
	}
	if err := support.mkdir(support.join(destination, "..")); err != "" {
		return err
	}
	stage, err := os.make_directory_temp(
		support.join(destination, ".."),
		"odin-*",
		context.allocator,
	); if err != nil {
		return fmt.tprintf("toolchain stage: %v", err)
	}
	defer os.remove_all(stage)
	archive := support.join(stage, "source.tar"); unpack := support.join(stage, "unpacked")
	if e := support.mkdir(unpack); e != "" {
		return e
	}
	if _, e := tc.run(
		c,
		[]string {
			"git",
			"-C",
			source,
			"archive",
			"--output",
			archive,
			ODIN_REVISION,
		},
	); e != "" {
		return e
	}
	if _, e := tc.run(
		c,
		[]string{"/usr/bin/tar", "-xf", archive, "-C", unpack},
	); e != "" {
		return e
	}
	if e := os.rename(unpack, destination); e != nil {
		return fmt.tprintf("cannot install toolchain: %v", e)
	}
	return ""
}
toolchain_cli :: proc(c: tc.Context, args: []string) -> string {
	o, err := support.parse(
		args,
		[]string{"source"},
		[]string{"patch-only", "build-compiler"},
	); if err != "" {
		return err
	}; if len(o.positionals) != 0 {
		return "unexpected toolchain argument"
	}
	destination := tc.library_root(c)
	if !(o.flags["patch-only"] ||
		   o.flags["build-compiler"] && support.kind(destination) == .Directory) {
		source := support.get(o, "source")
		if source == "" {
			text, e := tc.run(c, []string{"odin", "root"}); if e != "" {
				return e
			}; source = support.trim(text)
		}
		if err = prepare_toolchain(c, support.abs(source), destination); err != "" {
			return err
		}
	}
	if err = patch_assembly(c, destination); err != "" {
		return err
	}
	if o.flags["build-compiler"] {
		env := support.environment(
			"CPPFLAGS",
			support.cat(
				os.get_env("CPPFLAGS", context.allocator),
				` -DGIT_SHA="` + ODIN_REVISION + `"`,
			),
		)
		fmt.println("Building pinned Odin compiler…")
		if _, err = tc.run(
			c,
			[]string{"/bin/sh", "build_odin.sh", "release"},
			destination,
			"",
			1800 * time.Second,
			env,
		); err != "" {
			return err
		}
	}
	fmt.println("Pinned toolchain ready:", destination, ODIN_REVISION)
	return ""
}
build_arm64e :: proc(c: tc.Context, args: []string) -> string {
	if len(args) != 1 {
		return "build-arm64e expects an Odin source checkout"
	}
	source := support.real(args[0]); if source == "" {
		return "source checkout is missing"
	}
	for name in ([]string{"src", "base", "core", "vendor", "build_odin.sh"}) {
		if !support.exists(support.join(source, name)) {
			return support.cat("missing source input: ", name)
		}
	}
	stage, err := support.temp("shoji-odin-arm64e"); if err != "" {
		return err
	}; defer os.remove_all(stage)
	if err = tc.copy_tree(c, support.join(stage, "src"), support.join(source, "src"));
	   err != "" {
		return err
	}
	if err = support.copy_file(
		support.join(stage, "build_odin.sh"),
		support.join(source, "build_odin.sh"),
	); err != "" {
		return err
	}
	for name in ([]string{"base", "core", "vendor"}) {
		if _, err = tc.run(
			c,
			[]string {
				"/bin/ln",
				"-s",
				support.join(source, name),
				support.join(stage, name),
			},
		); err != "" {
			return err
		}
	}
	patch := tc.root_file(c, "tools/odin-arm64e.patch")
	for name in ([]string {
			"build_settings.cpp",
			"linker.cpp",
			"llvm_backend_general.cpp",
			"llvm_backend.cpp",
		}) {
		include := support.cat("--include=src/", name)
		r := support.process_run(
			c.executor,
			[]string{"git", "apply", include, "--check", patch},
			stage,
		)
		if r.code == 0 {
			if _, err = tc.run(
				c,
				[]string{"git", "apply", include, patch},
				stage,
			); err != "" {
				return err
			}
		} else {
			if reverse := support.process_run(
				c.executor,
				[]string {
					"git",
					"apply",
					include,
					"--reverse",
					"--check",
					patch,
				},
				stage,
			); reverse.code != 0 {
				return support.cat(
					"cannot apply arm64e patch to ",
					name,
					": ",
					r.diagnostic,
				)
			}
		}
	}
	if err = patch_assembly(c, stage); err != "" {
		return err
	}
	fmt.println("Building isolated arm64e compiler…")
	if _, err = tc.run(
		c,
		[]string{"/bin/sh", "build_odin.sh", "release"},
		stage,
		"",
		1800 * time.Second,
	); err != "" {
		return err
	}
	if err = support.mkdir(tc.root_file(c, "bin")); err != "" {
		return err
	}
	return support.copy_file(tc.binary(c, "odin-arm64e"), support.join(stage, "odin"))
}
