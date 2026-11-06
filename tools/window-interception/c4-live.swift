#!/usr/bin/env swift
// C4 live acceptance on the disposable 26A434 guest. Run as root (sudo).
//   c4-live.swift install   reinstall the observer (SIGKILLs WindowServer)
//   c4-live.swift run       Shoji's adapter path (GUI logged in + unlocked, 2 Spaces)
//   c4-live.swift controller  (re)start the experiment controller as gate owner
//   c4-live.swift trust     runtime allowlist checks (cleared/unsafe/trusted/export)
//   c4-live.swift daemon [APP MATCH]  D1: window A is APP's window, else a fixture
//   c4-live.swift daemon    the real Shoji daemon as gate owner: C1/C2/C4
// Shoji binaries live in $src/c4 so the WindowServer loader in $src is untouched.
import Foundation

let fm = FileManager.default
let env = ProcessInfo.processInfo.environment
let src = "/Users/Shared/shoji-ws-observer.Qwiazd"
let c4 = src + "/c4"
let tgate = "/private/tmp/shoji-ws-observer-tgate-26A434.bin"
let req = "/private/tmp/shoji-gate-handoff-request"
let response = "/private/tmp/shoji-ws-observer-response-26A434.bin"

signal(SIGHUP, SIG_IGN)

