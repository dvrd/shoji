package development

import tc "../../common"
import "core:fmt"
import "core:os"
import "core:time"
import support "../../../src/support"

ODIN_REVISION :: "37d8ab08f"
ODIN_REMOTE :: "https://github.com/odin-lang/Odin.git"
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
// A directory that contains ODIN_REVISION. An ordinary library root does not.
has_revision :: proc(c: tc.Context, source: string) -> bool {
	if source == "" {return false}
	_, err := tc.run(
		c,
		[]string{"git", "-C", source, "cat-file", "-e", ODIN_REVISION + "^{commit}"},
	)
	return err == ""
}
// Puts the pinned commit into an empty directory. A local git checkout that
// already has it is archived from there. Otherwise the commit is fetched.
// src and vendor exist only inside this directory; the caller deletes it.
fetch_revision :: proc(c: tc.Context, into, source: string) -> string {
	if err := support.mkdir(into); err != "" {return err}
	if has_revision(c, source) {
		archive := support.join(into, "source.tar")
		if _, e := tc.run(
			c,
			[]string{"git", "-C", source, "archive", "--output", archive, ODIN_REVISION},
		); e != "" {
			return e
		}
		if _, e := tc.run(c, []string{"/usr/bin/tar", "-xf", archive, "-C", into}); e != "" {
			return e
		}
		os.remove(archive)
		return ""
	}
	fmt.println("Fetching Odin", ODIN_REVISION)
	if _, e := tc.run(c, []string{"git", "init", "-q"}, into); e != "" {return e}
	if _, e := tc.run(
		c,
		[]string{"git", "-C", into, "remote", "add", "origin", ODIN_REMOTE},
	); e != "" {
		return e
	}
	if _, e := tc.run(
		c,
		[]string{"git", "-C", into, "fetch", "--depth", "1", "origin", ODIN_REVISION},
		"",
		"",
		1800 * time.Second,
	); e != "" {
		return e
	}
	_, e := tc.run(c, []string{"git", "-C", into, "checkout", "--detach", "--quiet", "FETCH_HEAD"})
	return e
}
// The running compiler reads core and base. src and vendor are build inputs.
install_libraries :: proc(c: tc.Context, from, destination: string) -> string {
	if err := support.mkdir(destination); err != "" {return err}
	for name in ([]string{"core", "base"}) {
		dst := support.join(destination, name)
		if support.exists(dst) {continue}
		if err := tc.copy_tree(c, dst, support.join(from, name)); err != "" {return err}
	}
	return ""
}
install_compiler :: proc(c: tc.Context, from, destination: string) -> string {
	if err := support.mkdir(destination); err != "" {return err}
	if err := support.copy_file(
		support.join(destination, "odin"),
		support.join(from, "odin"),
	); err != "" {
		return err
	}
	lib := support.join(destination, "lib")
	if support.exists(lib) {return ""}
	return tc.copy_tree(c, lib, support.join(from, "lib"))
}
// src is the compiler's own code. vendor's packages are unused. The compiler
// still requires a vendor directory to exist, so an empty one is put back.
discard_sources :: proc(destination: string) -> string {
	for name in ([]string{"src", "vendor"}) {
		path := support.join(destination, name)
		if !support.exists(path) {continue}
		if err := os.remove_all(path); err != nil {
			return fmt.tprintf("cannot remove %s: %v", path, err)
		}
	}
	return support.mkdir(support.join(destination, "vendor"))
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
	if o.flags["patch-only"] {
		if !support.exists(support.join(destination, "src")) {
			return "compiler sources are fetched at build time; pass --build-compiler"
		}
		if err = patch_assembly(c, destination); err != "" {return err}
		fmt.println("Pinned toolchain patched:", destination, ODIN_REVISION)
		return ""
	}
	need_libraries := !support.exists(support.join(destination, "core")) ||
		!support.exists(support.join(destination, "base"))
	if o.flags["build-compiler"] || need_libraries {
		stage, e := support.temp("shoji-odin"); if e != "" {return e}
		defer os.remove_all(stage)
		raw := support.get(o, "source")
		source := raw == "" ? "" : support.abs(raw)
		if err = fetch_revision(c, stage, source); err != "" {return err}
		if err = patch_assembly(c, stage); err != "" {return err}
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
				stage,
				"",
				1800 * time.Second,
				env,
			); err != "" {
				return err
			}
			if err = install_compiler(c, stage, destination); err != "" {return err}
		}
		if err = install_libraries(c, stage, destination); err != "" {return err}
	}
	if err = discard_sources(destination); err != "" {return err}
	fmt.println("Pinned toolchain ready:", destination, ODIN_REVISION)
	return ""
}
build_arm64e :: proc(c: tc.Context, args: []string) -> string {
	if len(args) > 1 {return "build-arm64e accepts one optional source checkout"}
	source := ""
	if len(args) == 1 {
		source = support.real(args[0]); if source == "" {return "source checkout is missing"}
	}
	stage, err := support.temp("shoji-odin-arm64e"); if err != "" {
		return err
	}; defer os.remove_all(stage)
	if err = fetch_revision(c, stage, source); err != "" {return err}
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
