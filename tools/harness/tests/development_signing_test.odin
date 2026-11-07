package tests

import tc "../../common"
import d "../../dev/dev"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import support "../../../src/support"

@(test)
native_signing_uses_stable_requirement_and_preserves_binary_on_failure :: proc(
	t: ^testing.T,
) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	root, _ := support.temp("shoji-signing-test"); defer os.remove_all(root)
	identity := "ABABABABABABABABABABABABABABABABABABABAB"
	keychain := support.join(root, "keychain"); _ = support.write(keychain, "")
	r := Tool_Recorder {
		identity = identity,
	}; c := tool_context(root, &r)
	config := d.Signing_Config {
		identity = identity,
		keychain = keychain,
	}
	testing.expect_value(t, d.signing_check(c, config), "")
	installed, candidate := support.join(root, "shoji"), support.join(root, "shoji.new")
	_ = support.write(installed, "working"); _ = support.write(candidate, "new")
	r.fail_verify = true
	testing.expect(t, d.sign(c, candidate, config, install = installed) != "")
	original, _ := support.read(installed)
	testing.expect_value(t, original, "working")
	testing.expect(t, support.regular(candidate))
	r.fail_verify = false
	testing.expect_value(
		t,
		d.sign(c, candidate, config, install = installed),
		"",
	)
	current, _ := support.read(installed); testing.expect_value(t, current, "new")
	testing.expect(t, !support.exists(candidate))
	requirement := d.signing_requirement(d.SIGNING_IDENTIFIER, identity)
	testing.expect(
		t,
		strings.contains(requirement, "certificate leaf") &&
		!strings.contains(requirement, "cdhash"),
	)
	found := false
	for call in r.calls {
		for arg in call.args {
			if arg == support.cat("=designated => ", requirement) {
				found = true
			}
		}
	}
	testing.expect(t, found)
	_, err := support.checked(
		{},
		[]string {
			"/usr/bin/csreq",
			"-r",
			support.cat("=", requirement),
			"-b",
			support.join(root, "requirement.bin"),
		},
	); testing.expect_value(t, err, "")
	_ = support.write(candidate, "candidate")
	testing.expect(t, d.sign(c, candidate, config, install = candidate) != "")
	link := support.join(root, "link")
	_, _ = support.checked({}, []string{"/bin/ln", "-s", candidate, link})
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
	root, _ := support.temp("shoji-signing-config-test"); defer os.remove_all(root)
	r := Tool_Recorder {
		identity = "ABABABABABABABABABABABABABABABABABABABAB",
	}; c := tool_context(root, &r)
	keychain := support.join(root, "keychain"); _ = support.write(keychain, "")
	path := support.join(root, "signing.json")
	// Explicit missing/malformed/unavailable configurations must fail even when
	// a different configured identity exists on the test host.
	{
		_, err := d.read_signing_config(c, path); testing.expect(t, err != "")
		_ = support.write_json(
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
	candidate := support.join(root, "adhoc")
	testing.expect_value(t, support.copy_file(candidate, "/usr/bin/true"), "")
	testing.expect_value(
		t,
		d.sign(tc.Context{root = root}, candidate, {adhoc = true}),
		"",
	)
}
