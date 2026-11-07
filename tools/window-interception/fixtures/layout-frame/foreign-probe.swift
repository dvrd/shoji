#!/usr/bin/swift
// C1 production prerequisite: does the staged layout apply to windows owned by
// OTHER processes, triggered by a marker owned by a THIRD process (as a
// Shoji-owned marker would be)? The C1 fixture proved same-owner only.
// Run as shoji-test with an unlocked GUI and the gate controller serving.
// usage: foreign-probe.swift [ROUNDS] [appkit|sls]   (marker kind; sls = Shoji's surfaces)
import Foundation

let src = "/Users/Shared/shoji-ws-observer.Qwiazd"
let out = "/tmp/shoji-c1-foreign"
let fm = FileManager.default
let argv = Array(CommandLine.arguments.dropFirst())
let rounds = argv.count > 0 ? (Int(argv[0]) ?? 3) : 3
let markerKind = argv.count > 1 ? argv[1] : "appkit"

var childPids: [Int32] = []
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
func ctl(_ args: [String]) -> String { sh(src + "/gate-ctl.swift", args).1 }
func tee(_ path: String, _ s: String, append: Bool = false) {
    print(s, terminator: s.hasSuffix("\n") ? "" : "\n")
    if append, let fh = FileHandle(forWritingAtPath: path) { fh.seekToEndOfFile(); fh.write(Data((s.hasSuffix("\n") ? s : s + "\n").utf8)); try? fh.close() }
    else { try? (s.hasSuffix("\n") ? s : s + "\n").write(toFile: path, atomically: true, encoding: .utf8) }
}
func windowOf(_ file: String) -> String? {   // file → wid (waits)
    for _ in 0..<100 {
        if let s = try? String(contentsOfFile: file, encoding: .utf8) {
            for line in s.split(separator: "\n") where line.hasPrefix("window=") {
                let w = String(line.dropFirst(7).prefix { $0.isNumber }); if !w.isEmpty { return w }
            }
        }
        usleep(50_000)
    }
    return nil
}
func item(_ tag: String) -> String {   // wid of a visible foreign window (own process)
    let (_, _, p) = sh(src + "/shoji-ws-ordering-trigger", ["--no-hold", "--report-frame", "--delay", "100", "--visible-ms", "30000"], toFile: out + "/item-\(tag).txt", background: true)
    childPids.append(p.processIdentifier)
    return windowOf(out + "/item-\(tag).txt") ?? ""
}
for s in [SIGINT, SIGTERM] { signal(s) { _ in _exit(130) } }

try? fm.removeItem(atPath: out); try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
let a = item("a"), b = item("b")
usleep(1_500_000)
tee(out + "/summary.txt", "items a=\(a) b=\(b)")
print(sh(src + "/shoji-gate-client", ["bounds", a]).1, terminator: "")
print(sh(src + "/shoji-gate-client", ["bounds", b]).1, terminator: "")

var pass = 0
for r in 1...rounds {
    // Alternate between two layouts so every round is a real move.
    let (ax, ay, bx, by) = (r % 2 == 1) ? (200, 200, 700, 200) : (200, 500, 700, 500)
    // Marker: a third process orders its window in 2 s after printing its id.
    let markerArgs = markerKind == "sls" ? ["--sls-marker", "2000"] : ["--no-hold", "--delay", "2000", "--visible-ms", "300"]
    let (_, _, mp) = sh(src + "/shoji-ws-ordering-trigger", markerArgs, toFile: out + "/marker-\(r).txt", background: true)
    let mpid = mp.processIdentifier; childPids.append(mpid)
    let m = windowOf(out + "/marker-\(r).txt") ?? ""
    var arm = ctl(["layout-begin"])
    arm += ctl(["layout-add", a, "\(ax)", "\(ay)"])
    arm += ctl(["layout-add", b, "\(bx)", "\(by)"])
    arm += ctl(["layout-arm", m, "8000"])
    try? arm.write(toFile: out + "/arm-\(r).txt", atomically: true, encoding: .utf8)
    print(arm, terminator: arm.hasSuffix("\n") ? "" : "\n")
    sleep(3)
    let status = ctl(["layout-status"])
    let ba = sh(src + "/shoji-gate-client", ["bounds", a]).1
    let bb = sh(src + "/shoji-gate-client", ["bounds", b]).1
    let statusFile = out + "/status-\(r).txt"
    tee(statusFile, status)
    tee(statusFile, "\(ba)\n\(bb)", append: true)
    let statusAll = (try? String(contentsOfFile: statusFile, encoding: .utf8)) ?? ""
    let ok = (statusAll.range(of: #" status=0 .*applied=2"#, options: .regularExpression) != nil
              && ba.contains(" x=\(ax) y=\(ay) ") && bb.contains(" x=\(bx) y=\(by) ")) ? 1 : 0
    tee(out + "/summary.txt", "round \(r) marker=\(m) target a(\(ax),\(ay)) b(\(bx),\(by)) pass=\(ok)", append: true)
    pass += ok
    mp.waitUntilExit()
}
_ = ctl(["dump"]); usleep(400_000)
try? fm.removeItem(atPath: out + "/response.bin")
try? fm.copyItem(atPath: "/private/tmp/shoji-ws-observer-response-26A434.bin", toPath: out + "/response.bin")
tee(out + "/summary.txt", "PASS \(pass)/\(rounds) marker=\(markerKind) out=\(out)", append: true)
for p in childPids { kill(p, SIGTERM) }
exit(pass == rounds ? 0 : 1)
