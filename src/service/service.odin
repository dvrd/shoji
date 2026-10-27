package service

import s "../support"
import "core:fmt"
import "core:os"
import "core:strings"

LABEL :: "tech.shoji.window-manager"
Manager :: struct {
	home: string,
	uid: int,
	executor: s.Executor,
}
plist_path :: proc(m: Manager) -> string {
	return s.join(m.home, "Library/LaunchAgents/" + LABEL + ".plist")
}
logs_path :: proc(m: Manager) -> string {
	return s.join(m.home, "Library/Logs/shoji")
}
target :: proc(m: Manager) -> string {
	return fmt.tprintf("gui/%d/%s", m.uid, LABEL)
}
launch :: proc(m: Manager, args: ..string) -> s.Result {
	cmd := make([dynamic]string); append(&cmd, "/bin/launchctl")
	append(&cmd, ..args); return s.run(m.executor, cmd[:])
}
loaded :: proc(m: Manager) -> bool {
	return launch(m, "print", target(m)).code == 0
}
escape :: proc(value: string) -> string {
	result := strings.builder_make(context.allocator)
	for c in value {
		switch
		c {case '&':
			strings.write_string(&result, "&amp;"); case '<':
			strings.write_string(&result, "&lt;"); case '>':
			strings.write_string(&result, "&gt;"); case '"':
			strings.write_string(&result, "&quot;"); case '\'':
			strings.write_string(&result, "&apos;"); case:
			strings.write_rune(&result, c)
		}
	}
	return strings.to_string(result)
}
configuration :: proc(
	binary, logs: string,
	config: string = "",
	payload: string = "",
) -> (
	string,
	string,
) {
	binary := s.real(binary)
	info, err := os.stat(binary, context.allocator)
	if err != nil ||
	   info.type != .Regular ||
	   info.mode & {.Execute_User, .Execute_Group, .Execute_Other} == nil {
		return "", "binary must be an executable regular file"
	}
	args := make([dynamic]string); append(&args, binary)
	for value, i in ([2]string{config, payload}) {
		if value != "" {
			path := s.real(value); if !s.regular(path) {
				return "", "config and payload must be regular files"
			}; append(&args, i == 0 ? "-c" : "--sa", path)
		}
	}
	b := strings.builder_make(context.allocator)
	strings.write_string(
		&b,
		`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>` +
		LABEL +
		`</string><key>ProgramArguments</key><array>`,
	)
	for arg in args {
		strings.write_string(
			&b,
			fmt.tprintf("<string>%s</string>", escape(arg)),
		)
	}
	strings.write_string(
		&b,
		fmt.tprintf(
			`</array><key>RunAtLoad</key><true/><key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict><key>ThrottleInterval</key><integer>10</integer><key>ProcessType</key><string>Interactive</string><key>StandardOutPath</key><string>%s</string><key>StandardErrorPath</key><string>%s</string></dict></plist>`,
			escape(s.join(s.abs(logs), "shoji.out.log")),
			escape(s.join(s.abs(logs), "shoji.err.log")),
		),
	)
	return strings.to_string(b), ""
}
ownership :: proc(m: Manager, required: bool) -> string {
	path := plist_path(m)
	if s.kind(path) == .Symlink {
		return "refusing a symlinked service plist"
	}
	if !s.exists(path) {
		return required ? "install the service first" : ""
	}
	if !s.regular(path) {
		return "service plist must be a regular file"
	}
	label, err := s.checked(
		m.executor,
		[]string {
			"/usr/bin/plutil",
			"-extract",
			"Label",
			"raw",
			"-o",
			"-",
			path,
		},
	)
	if err != "" || s.trim(label) != LABEL {
		return "existing plist belongs to another service or is invalid"
	}
	return ""
}
install :: proc(
	m: Manager,
	binary: string,
	config: string = "",
	payload: string = "",
) -> string {
	data, err := configuration(binary, logs_path(m), config, payload)
	if err != "" {
		return err
	}
	if loaded(m) {
		return "stop the loaded service before replacing its configuration"
	}
	if err = ownership(m, false); err != "" {
		return err
	}
	if err = s.mkdir(logs_path(m)); err != "" {
		return err
	}
	return s.atomic_write(plist_path(m), data)
}
start :: proc(m: Manager) -> string {
	if err := ownership(m, true); err != "" {
		return err
	}
	if loaded(m) {
		return ""
	}
	if r := launch(m, "enable", target(m)); r.code != 0 {
		return r.diagnostic
	}
	r := launch(m, "bootstrap", fmt.tprintf("gui/%d", m.uid), plist_path(m))
	if r.code != 0 {
		return s.cat("launchctl bootstrap failed: ", r.diagnostic)
	}; return ""
}
stop :: proc(m: Manager) -> string {
	if err := ownership(m, false); err != "" {
		return err
	}
	if !loaded(m) {
		return ""
	}
	r := launch(m, "bootout", target(m)); if r.code != 0 {
		return s.cat("launchctl bootout failed: ", r.diagnostic)
	}; return ""
}
restart :: proc(m: Manager) -> string {
	if err := start(m); err != "" {
		return err
	}; r := launch(m, "kickstart", "-k", target(m)); if r.code != 0 {
		return s.cat("launchctl kickstart failed: ", r.diagnostic)
	}; return ""
}
uninstall :: proc(m: Manager) -> string {
	if err := ownership(m, false); err != "" {
		return err
	}; if err := stop(m); err != "" {
		return err
	}; if s.exists(plist_path(m)) {
		if err := os.remove(plist_path(m)); err != nil {
			return fmt.tprintf("cannot remove plist: %v", err)
		}
	}; return ""
}
cli :: proc(args: []string, default_binary: string) -> int {
	if len(args) == 0 || args[0] == "--help" {
		fmt.println(
			"Usage: shoji service plist|install|start|stop|restart|status|uninstall [--binary PATH] [--config PATH] [--sa PATH]",
		); return 0
	}
	if os.get_euid() == 0 {
		fmt.eprintln("service: run as the logged-in user, not root"); return 1
	}
	o, err := s.parse(args[1:], []string{"binary", "config", "sa"}, nil)
	if err != "" || len(o.positionals) != 0 {
		fmt.eprintln("service:", err, "unexpected arguments"); return 1
	}
	m := Manager {
		home = s.home(),
		uid  = os.get_uid(),
	}
	switch args[0] {
	case "plist":
		text, e := configuration(
			s.get(o, "binary", default_binary),
			logs_path(m),
			s.get(o, "config"),
			s.get(o, "sa"),
		); err = e; if err == "" {
			fmt.println(text)
		}
	case "install":
		err = install(
			m,
			s.get(o, "binary", default_binary),
			s.get(o, "config"),
			s.get(o, "sa"),
		)
	case "start":
		err = start(m)
	case "stop":
		err = stop(m)
	case "restart":
		err = restart(m)
	case "uninstall":
		err = uninstall(m)
	case "status":
		r := launch(m, "print", target(m)); fmt.print(r.out, r.diagnostic)
		return r.code
	case:
		err = "unknown service command"
	}
	if err != "" {
		fmt.eprintln("service:", err); return 1
	}; return 0
}
