package tests

import i "../../inspector/inspect"
import tc "../../common"
import d "../../dev/dev"
import "core:mem"
import "core:os"
import "core:testing"
import support "../../../src/support"

@(test)
native_cleanup_recognizes_generated_directories_and_preserves_mixed_inputs :: proc(
	t: ^testing.T,
) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	root, _ := support.temp("shoji-output-policy-test"); defer os.remove_all(root)
	c := tc.Context {
		root = root,
	}
	bytes := [4]u8{0xcf, 0xfa, 0xed, 0xfe}
	for folder in ([]string{"universal", "macos27", "transaction-fix"}) {
		path := tc.binary(c, folder); _ = support.mkdir(path)
		_ = support.write(support.join(path, "shoji-sa.dylib"), string(bytes[:]))
	}
	for name in ([]string {
			"shoji",
			"shoji-loader",
			"dev",
		}) { _ = support.write(tc.binary(c, support.cat("universal/", name)), string(bytes[:])) }
	evidence := tc.binary(c, "transaction-fix/notes.json")
	_ = support.write(evidence, "retained evidence")
	testing.expect_value(t, d.clean(c, true), "")
	testing.expect(t, support.exists(tc.binary(c, "universal")))
	testing.expect_value(t, d.clean(c, false), "")
	testing.expect(t, !support.exists(tc.binary(c, "universal")))
	testing.expect(t, !support.exists(tc.binary(c, "macos27")))
	testing.expect(t, support.regular(evidence))
	testing.expect(t, support.regular(tc.binary(c, "transaction-fix/shoji-sa.dylib")))
	_ = support.mkdir(tc.binary(c, "universal"))
	_, _ = support.checked(
		{},
		[]string{"/bin/ln", "-s", evidence, tc.binary(c, "universal/shoji")},
	)
	testing.expect_value(t, d.clean(c, false), "")
	testing.expect(t, support.kind(tc.binary(c, "universal/shoji")) == .Symlink)
	testing.expect(t, support.regular(evidence))
	_ = os.remove(tc.binary(c, "universal/shoji"))
	_ = support.write(tc.binary(c, "universal/shoji"), "unknown nonbinary input")
	testing.expect_value(t, d.clean(c, false), "")
	testing.expect(t, support.regular(tc.binary(c, "universal/shoji")))
}

@(test)
native_cleanup_preserves_runtime_unknown_inputs_and_symlink_targets :: proc(
	t: ^testing.T,
) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	root, _ := support.temp("shoji-clean-test"); defer os.remove_all(root)
	c := tc.Context {
		root = root,
	}
	_ = support.mkdir(support.join(root, "bin")); _ = support.mkdir(support.join(root, "artifacts"))
	bytes := [8]u8{0xcf, 0xfa, 0xed, 0xfe, 0, 0, 0, 0}
	macho := string(bytes[:])
	for name in d.CLEAN_KEEP { _ = support.write(tc.binary(c, name), macho) }
	_ = support.write(tc.binary(c, "shoji-tests"), macho)
	_ = support.write(tc.binary(c, "harness-fixture"), macho)
	_ = support.write(tc.binary(c, "harness-personal"), macho)
	_ = support.mkdir(tc.binary(c, "shoji-tests.dSYM"))
	_ = support.write(support.join(tc.binary(c, "shoji-tests.dSYM"), "debug"), "symbol")
	for name in ([]string {
			"restore.ipsw",
			"notes.json",
			"shoji-notes.txt",
		}) { _ = support.write(tc.binary(c, name), "keep") }
	evidence := support.join(root, "artifacts/report.json")
	_ = support.write(evidence, "evidence")
	_, _ = support.checked(
		{},
		[]string{"/bin/ln", "-s", evidence, tc.binary(c, "shoji-link")},
	)
	testing.expect_value(t, d.clean(c, true), "")
	testing.expect(t, support.regular(tc.binary(c, "shoji-tests")))
	testing.expect_value(t, d.clean(c, false), "")
	for name in d.CLEAN_KEEP { testing.expect(t, support.regular(tc.binary(c, name))) }
	testing.expect(t, !support.exists(tc.binary(c, "shoji-tests")))
	testing.expect(t, !support.exists(tc.binary(c, "harness-fixture")))
	testing.expect(t, support.regular(tc.binary(c, "harness-personal")))
	for name in ([]string {
			"restore.ipsw",
			"notes.json",
			"shoji-notes.txt",
		}) { testing.expect(t, support.regular(tc.binary(c, name))) }
	text, _ := support.read(evidence); testing.expect_value(t, text, "evidence")
	testing.expect(t, support.kind(tc.binary(c, "shoji-link")) == .Symlink)
	remaining, err := d.clean_outputs(c); testing.expect_value(t, err, "")
	testing.expect_value(t, len(remaining), 0)
	_ = os.remove_all(support.join(root, "bin"))
	_, _ = support.checked(
		{},
		[]string {
			"/bin/ln",
			"-s",
			support.join(root, "artifacts"),
			support.join(root, "bin"),
		},
	)
	_, err = d.clean_outputs(c); testing.expect(t, err != "")
	testing.expect(t, support.regular(evidence))
}

