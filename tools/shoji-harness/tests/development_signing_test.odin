package tests

import tc "../../common"
import s "../../../src/support"
import d "../../shoji-dev/dev"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
native_signing_uses_stable_requirement_and_preserves_binary_on_failure :: proc(
	t: ^testing.T,
) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	root, _ := s.temp("shoji-signing-test"); defer os.remove_all(root)
	identity := "ABABABABABABABABABABABABABABABABABABABAB"
	keychain := s.join(root, "keychain"); _ = s.write(keychain, "")
	r := Tool_Recorder {
		identity = identity,
	}; c := tool_context(root, &r)
	config := d.Signing_Config {
		identity = identity,
		keychain = keychain,
	}
	testing.expect_value(t, d.signing_check(c, config), "")
	installed, candidate := s.join(root, "shoji"), s.join(root, "shoji.new")
	_ = s.write(installed, "working"); _ = s.write(candidate, "new")
	r.fail_verify = true
	testing.expect(t, d.sign(c, candidate, config, install = installed) != "")
	original, _ := s.read(installed)
	testing.expect_value(t, original, "working")
	testing.expect(t, s.regular(candidate))
	r.fail_verify = false
	testing.expect_value(
		t,
		d.sign(c, candidate, config, install = installed),
		"",
	)
	current, _ := s.read(installed); testing.expect_value(t, current, "new")
	testing.expect(t, !s.exists(candidate))
	requirement := d.signing_requirement(d.SIGNING_IDENTIFIER, identity)
	testing.expect(
		t,
		strings.contains(requirement, "certificate leaf") &&
		!strings.contains(requirement, "cdhash"),
	)
	found := false
	for call in r.calls {
		for arg in call.args {
			if arg == s.cat("=designated => ", requirement) {
				found = true
			}
		}
	}
	testing.expect(t, found)
	_, err := s.checked(
		{},
		[]string {
			"/usr/bin/csreq",
			"-r",
			s.cat("=", requirement),
			"-b",
			s.join(root, "requirement.bin"),
		},
	); testing.expect_value(t, err, "")
	_ = s.write(candidate, "candidate")
	testing.expect(t, d.sign(c, candidate, config, install = candidate) != "")
	link := s.join(root, "link")
	_, _ = s.checked({}, []string{"/bin/ln", "-s", candidate, link})
	testing.expect(t, d.sign(c, link, config, install = installed) != "")
	testing.expect(t, d.sign(c, candidate, config, install = link) != "")
}

@(test)
native_signing_reuses_configuration_and_never_silently_downgrades :: proc(
	t: ^testing.T,
) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	root, _ := s.temp("shoji-signing-config-test"); defer os.remove_all(root)
	r := Tool_Recorder {
		identity = "ABABABABABABABABABABABABABABABABABABABAB",
	}; c := tool_context(root, &r)
	keychain := s.join(root, "keychain"); _ = s.write(keychain, "")
	path := s.join(root, "signing.json")
	// Explicit missing/malformed/unavailable configurations must fail even when
	// a different configured identity exists on the test host.
	{
		_, err := d.read_signing_config(c, path); testing.expect(t, err != "")
		_ = s.write_json(
			path,
			d.Signing_Disk_Config{identity = r.identity, keychain = keychain},
		)
		testing.expect_value(t, d.signing_setup(c, path, "", ""), "")
		testing.expect_value(t, len(r.calls), 1)
		r.identity = "0 valid identities found"
		_, err = d.read_signing_config(c, path)
		testing.expect(t, strings.contains(err, "Refusing to fall back"))
	}
	adhoc, err := d.signing_load(c, path, true)
	testing.expect_value(t, err, ""); testing.expect(t, adhoc.adhoc)
	candidate := s.join(root, "adhoc")
	testing.expect_value(t, s.copy(candidate, "/usr/bin/true"), "")
	testing.expect_value(
		t,
		d.sign(tc.Context{root = root}, candidate, {adhoc = true}),
		"",
	)
}
