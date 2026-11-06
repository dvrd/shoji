#!/usr/bin/env swift
// Disposable Shoji Test guest only. Restarts WindowServer when an observer is
// already mapped, then loads cctor22 and proves the Mach gate. Run over SSH
// from the host as root. HUP is ignored; the controller is left running.
// usage: run-experiment.swift [--preflight]
import Foundation

let fm = FileManager.default
let src = "/Users/Shared/shoji-ws-observer.Qwiazd"
let dst = "/Library/GPUBundles/ShojiWindowServerProbe/shoji-ws-observer-cctor22.dylib"
let tgate = "/private/tmp/shoji-ws-observer-tgate-26A434.bin"
let log = "/tmp/shoji-run-experiment.log"
let exitfile = "/tmp/shoji-run-experiment.exit"
let ctlLog = "/tmp/shoji-gate-controller.log"

signal(SIGHUP, SIG_IGN)

func eprint(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

// print and append to the run log (mirrors `run 2>&1 | tee -a log`).
func emit(_ s: String) {
    print(s)
    if let fh = FileHandle(forWritingAtPath: log) {
        fh.seekToEndOfFile(); fh.write(Data((s + "\n").utf8)); try? fh.close()
    }
}

@discardableResult
func sh(_ launch: String, _ args: [String], env: [String: String]? = nil,
        asUser: String? = nil) -> (code: Int32, out: String) {
    let p = Process()
    if let u = asUser {
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-u", u, launch] + args
    } else {
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
    }
    if let env = env {
        var e = ProcessInfo.processInfo.environment; env.forEach { e[$0] = $1 }; p.environment = e
    }
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (127, "\(error)") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(data: d, encoding: .utf8) ?? "")
}

func pgrep(_ args: [String]) -> [Int32] {
    sh("/usr/bin/pgrep", args).out.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
}

func rmPrefixed(_ base: String) {
    try? fm.removeItem(atPath: base)
    let parent = (base as NSString).deletingLastPathComponent
    let prefix = (base as NSString).lastPathComponent
    if let es = try? fm.contentsOfDirectory(atPath: parent) {
        for e in es where e.hasPrefix(prefix + ".") || e == prefix {
            try? fm.removeItem(atPath: parent + "/" + e)
        }
    }
}

func fileHasLine(_ path: String, prefix: String) -> Bool {
    guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
    return s.split(separator: "\n").contains { $0.hasPrefix(prefix) }
}

func finish(_ code: Int32) -> Never {
    try? "\(code)\n".write(toFile: exitfile, atomically: true, encoding: .utf8)
    exit(code)
}

