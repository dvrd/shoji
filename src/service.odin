package shoji

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import posix "core:sys/posix"
foreign import service_libc "system:c"

@(default_calling_convention = "c")
foreign service_libc {
	isatty :: proc(fd: i32) -> i32 ---
}

LABEL :: "tech.shoji.window-manager"
Service_Manager :: struct {
	home: string,
	uid: int,
	executor: Executor,
}
plist_path :: proc(m: Service_Manager) -> string {
	return join(m.home, "Library/LaunchAgents/" + LABEL + ".plist")
}
logs_path :: proc(m: Service_Manager) -> string {
	return join(m.home, "Library/Logs/shoji")
}
target :: proc(m: Service_Manager) -> string {
	return fmt.tprintf("gui/%d/%s", m.uid, LABEL)
}
launch :: proc(m: Service_Manager, args: ..string) -> Result {
	cmd := make([dynamic]string); append(&cmd, "/bin/launchctl")
	append(&cmd, ..args); return process_run(m.executor, cmd[:])
}
loaded :: proc(m: Service_Manager) -> bool {
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
	binary := real(binary)
	info, err := os.stat(binary, context.allocator)
	if err != nil ||
	   info.type != .Regular ||
	   info.mode & {.Execute_User, .Execute_Group, .Execute_Other} == nil {
		return "", "binary must be an executable regular file"
	}
	args := make([dynamic]string); append(&args, binary)
	for value, i in ([2]string{config, payload}) {
		if value != "" {
			path := real(value); if !regular(path) {
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
			escape(join(abs(logs), "shoji.out.log")),
			escape(join(abs(logs), "shoji.err.log")),
		),
	)
	return strings.to_string(b), ""
}
ownership :: proc(m: Service_Manager, required: bool) -> string {
	path := plist_path(m)
	if kind(path) == .Symlink {
		return "refusing a symlinked service plist"
	}
	if !exists(path) {
		return required ? "install the service first" : ""
	}
	if !regular(path) {
		return "service plist must be a regular file"
	}
	label, err := checked(
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
	if err != "" || trim(label) != LABEL {
		return "existing plist belongs to another service or is invalid"
	}
	return ""
}
install :: proc(
	m: Service_Manager,
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
	if err = mkdir(logs_path(m)); err != "" {
		return err
	}
	return atomic_write(plist_path(m), data)
}
service_start :: proc(m: Service_Manager) -> string {
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
		return cat("launchctl bootstrap failed: ", r.diagnostic)
	}; return ""
}
service_start_configured :: proc(m: Service_Manager, binary, config, payload: string) -> string {
	if !exists(plist_path(m)) {
		if err := install(m, binary, config, payload); err != "" {
			return err
		}
	}
	return service_start(m)
}

service_binary :: proc(m: Service_Manager, fallback: string) -> (string, string) {
	if err := ownership(m, false); err != "" { return "", err }
	if !exists(plist_path(m)) { return real(fallback), "" }
	value, err := checked(m.executor, []string{
		"/usr/bin/plutil", "-extract", "ProgramArguments.0", "raw", "-o", "-", plist_path(m),
	})
	if err != "" || trim(value) == "" { return "", "cannot read the service executable" }
	return real(trim(value)), ""
}

request_accessibility :: proc() {
	keys := [1]Ref{kAXTrustedCheckOptionPrompt}
	values := [1]Ref{kCFBooleanTrue}
	options := CFDictionaryCreate(nil, &keys[0], &values[0], 1, nil, nil)
	if options != nil {
		_ = AXIsProcessTrustedWithOptions(options)
		CFRelease(options)
	}
}

Permission_Choice :: enum { Invalid, Wait, Stop }
accessibility_choice :: proc(input: string) -> Permission_Choice {
	lower := strings.to_lower(strings.trim_space(input))
	defer delete(lower)
	switch lower {
	case "", "y", "yes", "w", "wait": return .Wait
	case "n", "no", "s", "stop": return .Stop
	case: return .Invalid
	}
}

accessibility_more_time :: proc() -> bool {
	for {
		fmt.eprint("service: Still waiting for Accessibility approval. Wait another two minutes? [Y/n] ")
		input: [256]byte
		for {
			if interrupted() { return false }
			if AXIsProcessTrusted() { return true }
			fd := posix.pollfd{fd = posix.STDIN_FILENO, events = {.IN}}
			ready := posix.poll(&fd, 1, 1000)
			if ready < 0 {
				if interrupted() { return false }
				continue
			}
			if ready == 0 { continue }
			if .IN not_in fd.revents { return false }
			n, err := os.read(os.stdin, input[:])
			if err != nil || n == 0 { return false }
			switch accessibility_choice(string(input[:n])) {
			case .Wait: return true
			case .Stop: return false
			case .Invalid: fmt.eprintln("service: enter yes to wait or no to stop"); break
			}
		}
	}
}

accessibility_trusted :: proc() -> bool { return AXIsProcessTrusted() }
accessibility_tick :: proc() { time.sleep(time.Second) }

accessibility_countdown :: proc(
	seconds: int,
	trusted: proc() -> bool = accessibility_trusted,
	tick: proc() = accessibility_tick,
) -> bool {
	show_timer := isatty(i32(posix.STDERR_FILENO)) != 0
	for remaining := seconds; remaining > 0; remaining -= 1 {
		if interrupted() || trusted() {
			if show_timer { fmt.eprint("\r\033[K") }
			return !interrupted()
		}
		if show_timer {
			fmt.eprintf("\rservice: Waiting for approval — %d:%02d until the next prompt (Ctrl-C to cancel)", remaining / 60, remaining % 60)
		}
		tick()
	}
	if show_timer { fmt.eprint("\r\033[K") }
	return !interrupted() && trusted()
}

accessibility_wait :: proc(m: Service_Manager) -> bool {
	request_accessibility()
	result := process_run(m.executor, []string{
		"/usr/bin/open", "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
	})
	if result.code != 0 {
		fmt.eprintln("service: open System Settings → Privacy & Security → Accessibility")
	}
	fmt.eprintln("service: allow Shoji in Accessibility settings. Waiting for approval (Ctrl-C to cancel)...")
	if isatty(i32(posix.STDIN_FILENO)) == 0 { return false }
	for {
		if accessibility_countdown(120) { return true }
		if interrupted() { return false }
		if !accessibility_more_time() { return false }
	}
}

service_accessibility :: proc(
	m: Service_Manager, current, requested: string,
	trusted: proc() -> bool = accessibility_trusted,
	wait: proc(Service_Manager) -> bool = accessibility_wait,
) -> string {
	binary, err := service_binary(m, requested)
	if err != "" { return err }
	if binary == "" { return "service executable does not exist" }
	if binary != real(current) {
		return fmt.tprintf("service uses %s; run that executable to check its Accessibility permission", binary)
	}
	if trusted() || wait(m) { return "" }
	if err := stop(m); err != "" {
		return cat("Accessibility permission is missing and the service could not be stopped: ", err)
	}
	return "Accessibility permission is required; approve Shoji in System Settings, then run shoji service start again"
}
stop :: proc(m: Service_Manager) -> string {
	if err := ownership(m, false); err != "" {
		return err
	}
	if !loaded(m) {
		return ""
	}
	r := launch(m, "bootout", target(m)); if r.code != 0 {
		return cat("launchctl bootout failed: ", r.diagnostic)
	}; return ""
}
restart :: proc(m: Service_Manager) -> string {
	if err := service_start(m); err != "" {
		return err
	}; r := launch(m, "kickstart", "-k", target(m)); if r.code != 0 {
		return cat("launchctl kickstart failed: ", r.diagnostic)
	}; return ""
}
uninstall :: proc(m: Service_Manager) -> string {
	if err := ownership(m, false); err != "" {
		return err
	}; if err := stop(m); err != "" {
		return err
	}; if exists(plist_path(m)) {
		if err := os.remove(plist_path(m)); err != nil {
			return fmt.tprintf("cannot remove plist: %v", err)
		}
	}; return ""
}
service_cli :: proc(args: []string, default_binary: string) -> int {
	configure_signals()
	if len(args) == 0 || args[0] == "--help" {
		fmt.println(
			"Usage: shoji service plist|install|start|stop|restart|status|uninstall [--binary PATH] [--config PATH] [--sa PATH]",
		); return 0
	}
	if os.get_euid() == 0 {
		fmt.eprintln("service: run as the logged-in user, not root"); return 1
	}
	o, err := parse(args[1:], []string{"binary", "config", "sa"}, nil)
	if err != "" || len(o.positionals) != 0 {
		fmt.eprintln("service:", err, "unexpected arguments"); return 1
	}
	m := Service_Manager {
		home = home(),
		uid  = os.get_uid(),
	}
	switch args[0] {
	case "plist":
		text, e := configuration(
			get(o, "binary", default_binary),
			logs_path(m),
			get(o, "config"),
			get(o, "sa"),
		); err = e; if err == "" {
			fmt.println(text)
		}
	case "install":
		err = install(
			m,
			get(o, "binary", default_binary),
			get(o, "config"),
			get(o, "sa"),
		)
	case "start":
		binary := get(o, "binary", default_binary)
		err = service_accessibility(m, default_binary, binary)
		if err == "" {
			err = service_start_configured(m, binary, get(o, "config"), get(o, "sa"))
		}
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
		fmt.eprintln("service:", err); return interrupted() ? 130 : 1
	}; return 0
}