func eprint(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
func die(_ s: String, _ c: Int32) -> Never { eprint(s); exit(c) }

// Capture combined stdout+stderr.
@discardableResult
func capture(_ launch: String, _ args: [String], asUser: String? = nil,
             env extra: [String: String]? = nil) -> (code: Int32, out: String) {
    let p = Process()
    if let u = asUser { p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo"); p.arguments = ["-u", u, launch] + args }
    else { p.executableURL = URL(fileURLWithPath: launch); p.arguments = args }
    if let extra = extra { var e = env; extra.forEach { e[$0] = $1 }; p.environment = e }
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (127, "\(error)") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(data: d, encoding: .utf8) ?? "")
}

// Inherit stdio (output flows to the terminal), return exit code.
@discardableResult
func run(_ launch: String, _ args: [String], asUser: String? = nil,
         env extra: [String: String]? = nil, toFile: String? = nil, background: Bool = false) -> Int32 {
    let p = Process()
    if let u = asUser { p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo"); p.arguments = ["-u", u, launch] + args }
    else { p.executableURL = URL(fileURLWithPath: launch); p.arguments = args }
    if let extra = extra { var e = env; extra.forEach { e[$0] = $1 }; p.environment = e }
    if let f = toFile { fm.createFile(atPath: f, contents: Data()); if let fh = FileHandle(forWritingAtPath: f) { p.standardOutput = fh; p.standardError = fh } }
    do { try p.run() } catch { return 127 }
    if background { return 0 }
    p.waitUntilExit(); return p.terminationStatus
}

func pgrep(_ args: [String]) -> [Int32] {
    capture("/usr/bin/pgrep", args).out.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
}
func kill(pids: [Int32], _ sig: Int32 = SIGTERM) { for p in pids { kill(p, sig) } }
func globExists(_ dir: String, _ prefix: String) -> Bool {
    ((try? fm.contentsOfDirectory(atPath: dir))?.contains { $0.hasPrefix(prefix) }) ?? false
}
func rmGlob(_ base: String) {
    try? fm.removeItem(atPath: base)
    let dir = (base as NSString).deletingLastPathComponent, name = (base as NSString).lastPathComponent
    if let es = try? fm.contentsOfDirectory(atPath: dir) { for e in es where e.hasPrefix(name + ".") { try? fm.removeItem(atPath: dir + "/" + e) } }
}
func fileContains(_ path: String, _ needle: String) -> Bool {
    (try? String(contentsOfFile: path, encoding: .utf8))?.contains(needle) ?? false
}
func fileHasLinePrefix(_ path: String, _ prefix: String) -> Bool {
    ((try? String(contentsOfFile: path, encoding: .utf8))?.split(separator: "\n").contains { $0.hasPrefix(prefix) }) ?? false
}
@discardableResult
func waitUntil(_ tries: Int, _ ms: UInt32, _ cond: () -> Bool) -> Bool {
    var i = 0; while i < tries { if cond() { return true }; usleep(ms * 1000); i += 1 }; return cond()
}

// ---- guards ------------------------------------------------------------
if env["SHOJI_WINDOWSERVER_DISABLE"] == "1" || fm.fileExists(atPath: "/Library/GPUBundles/ShojiWindowServerProbe/DISABLED") {
    die("WindowServer experiment disabled; no changes made.", 3)
}
if geteuid() != 0 { die("Run with sudo on the disposable guest.", 1) }
if capture("/usr/bin/sw_vers", ["-buildVersion"]).out.trimmingCharacters(in: .whitespacesAndNewlines) != "26A434"
    || capture("/usr/sbin/sysctl", ["-n", "kern.hv_vmm_present"]).out.trimmingCharacters(in: .whitespacesAndNewlines) != "1" {
    die("Disposable 26A434 virtual machine required.", 1)
}

let argv = Array(CommandLine.arguments.dropFirst())
let mode = argv.first ?? ""

func swiftScript(_ name: String, _ a: [String] = [], asUser: String? = nil, toFile: String? = nil, background: Bool = false) -> Int32 {
    run("swift", [src + "/" + name] + a, asUser: asUser, toFile: toFile, background: background)
}

switch mode {
case "install":
    guard fm.isExecutableFile(atPath: c4 + "/shoji"), fm.fileExists(atPath: c4 + "/shoji-sa.dylib") else {
        die("missing \(c4)/shoji or shoji-sa.dylib", 1)
    }
    _ = swiftScript("trust-client.swift", [c4 + "/shoji"])
    exit(swiftScript("run-experiment.swift"))   // mirrors `exec`
case "run", "controller", "daemon", "trust":
    break
default:
    die("usage: c4-live.swift install | run | controller | trust | daemon", 2)
}

if mode == "run" || mode == "daemon" { _ = swiftScript("trust-client.swift", [c4 + "/shoji"]) }

guard fm.fileExists(atPath: tgate) else { die("observer not installed (no tgate status); run install first", 1) }
let ws = pgrep(["-x", "WindowServer"]).first.map(String.init) ?? ""

@discardableResult
func startController(toFile: String? = nil) -> Bool {
    if let existing = pgrep(["-u", "501", "-f", "^\(src)/shoji-gate-client serve$"]).first {
        let line = "controller=\(existing) (already serving)\n"
        if let f = toFile { try? line.write(toFile: f, atomically: true, encoding: .utf8) } else { print(line, terminator: "") }
        return true
    }
    rmGlob(req); rmGlob("/private/tmp/shoji-gate-handoff-response")
    for f in ["/tmp/shoji-gate-controller.log", "/private/tmp/shoji-gate-controller-request", "/private/tmp/shoji-gate-controller-response"] { try? fm.removeItem(atPath: f) }
    _ = run("/usr/bin/nohup", ["sudo", "-u", "shoji-test", src + "/shoji-gate-client", "serve"], toFile: "/tmp/shoji-gate-controller.log", background: true)
    waitUntil(100, 50) { globExists("/private/tmp", "shoji-gate-handoff-request.") }
    _ = run(src + "/shoji-gate-handoff", [ws])
    waitUntil(40, 250) { fileHasLinePrefix("/tmp/shoji-gate-controller.log", "owner ") }
    let log = (try? String(contentsOfFile: "/tmp/shoji-gate-controller.log", encoding: .utf8)) ?? ""
    if let f = toFile { try? log.write(toFile: f, atomically: true, encoding: .utf8) } else { print(log, terminator: "") }
    return fileHasLinePrefix("/tmp/shoji-gate-controller.log", "owner ")
}

func loadDock(uid: String) -> Bool {
    var i = 0
    while run("/bin/launchctl", ["asuser", uid, c4 + "/shoji", "--load-sa", c4 + "/shoji-sa.dylib"]) != 0 {
        i += 1; if i >= 15 { print("Dock payload did not load"); return false }; sleep(2)
    }
    return run(c4 + "/shoji", ["--check-sa"], asUser: "shoji-test") == 0
}

if mode == "controller" { exit(startController() ? 0 : 1) }

// ---- trust battery -----------------------------------------------------
if mode == "trust" {
    let out = "/tmp/shoji-c4-trust"
    try? fm.removeItem(atPath: out); try? fm.createDirectory(atPath: out, withIntermediateDirectories: true); chmod(out, 0o777)
    let clients = "/Library/GPUBundles/ShojiWindowServerProbe/clients"
    kill(pids: pgrep(["-u", "501", "-f", "^\(src)/shoji-gate-client serve$"])); usleep(300_000)
    var pass = 0
    func report(_ tag: String, _ dir: String? = nil) {
        rmGlob(req); rmGlob("/private/tmp/shoji-gate-handoff-response")
        let target = out + "/" + tag + ".txt"
        _ = run(c4 + "/shoji", ["--ws-report"] + (dir.map { [$0] } ?? []), asUser: "shoji-test", toFile: target, background: true)
        waitUntil(60, 50) { globExists("/private/tmp", "shoji-gate-handoff-request.") }
        _ = capture(src + "/shoji-gate-handoff", [ws])
        usleep(400_000)   // let the backgrounded --ws-report finish writing
        waitUntil(40, 100) { ((try? fm.attributesOfItem(atPath: target)[.size]) as? Int ?? 0) > 0 }
        if let s = try? String(contentsOfFile: target, encoding: .utf8) { print(s.split(separator: "\n").map { "  " + $0 }.joined(separator: "\n")) }
    }
    func check(_ tag: String, _ pat: String) {
        if fileContains(out + "/" + tag + ".txt", pat) { print("PASS \(tag)"); pass += 1 } else { print("FAIL \(tag) (wanted: \(pat))") }
    }
    print("== T1 no clients file → refused")
    _ = swiftScript("trust-client.swift", ["--clear"]); report("t1-cleared"); check("t1-cleared", "refused (status 4")
    print("== T2 group-writable clients file → ignored")
    _ = swiftScript("trust-client.swift", [c4 + "/shoji"]); chmod(clients, 0o664); report("t2-unsafe"); check("t2-unsafe", "refused (status 4")
    print("== T3 trusted → serving, no payload rebuild")
    chmod(clients, 0o644); report("t3-trusted"); check("t3-trusted", "adapter serving")
    print("== T4 event ring export")
    report("t4-export", out + "/export"); check("t4-export", "retained → ")
    if let s = try? fm.attributesOfItem(atPath: out + "/export/ws-ring.json")[.size] as? Int, s > 0 {
        try? fm.copyItem(atPath: out + "/export/ws-ring.json", toPath: out + "/ws-ring.json")
    }
    _ = startController(toFile: out + "/controller-after.txt")
    print("trust checks \(pass)/4 out=\(out)")
    exit(pass == 4 ? 0 : 1)
}

// ---- JSON helpers for daemon/run ---------------------------------------
func jsonArray(_ s: String) -> [[String: Any]] {
    (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [[String: Any]] ?? []
}
func jsonObject(_ s: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
}
// parse "x=.. y=.. w=.. h=.." ints from a gate-client bounds line
func boundsInts(_ s: String) -> [Int]? {
    var m: [String: Int] = [:]
    for tok in s.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
        let parts = tok.split(separator: "="); if parts.count == 2, let v = Int(parts[1]) { m[String(parts[0])] = v }
    }
    guard let x = m["x"], let y = m["y"], let w = m["w"], let h = m["h"] else { return nil }
    return [x, y, w, h]
}

// ---- daemon acceptance (C1/C2/C4) --------------------------------------
if mode == "daemon" {
    let app = argv.count > 1 ? argv[1] : ""
    let match = argv.count > 2 ? argv[2] : app
    let suffix = app.isEmpty ? "" : "-" + String(app.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    let out = "/tmp/shoji-c4-daemon" + suffix
    try? fm.removeItem(atPath: out); try? fm.createDirectory(atPath: out, withIntermediateDirectories: true); chmod(out, 0o777)
    let uid = capture("/usr/bin/id", ["-u", "shoji-test"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
    let label = "tech.shoji.c4-daemon"
    func m(_ a: [String]) -> Int32 { run(c4 + "/shoji", ["-m"] + a, asUser: "shoji-test") }
    func mOut(_ a: [String]) -> String { capture(c4 + "/shoji", ["-m"] + a, asUser: "shoji-test").out }

    _ = run("/bin/launchctl", ["asuser", uid, "sudo", "-u", "shoji-test", "caffeinate", "-u", "-t", "2"])
    if capture("/usr/sbin/ioreg", ["-n", "Root", "-d1"]).out.contains("\"CGSSessionScreenIsLocked\"=Yes") {
        die("screen is locked: AX cannot identify windows; unlock (or reboot with auto-login) and rerun", 1)
    }
    if !loadDock(uid: uid) { exit(1) }
    kill(pids: pgrep(["-u", uid, "-f", "^\(src)/shoji-gate-client serve$"]))
    try? "".write(toFile: out + "/empty.conf", atomically: true, encoding: .utf8); chmod(out + "/empty.conf", 0o644)
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>Label</key><string>\(label)</string>
    <key>RunAtLoad</key><true/>
    <key>ProgramArguments</key><array><string>\(c4)/shoji</string><string>-c</string><string>\(out)/empty.conf</string></array>
    <key>EnvironmentVariables</key><dict><key>SHOJI_WS_ADAPTER</key><string>1</string></dict>
    <key>StandardErrorPath</key><string>\(out)/daemon.log</string>
    <key>StandardOutPath</key><string>\(out)/daemon.log</string>
    </dict></plist>
    """
    try? plist.write(toFile: out + "/\(label).plist", atomically: true, encoding: .utf8)
    _ = capture("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
    waitUntil(40, 250) { capture("/bin/launchctl", ["print", "gui/\(uid)/\(label)"]).code == 0 || !pgrep(["-f", "^\(c4)/shoji -c"]).isEmpty } // true while still present
    rmGlob(req); rmGlob("/private/tmp/shoji-gate-handoff-response")
    _ = run("/bin/launchctl", ["bootstrap", "gui/\(uid)", out + "/\(label).plist"])
    waitUntil(60, 50) { globExists("/private/tmp", "shoji-gate-handoff-request.") }
    _ = run(src + "/shoji-gate-handoff", [ws])
    waitUntil(40, 250) { fileContains(out + "/daemon.log", "listening on") }
    print((try? String(contentsOfFile: out + "/daemon.log", encoding: .utf8)) ?? "")
    if !fileContains(out + "/daemon.log", "WindowServer adapter serving") {
        print("daemon is not the gate owner"); _ = run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"]); exit(1)
    }

    func item(_ tag: String) -> String {
        let f = out + "/item-\(tag).txt"
        _ = run(src + "/shoji-ws-ordering-trigger", ["--no-hold", "--report-frame", "--delay", "100", "--visible-ms", "40000"], asUser: "shoji-test", toFile: f, background: true)
        waitUntil(100, 50) { fileHasLinePrefix(f, "window=") }
        for line in ((try? String(contentsOfFile: f, encoding: .utf8)) ?? "").split(separator: "\n") where line.hasPrefix("window=") {
            return String(line.dropFirst(7).prefix { $0.isNumber })
        }
        return ""
    }
    func appWindow(_ match: String) -> String? {
        for _ in 0..<120 {
            for w in jsonArray(mOut(["query", "--windows"])) {
                let appName = (w["app"] as? String ?? "").lowercased()
                if appName.contains(match.lowercased()), (w["subrole"] as? String) == "AXStandardWindow", (w["is-floating"] as? Bool) == false {
                    if let id = w["id"] as? Int { return String(id) }
                }
            }
            usleep(500_000)
        }
        return nil
    }
    func syncCheck(_ tag: String, _ wid: String) {
        usleep(1_200_000)
        let frame = jsonObject(mOut(["query", "--windows", "--window", wid]))["frame"] as? [String: Any] ?? [:]
        func r(_ k: String) -> Int { Int((frame[k] as? Double ?? 0).rounded()) }
        let ax = [r("x"), r("y"), r("w"), r("h")]
        let slsStr = capture(src + "/shoji-gate-client", ["bounds", wid], asUser: "shoji-test").out
        let sls = boundsInts(slsStr)
        let verdict = (sls != nil && zip(ax, sls!).allSatisfy { abs($0 - $1) <= 1 }) ? "SYNC" : "DESYNC"
        let line = "\(verdict) \(tag) window=\(wid) ax=(\(ax.map(String.init).joined(separator: " "))) ws=(\(sls?.map(String.init).joined(separator: " ") ?? ""))\n"
        print(line, terminator: "")
        if let fh = FileHandle(forWritingAtPath: out + "/sync.txt") ?? { fm.createFile(atPath: out + "/sync.txt", contents: nil); return FileHandle(forWritingAtPath: out + "/sync.txt") }() { fh.seekToEndOfFile(); fh.write(Data(line.utf8)); try? fh.close() }
    }

    _ = m(["rule", "--add", "app=^shoji-ws-ordering-trigger$", "manage=on"])
    var a = ""
    if !app.isEmpty {
        let appArgs = (env["APP_ARGS"].map { $0.split(separator: " ").map(String.init) }) ?? []
        _ = run("/bin/launchctl", ["asuser", uid, "sudo", "-u", "shoji-test", "open", "-a", app, "--args"] + appArgs)
        guard let w = appWindow(match) else {
            print("no tiled window for \(app)"); try? mOut(["query", "--windows"]).write(toFile: out + "/windows-fail.json", atomically: true, encoding: .utf8)
            _ = run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"]); exit(1)
        }
        a = w
    } else { a = item("a") }
    let b = item("b")
    sleep(2)
    print("items a=\(a) b=\(b)")
    _ = m(["config", "window_animation_duration", "0"])
    if jsonArray(mOut(["query", "--spaces"])).count < 2 { _ = m(["space", "--create"]); sleep(1) }
    _ = m(["config", "--space", "1", "layout", "bsp"]); _ = m(["config", "--space", "2", "layout", "bsp"]); usleep(1_500_000)
    _ = m(["debug", "motion", "start"])
    try? mOut(["query", "--windows"]).write(toFile: out + "/windows-before.json", atomically: true, encoding: .utf8)
    print("== C1 swap"); _ = m(["window", a, "--swap", b]); usleep(500_000)
    _ = run(src + "/shoji-gate-client", ["bounds", a], asUser: "shoji-test"); _ = run(src + "/shoji-gate-client", ["bounds", b], asUser: "shoji-test")
    syncCheck("c1", a); syncCheck("c1", b)
    print("== C2 focus"); _ = m(["window", a, "--focus"]); usleep(300_000); _ = m(["window", b, "--focus"]); usleep(300_000)
    print("== C4 space"); _ = m(["window", a, "--space", "2"]); usleep(500_000)
    _ = run(src + "/shoji-gate-client", ["bounds", a], asUser: "shoji-test"); _ = run(src + "/shoji-gate-client", ["spaces", a], asUser: "shoji-test")
    syncCheck("c4", a)
    try? mOut(["debug", "motion", "dump"]).write(toFile: out + "/motion.json", atomically: true, encoding: .utf8)
    try? mOut(["debug", "ws", "dump"]).write(toFile: out + "/ws-debug.txt", atomically: true, encoding: .utf8)
    print((try? String(contentsOfFile: out + "/ws-debug.txt", encoding: .utf8)) ?? "")
    try? mOut(["query", "--windows"]).write(toFile: out + "/windows-after.json", atomically: true, encoding: .utf8)
    _ = run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
    if !app.isEmpty { _ = run("/bin/launchctl", ["asuser", uid, "sudo", "-u", "shoji-test", "osascript", "-e", "quit app \"\(app)\""]) }
    usleep(500_000)
    _ = swiftScript("gate-handoff-run.swift", ["dump"], toFile: out + "/dump.txt")
    usleep(400_000)
    try? fm.removeItem(atPath: out + "/response.bin"); try? fm.copyItem(atPath: response, toPath: out + "/response.bin")
    _ = startController(toFile: out + "/controller-after.txt")
    _ = run("/usr/bin/pgrep", ["-x", "WindowServer"])
    print("DONE out=\(out)")
    exit(0)
}

// ---- default: adapter battery (run) ------------------------------------
let out = "/tmp/shoji-c4-live"
try? fm.removeItem(atPath: out); try? fm.createDirectory(atPath: out, withIntermediateDirectories: true); chmod(out, 0o755)
print("start \(Date()) WindowServer=\(ws)")

let uid = capture("/usr/bin/id", ["-u", "shoji-test"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
var i = 0
while run("/bin/launchctl", ["asuser", uid, c4 + "/shoji", "--load-sa", c4 + "/shoji-sa.dylib"]) != 0 {
    i += 1; if i >= 15 { die("Dock payload did not load", 1) }; sleep(2)
}
if run(c4 + "/shoji", ["--check-sa"], asUser: "shoji-test") != 0 { die("Dock payload not answering", 1) }

_ = swiftScript("spaces.swift", toFile: out + "/spaces.txt")
let spacesTxt = (try? String(contentsOfFile: out + "/spaces.txt", encoding: .utf8)) ?? ""
print(spacesTxt)
var active = ""
for l in spacesTxt.split(separator: "\n") where l.hasPrefix("ACTIVE ") { active = String(l.dropFirst(7).prefix { $0.isNumber }) }
var target = ""
for l in spacesTxt.split(separator: "\n") where l.hasPrefix("SPACE ") {
    let id = String(l.dropFirst(6).prefix { $0.isNumber }); if !id.isEmpty, id != active { target = id; break }
}
if target.isEmpty { die("Need a second desktop Space (Mission Control +).", 1) }
print("active=\(active) target=\(target)")

var wid = ""
func fixture(_ tag: String) {
    let f = out + "/fixture-\(tag).txt"
    _ = run(src + "/shoji-ws-ordering-trigger", ["--no-hold", "--delay", "100", "--visible-ms", "30000"], asUser: "shoji-test", toFile: f, background: true)
    waitUntil(100, 50) { fileHasLinePrefix(f, "window=") }
    wid = ""
    for l in ((try? String(contentsOfFile: f, encoding: .utf8)) ?? "").split(separator: "\n") where l.hasPrefix("window=") { wid = String(l.dropFirst(7).prefix { $0.isNumber }) }
    sleep(1)
    print("fixture \(tag) window=\(wid)")
}

func shojiMove(_ tag: String, _ wid: String, _ space: String, _ x: String, _ y: String, _ extra: [String: String] = [:]) {
    rmGlob(req); rmGlob("/private/tmp/shoji-gate-handoff-response")
    let f = out + "/" + tag + ".txt"
    let code = run(c4 + "/shoji", ["--ws-space-move", wid, space, x, y], asUser: "shoji-test", env: extra, toFile: f, background: true)
    _ = code
    waitUntil(40, 50) { globExists("/private/tmp", "shoji-gate-handoff-request.") }
    if globExists("/private/tmp", "shoji-gate-handoff-request.") {
        let h = capture(src + "/shoji-gate-handoff", [ws])
        if let fh = FileHandle(forWritingAtPath: f) { fh.seekToEndOfFile(); fh.write(Data(h.out.utf8)); try? fh.close() }
    }
    // the backgrounded shoji writes its own result; give it a moment
    usleep(500_000)
    for extraCmd in [["bounds", wid], ["spaces", wid]] {
        let r = capture(src + "/shoji-gate-client", extraCmd, asUser: "shoji-test")
        if let fh = FileHandle(forWritingAtPath: f) { fh.seekToEndOfFile(); fh.write(Data(r.out.utf8)); try? fh.close() }
    }
    print("== \(tag)"); print((try? String(contentsOfFile: f, encoding: .utf8)) ?? "")
}

// T1 not opted in → adapter disabled, no move (exit 4).
fixture("a")
shojiMove("t1-disabled", wid, target, "600", "400")
// T2 kill switch wins over opt-in.
shojiMove("t2-killswitch", wid, target, "600", "400", ["SHOJI_WS_ADAPTER": "1", "SHOJI_WINDOWSERVER_DISABLE": "1"])
// T3 a live controller owns the gate → refused.
if !startController() { print("controller did not claim the gate") }
let controller = pgrep(["-u", "501", "-f", "^\(src)/shoji-gate-client serve$"]).first
print("controller=\(controller.map(String.init) ?? "none")")
shojiMove("t3-refused", wid, target, "600", "400", ["SHOJI_WS_ADAPTER": "1"])
// T4 owner dies → Shoji reclaims and lands the move.
if let c = controller { kill(c, SIGTERM); usleep(500_000) }
shojiMove("t4-reclaim-place", wid, target, "600", "400", ["SHOJI_WS_ADAPTER": "1"])
// T5 previous Shoji owner exited → reclaim again, new window.
fixture("b")
shojiMove("t5-reclaim-again", wid, target, "700", "450", ["SHOJI_WS_ADAPTER": "1"])

_ = swiftScript("gate-handoff-run.swift", ["dump"], toFile: out + "/dump.txt")
usleep(400_000)
try? fm.removeItem(atPath: out + "/response.bin"); try? fm.copyItem(atPath: response, toPath: out + "/response.bin")
_ = startController(toFile: out + "/controller-after.txt")
_ = run("/usr/bin/pgrep", ["-x", "WindowServer"])
print("DONE out=\(out)")
