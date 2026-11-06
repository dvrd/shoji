#!/usr/bin/env swift
// Exact-build, disposable-window placement through the server ordering seam.
// This collects geometry evidence; it does not certify frame atomicity.
// usage: server-placement.swift X Y [release|timeout|cancel]
import Foundation

let src = "/Users/Shared/shoji-ws-observer.Qwiazd"
let fm = FileManager.default
let argv = Array(CommandLine.arguments.dropFirst())

@discardableResult
func sh(_ launch: String, _ args: [String], toFile: String? = nil, background: Bool = false) -> (Int32, String, Process) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: launch.hasPrefix("/") ? launch : "/usr/bin/env")
    p.arguments = launch.hasPrefix("/") ? args : [launch] + args
    var pipe: Pipe?
    if let f = toFile { fm.createFile(atPath: f, contents: Data()); if let fh = FileHandle(forWritingAtPath: f) { p.standardOutput = fh; p.standardError = fh } }
    else { pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe }
    do { try p.run() } catch { return (127, "\(error)", p) }
    if background { return (0, "", p) }
    var o = ""; if let pipe = pipe { o = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "" }
    p.waitUntilExit(); return (p.terminationStatus, o, p)
}
func out1(_ launch: String, _ args: [String]) -> String { sh(launch, args).1.trimmingCharacters(in: .whitespacesAndNewlines) }
func gateCtl(_ args: [String]) -> String { sh("swift", [src + "/gate-ctl.swift"] + args).1 }
func grep(_ s: String, _ pat: String, _ g: Int = 1) -> String? {
    guard let re = try? NSRegularExpression(pattern: pat),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: g), in: s) else { return nil }
    return String(s[r])
}
func fileHas(_ path: String, _ needle: String, regex: Bool = false) -> Bool {
    let s = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    return regex ? (s.range(of: needle, options: .regularExpression) != nil) : s.contains(needle)
}
func die(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }

if out1("/usr/bin/id", ["-un"]) != "shoji-test" || out1("/usr/bin/sw_vers", ["-buildVersion"]) != "26A434" || out1("/usr/sbin/sysctl", ["-n", "kern.hv_vmm_present"]) != "1" {
    die("Disposable 26A434 VM user shoji-test required.")
}
if out1("/usr/bin/stat", ["-f", "%Su", "/dev/console"]) != "shoji-test" { die("Log into the guest desktop before running the fixture.") }
guard argv.count >= 2 else { die("usage: server-placement.swift X Y [release|timeout|cancel]") }
let x = argv[0], y = argv[1]
let mode = argv.count > 2 ? argv[2] : "release"
guard ["release", "timeout", "cancel"].contains(mode) else { exit(2) }
let visibleMs = mode == "timeout" ? "8000" : "3000"
let sampleMs = mode == "timeout" ? "12000" : "9000"

var tmpl = "/tmp/shoji-server-placement-run.XXXXXXXX".cString(using: .utf8)!
guard let cdir = mkdtemp(&tmpl) else { die("mkdtemp failed") }
let out = String(cString: cdir)
print("out=\(out)")

var gen = "", fixturePid: Int32 = 0, samplerPid: Int32 = 0
func cleanup() {
    if !gen.isEmpty { try? gateCtl(["release", gen]).write(toFile: out + "/cleanup.txt", atomically: true, encoding: .utf8) }
    if fixturePid != 0 { kill(fixturePid, SIGTERM) }
    if samplerPid != 0 { kill(samplerPid, SIGTERM) }
}
for s in [SIGINT, SIGTERM] { signal(s) { _ in _exit(130) } }

