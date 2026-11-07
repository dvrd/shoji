package tests

import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import support "../../../src/support"
import service "../../../src/service"

permission_trusted :: proc() -> bool { return true }
permission_missing :: proc() -> bool { return false }
permission_granted :: proc(_: service.Service_Manager) -> bool { return true }
permission_denied :: proc(_: service.Service_Manager) -> bool { return false }
permission_no_delay :: proc() {}

@(test)
service_permission_timeout_choice :: proc(t: ^testing.T) {
	testing.expect_value(t, service.accessibility_choice(""), service.Permission_Choice.Wait)
	testing.expect_value(t, service.accessibility_choice("  YES\n"), service.Permission_Choice.Wait)
	testing.expect_value(t, service.accessibility_choice("wait\n"), service.Permission_Choice.Wait)
	testing.expect_value(t, service.accessibility_choice("n\n"), service.Permission_Choice.Stop)
	testing.expect_value(t, service.accessibility_choice("stop\n"), service.Permission_Choice.Stop)
	testing.expect_value(t, service.accessibility_choice("maybe\n"), service.Permission_Choice.Invalid)
	testing.expect(t, service.accessibility_countdown(3, permission_trusted, permission_no_delay))
	testing.expect(t, !service.accessibility_countdown(3, permission_missing, permission_no_delay))
}

@(test)
service_checks_permission_for_the_service_executable :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	root, _ := support.temp("shoji-service-permission"); defer os.remove_all(root)
	r: Tool_Recorder; c := tool_context(root, &r)
	m := service.Service_Manager{root, 501, c.executor}
	exe := support.join(root, "shoji"); _ = support.write(exe, "fixture")
	_ = os.chmod(exe, {.Read_User, .Write_User, .Execute_User})
	other := support.join(root, "other"); _ = support.write(other, "fixture")
	_ = os.chmod(other, {.Read_User, .Write_User, .Execute_User})
	testing.expect_value(t, service.service_accessibility(m, exe, exe, permission_trusted, permission_denied), "")
	testing.expect_value(t, service.service_accessibility(m, exe, exe, permission_missing, permission_granted), "")
	testing.expect(t, service.service_accessibility(m, exe, exe, permission_missing, permission_denied) != "")
	testing.expect(t, service.service_accessibility(m, exe, other, permission_trusted, permission_granted) != "")
	testing.expect_value(t, service.install(m, other), "")
	testing.expect(t, service.service_accessibility(m, exe, exe, permission_trusted, permission_granted) != "")
	testing.expect_value(t, service.service_accessibility(m, other, exe, permission_trusted, permission_denied), "")
	r.loaded = true
	testing.expect(t, service.service_accessibility(m, other, exe, permission_missing, permission_denied) != "")
	testing.expect(t, !r.loaded)
}

@(test)
native_service_first_start_installs_and_preserves_configuration :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	root, _ := support.temp("shoji-service-first-start"); defer os.remove_all(root)
	r: Tool_Recorder; c := tool_context(root, &r)
	m := service.Service_Manager{root, 501, c.executor}
	exe := support.join(root, "shoji"); _ = support.write(exe, "fixture")
	_ = os.chmod(exe, {.Read_User, .Write_User, .Execute_User})
	testing.expect_value(t, service.service_start_configured(m, exe, "", false), "")
	testing.expect(t, r.loaded)
	before, _ := support.read(service.plist_path(m))
	testing.expect(t, strings.contains(before, exe))
	testing.expect_value(t, service.stop(m), "")
	testing.expect_value(t, service.service_start_configured(m, "invalid", "", false), "")
	after, _ := support.read(service.plist_path(m))
	testing.expect_value(t, after, before)
	testing.expect_value(t, service.uninstall(m), "")
	testing.expect_value(t, service.service_start_configured(m, exe, "", true), "")
	with_payload, _ := support.read(service.plist_path(m))
	// The daemon resolves the payload beside its binary; no path is recorded.
	testing.expect(t, strings.contains(with_payload, "<string>--sa</string></array>"))
}

@(test)
native_service_lifecycle_preserves_literal_paths_and_launchd_configuration :: proc(
	t: ^testing.T,
) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	root, err := support.temp("shoji-service-test"); testing.expect_value(t, err, "")
	defer os.remove_all(root)
	r: Tool_Recorder; c := tool_context(root, &r)
	m := service.Service_Manager{root, 501, c.executor}
	exe := support.join(root, "shoji $(touch never) & <app>")
	config := support.join(root, "config $(touch never)")
	testing.expect_value(t, support.write(exe, "fixture"), "")
	_ = os.chmod(exe, {.Read_User, .Write_User, .Execute_User})
	_ = support.write(config, "")
	testing.expect_value(t, service.install(m, exe, config, true), "")
	testing.expect(t, !r.loaded)
	xml, _ := support.read(service.plist_path(m))
	testing.expect(t, strings.contains(xml, "&amp; &lt;app&gt;"))
	args, e := support.checked(
		{},
		[]string {
			"/usr/bin/plutil",
			"-extract",
			"ProgramArguments",
			"json",
			"-o",
			"-",
			service.plist_path(m),
		},
	)
	testing.expect_value(t, e, "")
	testing.expect(t, strings.contains(args, "$(touch never)"))
	testing.expect(t, !support.exists(support.join(root, "never")))
	testing.expect_value(t, service.service_start(m), ""); testing.expect(t, r.loaded)
	testing.expect(t, service.install(m, exe) != "")
	testing.expect_value(t, service.restart(m), "")
	kickstart := false; for call in r.calls {
		if len(call.args) > 2 &&
		   call.args[1] == "kickstart" &&
		   call.args[2] == "-k" {
			kickstart = true
		}
	}
	testing.expect(t, kickstart)
	testing.expect_value(t, service.uninstall(m), "")
	testing.expect(t, !r.loaded && !support.exists(service.plist_path(m)))
	testing.expect(t, service.service_start(m) != "")
}

@(test)
native_service_refuses_foreign_plists_symlinks_and_invalid_inputs :: proc(
	t: ^testing.T,
) {
	arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	context.temp_allocator = context.allocator
	root, _ := support.temp("shoji-service-guard-test"); defer os.remove_all(root)
	r: Tool_Recorder; c := tool_context(root, &r)
	m := service.Service_Manager{root, 501, c.executor}
	exe := support.join(root, "shoji"); _ = support.write(exe, "fixture")
	_ = os.chmod(exe, {.Read_User, .Write_User, .Execute_User})
	_, e := service.configuration(exe, root, root); testing.expect(t, e != "")
	_ = support.mkdir(support.join(root, "Library/LaunchAgents"))
	_ = support.write(
		service.plist_path(m),
		`<?xml version="1.0"?><plist version="1.0"><dict><key>Label</key><string>somebody-else</string></dict></plist>`,
	)
	testing.expect(t, service.service_start(m) != "")
	testing.expect(t, service.service_start_configured(m, exe, "", false) != "")
	testing.expect(t, service.uninstall(m) != "")
	testing.expect(t, service.install(m, exe) != "")
	testing.expect(t, support.exists(service.plist_path(m)))
	_ = os.remove(service.plist_path(m))
	_, e = support.checked({}, []string{"/bin/ln", "-s", exe, service.plist_path(m)})
	testing.expect_value(t, e, "")
	testing.expect(t, service.service_start(m) != "")
	testing.expect(t, service.service_start_configured(m, exe, "", false) != "")
	testing.expect(t, service.uninstall(m) != "")
	testing.expect(t, support.regular(exe))
}
