package tests

import s "../../../src"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

permission_trusted :: proc() -> bool { return true }
permission_missing :: proc() -> bool { return false }
permission_granted :: proc(_: s.Service_Manager) -> bool { return true }
permission_denied :: proc(_: s.Service_Manager) -> bool { return false }
permission_no_delay :: proc() {}

@(test)
service_permission_timeout_choice :: proc(t: ^testing.T) {
	testing.expect_value(t, s.accessibility_choice(""), s.Permission_Choice.Wait)
	testing.expect_value(t, s.accessibility_choice("  YES\n"), s.Permission_Choice.Wait)
	testing.expect_value(t, s.accessibility_choice("wait\n"), s.Permission_Choice.Wait)
	testing.expect_value(t, s.accessibility_choice("n\n"), s.Permission_Choice.Stop)
	testing.expect_value(t, s.accessibility_choice("stop\n"), s.Permission_Choice.Stop)
	testing.expect_value(t, s.accessibility_choice("maybe\n"), s.Permission_Choice.Invalid)
	testing.expect(t, s.accessibility_countdown(3, permission_trusted, permission_no_delay))
	testing.expect(t, !s.accessibility_countdown(3, permission_missing, permission_no_delay))
}

@(test)
service_checks_permission_for_the_service_executable :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	root, _ := s.temp("shoji-service-permission"); defer os.remove_all(root)
	r: Tool_Recorder; c := tool_context(root, &r)
	m := s.Service_Manager{root, 501, c.executor}
	exe := s.join(root, "shoji"); _ = s.write(exe, "fixture")
	_ = os.chmod(exe, {.Read_User, .Write_User, .Execute_User})
	other := s.join(root, "other"); _ = s.write(other, "fixture")
	_ = os.chmod(other, {.Read_User, .Write_User, .Execute_User})
	testing.expect_value(t, s.service_accessibility(m, exe, exe, permission_trusted, permission_denied), "")
	testing.expect_value(t, s.service_accessibility(m, exe, exe, permission_missing, permission_granted), "")
	testing.expect(t, s.service_accessibility(m, exe, exe, permission_missing, permission_denied) != "")
	testing.expect(t, s.service_accessibility(m, exe, other, permission_trusted, permission_granted) != "")
	testing.expect_value(t, s.install(m, other), "")
	testing.expect(t, s.service_accessibility(m, exe, exe, permission_trusted, permission_granted) != "")
	testing.expect_value(t, s.service_accessibility(m, other, exe, permission_trusted, permission_denied), "")
	r.loaded = true
	testing.expect(t, s.service_accessibility(m, other, exe, permission_missing, permission_denied) != "")
	testing.expect(t, !r.loaded)
}

@(test)
native_service_first_start_installs_and_preserves_configuration :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	root, _ := s.temp("shoji-service-first-start"); defer os.remove_all(root)
	r: Tool_Recorder; c := tool_context(root, &r)
	m := s.Service_Manager{root, 501, c.executor}
	exe := s.join(root, "shoji"); _ = s.write(exe, "fixture")
	_ = os.chmod(exe, {.Read_User, .Write_User, .Execute_User})
	testing.expect_value(t, s.service_start_configured(m, exe, "", ""), "")
	testing.expect(t, r.loaded)
	before, _ := s.read(s.plist_path(m))
	testing.expect(t, strings.contains(before, exe))
	testing.expect_value(t, s.stop(m), "")
	testing.expect_value(t, s.service_start_configured(m, "invalid", "", ""), "")
	after, _ := s.read(s.plist_path(m))
	testing.expect_value(t, after, before)
	testing.expect_value(t, s.uninstall(m), "")
	payload := s.join(root, "shoji-sa.dylib"); _ = s.write(payload, "payload")
	testing.expect_value(t, s.service_start_configured(m, exe, "", payload), "")
	with_payload, _ := s.read(s.plist_path(m))
	testing.expect(t, strings.contains(with_payload, "--sa"))
	testing.expect(t, strings.contains(with_payload, payload))
}

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
	testing.expect(t, s.service_start_configured(m, exe, "", "") != "")
	testing.expect(t, s.uninstall(m) != "")
	testing.expect(t, s.install(m, exe) != "")
	testing.expect(t, s.exists(s.plist_path(m)))
	_ = os.remove(s.plist_path(m))
	_, e = s.checked({}, []string{"/bin/ln", "-s", exe, s.plist_path(m)})
	testing.expect_value(t, e, "")
	testing.expect(t, s.service_start(m) != "")
	testing.expect(t, s.service_start_configured(m, exe, "", "") != "")
	testing.expect(t, s.uninstall(m) != "")
	testing.expect(t, s.regular(exe))
}