let fix = sh(src + "/shoji-ws-ordering-trigger", ["--no-hold", "--delay", "2000", "--visible-ms", visibleMs], toFile: out + "/trigger.txt", background: true).2
fixturePid = fix.processIdentifier
var wid = ""
for _ in 0..<100 {
    if let s = try? String(contentsOfFile: out + "/trigger.txt", encoding: .utf8) {
        for l in s.split(separator: "\n") where l.hasPrefix("window=") { wid = String(l.dropFirst(7).prefix { $0.isNumber }); break }
    }
    if !wid.isEmpty { break }
    usleep(50_000)
}
guard !wid.isEmpty else { cleanup(); die("no window id") }
let samp = sh(src + "/shoji-ws-visibility-sampler", [wid, "20000", sampleMs], toFile: out + "/sampler.csv", background: true).2
samplerPid = samp.processIdentifier

try? gateCtl(["place-server", wid, x, y]).write(toFile: out + "/arm.txt", atomically: true, encoding: .utf8)
print((try? String(contentsOfFile: out + "/arm.txt", encoding: .utf8)) ?? "", terminator: "")
guard fileHas(out + "/arm.txt", " status=0 target=\(wid) gen=") else { cleanup(); die("arm not accepted") }
gen = grep((try? String(contentsOfFile: out + "/arm.txt", encoding: .utf8)) ?? "", #"gen=(\d+)"#) ?? ""
let armedGeneration = gen
if mode == "cancel" {
    try? gateCtl(["release", gen]).write(toFile: out + "/release.txt", atomically: true, encoding: .utf8)
    usleep(2_200_000)   // cancellation precedes order-in; read back only once the fixture shows
} else if mode == "release" {
    usleep(2_200_000)
    try? gateCtl(["release", gen]).write(toFile: out + "/release.txt", atomically: true, encoding: .utf8)
} else {
    usleep(5_200_000)
}
var k = 0
while k < 40 {
    try? gateCtl(["placement"]).write(toFile: out + "/placement.txt", atomically: true, encoding: .utf8)
    if !fileHas(out + "/placement.txt", " status=6 ") { break }
    usleep(50_000); k += 1
}
print((try? String(contentsOfFile: out + "/placement.txt", encoding: .utf8)) ?? "", terminator: "")
try? sh(src + "/shoji-gate-client", ["bounds", wid]).1.write(toFile: out + "/bounds-released.txt", atomically: true, encoding: .utf8)
print((try? String(contentsOfFile: out + "/bounds-released.txt", encoding: .utf8)) ?? "", terminator: "")
fix.waitUntilExit(); fixturePid = 0
samp.waitUntilExit(); samplerPid = 0
try? gateCtl(["dump"]).write(toFile: out + "/dump.txt", atomically: true, encoding: .utf8)
guard fileHas(out + "/dump.txt", " status=0 ") else { die("dump not status=0") }
try? fm.copyItem(atPath: "/private/tmp/shoji-ws-observer-response-26A434.bin", toPath: out + "/response.bin")
try? "\(mode)\n".write(toFile: out + "/mode.txt", atomically: true, encoding: .utf8)
gen = ""
if mode == "release" {
    guard fileHas(out + "/release.txt", " status=0 target=\(wid) gen=\(armedGeneration)", regex: false),
          fileHas(out + "/placement.txt", " status=0 gen=\(armedGeneration) x=\(x) y=\(y)", regex: false),
          fileHas(out + "/bounds-released.txt", "status=0 x=\(x) y=\(y) ") else { die("release assertions failed; evidence=\(out)") }
} else if mode == "timeout" {
    guard fileHas(out + "/placement.txt", " status=9 ") else { die("timeout assertions failed; evidence=\(out)") }
    if fileHas(out + "/bounds-released.txt", "status=0 x=\(x) y=\(y) ") { exit(1) }
} else {
    guard fileHas(out + "/placement.txt", " status=8 ") else { die("cancel assertions failed; evidence=\(out)") }
    if fileHas(out + "/bounds-released.txt", "status=0 x=\(x) y=\(y) ") { exit(1) }
}
print("PASS: \(mode) geometry diagnostic; evidence=\(out)")
