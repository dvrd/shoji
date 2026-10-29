package tests

import s "../../../src"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
native_service_lifecycle_preserves_literal_paths_and_launchd_configuration :: proc(
	t: ^testing.T,
) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	root, err := s.temp("shoji-service-test"); testing.expect_value(t, err, "")
	defer os.remove_all(root)
	r: Tool_Recorder; c := tool_context(root, &r)
	m := s.Service_Manager{root, 501, c.executor}
	exe := s.join(root, "shoji $(touch never) & <app>")
	payload := s.join(root, "payload $(touch never).dylib")
	config := s.join(root, "config")
	testing.expect_value(t, s.write(exe, "fixture"), "")
	_ = os.chmod(exe, {.Read_User, .Write_User, .Execute_User})
	_ = s.write(payload, "payload"); _ = s.write(config, "")
	testing.expect_value(t, s.install(m, exe, config, payload), "")
	testing.expect(t, !r.loaded)
	xml, _ := s.read(s.plist_path(m))
	testing.expect(t, strings.contains(xml, "&amp; &lt;app&gt;"))
	args, e := s.checked(
		{},
		[]string {
			"/usr/bin/plutil",
			"-extract",
			"ProgramArguments",
			"json",
			"-o",
			"-",
			s.plist_path(m),
		},
	)
	testing.expect_value(t, e, "")
	testing.expect(t, strings.contains(args, "$(touch never)"))
	testing.expect(t, !s.exists(s.join(root, "never")))
	testing.expect_value(t, s.service_start(m), ""); testing.expect(t, r.loaded)
	testing.expect(t, s.install(m, exe) != "")
	testing.expect_value(t, s.restart(m), "")
	kickstart := false; for call in r.calls {
		if len(call.args) > 2 &&
		   call.args[1] == "kickstart" &&
		   call.args[2] == "-k" {
			kickstart = true
		}
	}
	testing.expect(t, kickstart)
	testing.expect_value(t, s.uninstall(m), "")
	testing.expect(t, !r.loaded && !s.exists(s.plist_path(m)))
	testing.expect(t, s.service_start(m) != "")
}

@(test)
native_service_refuses_foreign_plists_symlinks_and_invalid_inputs :: proc(
	t: ^testing.T,
) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	root, _ := s.temp("shoji-service-guard-test"); defer os.remove_all(root)
	r: Tool_Recorder; c := tool_context(root, &r)
	m := s.Service_Manager{root, 501, c.executor}
	exe := s.join(root, "shoji"); _ = s.write(exe, "fixture")
	_ = os.chmod(exe, {.Read_User, .Write_User, .Execute_User})
	_, e := s.configuration(exe, root, root); testing.expect(t, e != "")
	_, e = s.configuration(exe, root, "", root)
	testing.expect(t, e != "")
	_ = s.mkdir(s.join(root, "Library/LaunchAgents"))
	_ = s.write(
		s.plist_path(m),
		`<?xml version="1.0"?><plist version="1.0"><dict><key>Label</key><string>somebody-else</string></dict></plist>`,
	)
	testing.expect(t, s.service_start(m) != "")
	testing.expect(t, s.uninstall(m) != "")
	testing.expect(t, s.install(m, exe) != "")
	testing.expect(t, s.exists(s.plist_path(m)))
	_ = os.remove(s.plist_path(m))
	_, e = s.checked({}, []string{"/bin/ln", "-s", exe, s.plist_path(m)})
	testing.expect_value(t, e, "")
	testing.expect(t, s.service_start(m) != "")
	testing.expect(t, s.uninstall(m) != "")
	testing.expect(t, s.regular(exe))
}
