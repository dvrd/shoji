package tests

import s "../../../src/support"
import d "../tooling"
import "core:mem"
import "core:os"
import "core:testing"

@(test)
native_cleanup_preserves_runtime_unknown_inputs_and_symlink_targets :: proc(
	t: ^testing.T,
) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	root, _ := s.temp("shoji-clean-test"); defer os.remove_all(root)
	c := d.Context {
		root = root,
	}
	_ = s.mkdir(s.join(root, "bin")); _ = s.mkdir(s.join(root, "artifacts"))
	bytes := [8]u8{0xcf, 0xfa, 0xed, 0xfe, 0, 0, 0, 0}
	macho := string(bytes[:])
	for name in d.CLEAN_KEEP { _ = s.write(d.binary(c, name), macho) }
	_ = s.write(d.binary(c, "shoji-tests"), macho)
	_ = s.mkdir(d.binary(c, "shoji-tests.dSYM"))
	_ = s.write(s.join(d.binary(c, "shoji-tests.dSYM"), "debug"), "symbol")
	for name in ([]string {
			"restore.ipsw",
			"notes.json",
			"shoji-notes.txt",
		}) { _ = s.write(d.binary(c, name), "keep") }
	evidence := s.join(root, "artifacts/report.json")
	_ = s.write(evidence, "evidence")
	_, _ = s.checked(
		{},
		[]string{"/bin/ln", "-s", evidence, d.binary(c, "shoji-link")},
	)
	testing.expect_value(t, d.clean(c, true), "")
	testing.expect(t, s.regular(d.binary(c, "shoji-tests")))
	testing.expect_value(t, d.clean(c, false), "")
	for name in d.CLEAN_KEEP { testing.expect(t, s.regular(d.binary(c, name))) }
	testing.expect(t, !s.exists(d.binary(c, "shoji-tests")))
	for name in ([]string {
			"restore.ipsw",
			"notes.json",
			"shoji-notes.txt",
		}) { testing.expect(t, s.regular(d.binary(c, name))) }
	text, _ := s.read(evidence); testing.expect_value(t, text, "evidence")
	testing.expect(t, s.kind(d.binary(c, "shoji-link")) == .Symlink)
	remaining, err := d.clean_outputs(c); testing.expect_value(t, err, "")
	testing.expect_value(t, len(remaining), 0)
	_ = os.remove_all(s.join(root, "bin"))
	_, _ = s.checked(
		{},
		[]string {
			"/bin/ln",
			"-s",
			s.join(root, "artifacts"),
			s.join(root, "bin"),
		},
	)
	_, err = d.clean_outputs(c); testing.expect(t, err != "")
	testing.expect(t, s.regular(evidence))
}

@(test)
native_release_contains_only_native_binaries_and_verified_manifest :: proc(
	t: ^testing.T,
) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	root, _ := s.temp("shoji-release-test"); defer os.remove_all(root)
	c := d.Context {
		root = root,
	}
	_ = s.mkdir(s.join(root, "bin"))
	for name in d.RELEASE_BINARIES {
		path := d.binary(c, name); _ = s.write(path, name)
		_ = os.chmod(path, {.Read_User, .Write_User, .Execute_User})
	}
	for name in d.RELEASE_DOCUMENTS { _ = s.write(s.join(root, name), name) }
	_, err := d.package_release(
		c,
		s.join(root, "bin"),
		s.join(root, "out"),
		"../escape",
	); testing.expect(t, err != "")
	archive, e := d.package_release(
		c,
		s.join(root, "bin"),
		s.join(root, "out"),
		"0.1.0-test",
	); testing.expect_value(t, e, "")
	testing.expect_value(t, d.verify_archive(c, archive), "")
	_, err = d.package_release(
		c,
		s.join(root, "bin"),
		s.join(root, "out"),
		"0.1.0-test",
	); testing.expect(t, err != "")
	stage := s.join(root, "tamper"); _ = s.mkdir(stage)
	_, _ = s.checked(
		{},
		[]string{"/usr/bin/tar", "-xzf", archive, "-C", stage},
	)
	_ = s.write(s.join(stage, "shoji-0.1.0-test/bin/shoji"), "changed")
	changed := s.join(root, "changed.tar.gz")
	_, _ = s.checked(
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
	testing.expect(t, d.verify_archive(c, changed) != "")
	missing := s.join(root, "missing"); _ = s.mkdir(missing)
	_, err = d.package_release(c, missing, s.join(root, "other"), "valid")
	testing.expect(t, err != "")
}

@(test)
native_abi_normalization_is_idempotent_and_rejects_unknown_binaries :: proc(
	t: ^testing.T,
) {
	bytes: [32]u8
	testing.expect(t, d.normalize_bytes(bytes[:]) != "")
	bytes[0], bytes[1], bytes[2], bytes[3] = 0xcf, 0xfa, 0xed, 0xfe
	bytes[4], bytes[5], bytes[6], bytes[7] = 0x0c, 0, 0, 1
	bytes[8], bytes[9], bytes[10], bytes[11] = 2, 0, 0, 0x81
	testing.expect_value(t, d.normalize_bytes(bytes[:]), "")
	testing.expect_value(t, bytes[11], u8(0x80))
	testing.expect_value(t, d.normalize_bytes(bytes[:]), "")
	testing.expect(t, d.normalize_bytes(bytes[:4]) != "")
	bytes[11] = 0
	testing.expect(t, d.normalize_bytes(bytes[:]) != "")
}
