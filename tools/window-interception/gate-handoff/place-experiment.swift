#!/usr/bin/swift
// Fixture placement diagnostic (B7). Release independently of synchronous SLS
// calls: they may queue behind the globally serializing hold. Saved bounds and
// successful command submission do not prove atomic placement.
// usage: place-experiment.swift X Y
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
func gateCtl(_ args: [String]) -> String { sh(src + "/gate-ctl.swift", args).1 }
func tee(_ path: String, _ s: String) { print(s, terminator: s.hasSuffix("\n") ? "" : "\n"); try? s.write(toFile: path, atomically: true, encoding: .utf8) }
func grepLast(_ s: String, _ pat: String, _ g: Int = 1) -> String? {
    guard let re = try? NSRegularExpression(pattern: pat) else { return nil }
    guard let m = re.matches(in: s, range: NSRange(s.startIndex..., in: s)).last, let r = Range(m.range(at: g), in: s) else { return nil }
    return String(s[r])
}
func fileHas(_ path: String, _ needle: String) -> Bool { ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").contains(needle) }
func md5(_ path: String) -> String { fm.fileExists(atPath: path) ? out1("/sbin/md5", ["-q", path]) : "missing" }
func die(_ m: String, _ c: Int32 = 1) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(c) }

if out1("/usr/bin/id", ["-un"]) != "shoji-test" || out1("/usr/bin/sw_vers", ["-buildVersion"]) != "26A434" {
    die("Disposable 26A434 guest user shoji-test required.")
}
var tmpl = "/tmp/shoji-place.XXXXXXXX".cString(using: .utf8)!
guard let cdir = mkdtemp(&tmpl) else { die("mkdtemp failed") }
let out = String(cString: cdir)
print("out=\(out)")
guard argv.count >= 2 else { die("usage: place-experiment.swift X Y") }
let x = argv[0], y = argv[1]

var trigPid: Int32 = 0, sampPid: Int32 = 0, gen = ""
for s in [SIGINT, SIGTERM] { signal(s) { _ in _exit(130) } }

let trig = sh(src + "/shoji-ws-ordering-trigger", ["--no-hold", "--delay", "3000"], toFile: out + "/trigger.txt", background: true).2
trigPid = trig.processIdentifier
var wid = ""
for _ in 0..<100 {
    if let s = try? String(contentsOfFile: out + "/trigger.txt", encoding: .utf8) {
        for l in s.split(separator: "\n") where l.hasPrefix("window=") { wid = String(l.dropFirst(7).prefix { $0.isNumber }); break }
    }
    if !wid.isEmpty { break }
    usleep(50_000)
}
guard !wid.isEmpty else { kill(trigPid, SIGTERM); die("no window id from trigger") }
print("window=\(wid)")
// Queries may block across the whole hold. Missing observations during a hold are not proof of invisibility.
let samp = sh(src + "/shoji-ws-visibility-sampler", [wid, "200000", "8000"], toFile: out + "/sampler.csv", background: true).2
sampPid = samp.processIdentifier
tee(out + "/arm.txt", gateCtl(["arm", wid, "3"]))
guard fileHas(out + "/arm.txt", " status=0 target=\(wid) gen=") else { die("INCONCLUSIVE: arm rejected; see \(out)/arm.txt") }
gen = grepLast((try? String(contentsOfFile: out + "/arm.txt", encoding: .utf8)) ?? "", #"gen=(\d+)"#) ?? ""
guard !gen.isEmpty else { die("arm did not return a generation") }
print("armed generation=\(gen)")
// The trigger orders at --delay (3 s). Place and release must land between the
// claim and the 3 s hold deadline. Wait past the delay before placing.
usleep(3_500_000)
// A separate thread releases even if place/bounds block — never put a synchronous
// bounds read before the release on this driver.
let releaseDone = DispatchSemaphore(value: 0)
let capturedGen = gen
Thread.detachNewThread {
    usleep(500_000)
    try? gateCtl(["release", capturedGen]).write(toFile: out + "/release.txt", atomically: true, encoding: .utf8)
    releaseDone.signal()
}
tee(out + "/place.txt", sh(src + "/shoji-gate-client", ["place", wid, x, y]).1)
releaseDone.wait()
print((try? String(contentsOfFile: out + "/release.txt", encoding: .utf8)) ?? "", terminator: "")
if fileHas(out + "/release.txt", " status=0 ") { gen = "" }
tee(out + "/bounds-released.txt", sh(src + "/shoji-gate-client", ["bounds", wid]).1)
trig.waitUntilExit(); trigPid = 0
samp.waitUntilExit(); sampPid = 0
// Dumps go through the gate owner; the retired file fallback must not exist.
let before = md5("/private/tmp/shoji-ws-observer-response-26A434.bin")
tee(out + "/dump.txt", gateCtl(["dump"]))
var i = 0
while i < 100 {
    let now = md5("/private/tmp/shoji-ws-observer-response-26A434.bin")
    if now != "missing" && now != before { break }
    usleep(50_000); i += 1
}
if i == 100 { die("INCONCLUSIVE: no changed observer dump; artifacts retained at \(out)") }
try? fm.copyItem(atPath: "/private/tmp/shoji-ws-observer-response-26A434.bin", toPath: out + "/response.bin")
print("COLLECTED out=\(out); analyze fixture events before drawing conclusions")