// ---- preflight guards (stderr only, before the log) --------------------
if ProcessInfo.processInfo.environment["SHOJI_WINDOWSERVER_DISABLE"] == "1"
    || fm.fileExists(atPath: "/Library/GPUBundles/ShojiWindowServerProbe/DISABLED") {
    eprint("WindowServer experiment disabled; no changes made."); exit(3)
}
let args = Array(CommandLine.arguments.dropFirst())
if args.count > 1 || (args.count == 1 && args[0] != "--preflight") {
    eprint("usage: run-experiment.swift [--preflight]"); exit(2)
}
if geteuid() != 0 { eprint("Run with sudo on the disposable guest."); exit(1) }
let build = sh("/usr/bin/sw_vers", ["-buildVersion"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
let vmm = sh("/usr/sbin/sysctl", ["-n", "kern.hv_vmm_present"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
if build != "26A434" || vmm != "1" { eprint("Disposable 26A434 virtual machine required."); exit(1) }
if args.first == "--preflight" {
    print("Disposable VM/build preflight passed; no changes made. Loader ABI checks still required.")
    exit(0)
}

// ---- run ---------------------------------------------------------------
fm.createFile(atPath: log, contents: Data()); chmod(log, 0o644)
try? fm.removeItem(atPath: exitfile)

// Retire stale controllers that would race the new owner on the shared files.
for pid in pgrep(["-u", "501", "-f", "^/Users/Shared/shoji-ws-observer[.]Qwiazd/shoji-gate-client serve$"]) {
    kill(pid, SIGTERM)
}
emit("start \(Date())")
if !fm.isExecutableFile(atPath: src + "/shoji-loader")
    || !fm.fileExists(atPath: src + "/shoji-ws-observer.dylib")
    || !fm.isExecutableFile(atPath: src + "/shoji-gate-client") {
    emit("Missing cctor22 binaries in \(src)"); finish(1)
}

let old = pgrep(["-x", "WindowServer"]).first
emit("WindowServer before: \(old.map(String.init) ?? "none")")
var pid: Int32? = old
if let old = old, fm.fileExists(atPath: tgate) {
    // SIGTERM is ignored by WindowServer; SIGKILL forces a replacement pid.
    emit("SIGKILL WindowServer \(old); an observer status file is present.")
    if kill(old, SIGKILL) != 0 { emit("kill -9 \(old) failed."); finish(1) }
    pid = nil
    var i = 0
    while i < 80 {
        usleep(500_000)
        if let p = pgrep(["-x", "WindowServer"]).first, p != old { pid = p; break }
        if i % 4 == 0 { emit("waiting for WindowServer (\(i))") }
        i += 1
    }
}
guard let wsPid = pid else { emit("WindowServer did not come back."); finish(1) }
emit("WindowServer PID: \(wsPid)")

sh("/usr/bin/install", ["-o", "root", "-g", "wheel", "-m", "644", src + "/shoji-ws-observer.dylib", dst])
for f in ["/private/tmp/shoji-ws-observer-started-26A434.bin",
          "/private/tmp/shoji-ws-observer-status-26A434.bin",
          tgate,
          "/private/tmp/shoji-ws-observer-request",
          "/private/tmp/shoji-ws-observer-response-26A434.bin"] { try? fm.removeItem(atPath: f) }

emit(sh(src + "/shoji-loader", ["--windowserver", "\(wsPid)", dst],
        env: ["SHOJI_WINDOWSERVER_EXPERIMENT": "1"]).out)
emit("WindowServer after load: \(pgrep(["-x", "WindowServer"]).first.map(String.init) ?? "none")")
emit(sh("/bin/ls", ["-l", "/private/tmp/shoji-ws-observer-started-26A434.bin", tgate]).out)

// Task-port handoff does not need the session bootstrap port (offset 128, u64 LE).
var bootstrapPort: UInt64 = 0
if let fh = FileHandle(forReadingAtPath: tgate) {
    fh.seek(toFileOffset: 128)
    let d = fh.readData(ofLength: 8); try? fh.close()
    if d.count == 8 { bootstrapPort = d.withUnsafeBytes { $0.load(as: UInt64.self) } }
}
emit("bootstrap_port=\(bootstrapPort)")
if bootstrapPort == 0 { emit("No GUI session; the handoff prove does not need one.") }

// B7: persistent controller claims gate ownership and serves for WS lifetime.
rmPrefixed(ctlLog)
for f in ["/private/tmp/shoji-gate-controller-request",
          "/private/tmp/shoji-gate-controller-response",
          "/private/tmp/shoji-gate-controller-seq",
          "/private/tmp/shoji-gate-handoff-request",
          "/private/tmp/shoji-gate-handoff-response"] { rmPrefixed(f) }
fm.createFile(atPath: ctlLog, contents: Data())
let ctl = Process()
ctl.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
ctl.arguments = ["sudo", "-u", "shoji-test", src + "/shoji-gate-client", "serve"]
if let fh = FileHandle(forWritingAtPath: ctlLog) { ctl.standardOutput = fh; ctl.standardError = fh }
try? ctl.run()

func handoffReqExists() -> Bool {
    (try? fm.contentsOfDirectory(atPath: "/private/tmp"))?
        .contains { $0.hasPrefix("shoji-gate-handoff-request.") } ?? false
}
var i = 0
while i < 100 && !handoffReqExists() { usleep(50_000); i += 1 }
if handoffReqExists() { sh(src + "/shoji-gate-handoff", ["\(wsPid)"]) }

i = 0
while i < 60 && !fileHasLine(ctlLog, prefix: "owner ") { usleep(250_000); i += 1 }
if !fileHasLine(ctlLog, prefix: "owner ") {
    emit((try? String(contentsOfFile: ctlLog, encoding: .utf8)) ?? "")
    emit("controller failed to claim ownership")
    kill(ctl.processIdentifier, SIGTERM)
    finish(1)
}
emit((try? String(contentsOfFile: ctlLog, encoding: .utf8)) ?? "")
emit("controller running pid=\(ctl.processIdentifier)")

// Drive the prove battery through the controller command channel.
var proveOut = ""
var proveCode: Int32 = 0
for cmd in [["status"], ["arm", "55", "3"], ["arm", "66", "3"], ["release", "0"]] {
    let (c, o) = sh("swift", [src + "/gate-ctl.swift"] + cmd, asUser: "shoji-test")
    proveOut += o; proveCode = c
}
try? proveOut.write(toFile: "/tmp/shoji-gate-prove.txt", atomically: true, encoding: .utf8)
emit(proveOut)
var gen = ""
for line in proveOut.split(separator: "\n") {
    if let r = line.range(of: " status=0 target=55 gen=") {
        gen = String(line[r.upperBound...].prefix { $0.isNumber }); if !gen.isEmpty { break }
    }
}
let busy = proveOut.split(separator: "\n").filter { $0.contains(" status=6 target=55") }.count
let rel = proveOut.split(separator: "\n").filter { $0.contains(" status=0 target=55") }.count
if gen.isEmpty || busy != 1 || rel != 2 {
    emit("controller battery mismatch (gen=\(gen) busy=\(busy) rel=\(rel))")
    proveCode = 1
}
emit("prove_exit=\(proveCode)")

emit("running second hello (must be rejected)")
let second = sh("swift", [src + "/gate-handoff-run.swift", "hello"])
try? second.out.write(toFile: "/tmp/shoji-gate-second.txt", atomically: true, encoding: .utf8)
emit(second.out)
emit("second_hello_exit=\(second.code) (1=rejected as designed)")
emit(sh("/usr/bin/pgrep", ["-x", "WindowServer"]).out)
finish(proveCode)