@(test)
native_release_contains_only_native_binaries_and_verified_manifest :: proc(
	t: ^testing.T,
) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	root, _ := support.temp("shoji-release-test"); defer os.remove_all(root)
	c := tc.Context {
		root = root,
	}
	_ = support.mkdir(support.join(root, "bin"))
	for name in tc.RELEASE_BINARIES {
		path := tc.binary(c, name); _ = support.write(path, name)
		_ = os.chmod(path, {.Read_User, .Write_User, .Execute_User})
	}
	for name in tc.RELEASE_DOCUMENTS { _ = support.write(support.join(root, name), name) }
	_, err := d.package_release(
		c,
		support.join(root, "bin"),
		support.join(root, "out"),
		"../escape",
	); testing.expect(t, err != "")
	archive, e := d.package_release(
		c,
		support.join(root, "bin"),
		support.join(root, "out"),
		"0.1.0-test",
	); testing.expect_value(t, e, "")
	testing.expect_value(t, i.verify_archive(c, archive), "")
	_, err = d.package_release(
		c,
		support.join(root, "bin"),
		support.join(root, "out"),
		"0.1.0-test",
	); testing.expect(t, err != "")
	stage := support.join(root, "tamper"); _ = support.mkdir(stage)
	_, _ = support.checked(
		{},
		[]string{"/usr/bin/tar", "-xzf", archive, "-C", stage},
	)
	_ = support.write(support.join(stage, "shoji-0.1.0-test/bin/shoji"), "changed")
	changed := support.join(root, "changed.tar.gz")
	_, _ = support.checked(
		{},
		[]string {
			"/usr/bin/tar",
			"-czf",
			changed,
			"-C",
			stage,
			"shoji-0.1.0-test",
		},
	)
	testing.expect(t, i.verify_archive(c, changed) != "")
	missing := support.join(root, "missing"); _ = support.mkdir(missing)
	_, err = d.package_release(c, missing, support.join(root, "other"), "valid")
	testing.expect(t, err != "")
}

@(test)
native_abi_normalization_is_idempotent_and_rejects_unknown_binaries :: proc(
	t: ^testing.T,
) {
	bytes: [32]u8
	testing.expect(t, i.normalize_bytes(bytes[:]) != "")
	bytes[0], bytes[1], bytes[2], bytes[3] = 0xcf, 0xfa, 0xed, 0xfe
	bytes[4], bytes[5], bytes[6], bytes[7] = 0x0c, 0, 0, 1
	bytes[8], bytes[9], bytes[10], bytes[11] = 2, 0, 0, 0x81
	testing.expect_value(t, i.normalize_bytes(bytes[:]), "")
	testing.expect_value(t, bytes[11], u8(0x80))
	testing.expect_value(t, i.normalize_bytes(bytes[:]), "")
	testing.expect(t, i.normalize_bytes(bytes[:4]) != "")
	bytes[11] = 0
	testing.expect(t, i.normalize_bytes(bytes[:]) != "")
}
