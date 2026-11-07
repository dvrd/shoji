#!/usr/bin/swift
// C3: move a fixture window between two real spaces while the transaction gate
// holds op 0x18; the shim applies the staged placement on release using the
// context connection. Verified by placement status, sampler bounds and observer
// events. Run as shoji-test on the guest with a logged-in GUI.
// usage: space-move-experiment.swift X Y [--managed-move]
import Foundation

let src = "/Users/Shared/shoji-ws-observer.Qwiazd"
let fm = FileManager.default
let argv = Array(CommandLine.arguments.dropFirst())
guard argv.count >= 2 else { FileHandle.standardError.write(Data("usage: space-move-experiment.swift X Y\n".utf8)); exit(1) }
let x = argv[0], y = argv[1]
let managed = argv.count > 2 ? argv[2] : ""
let out = "/tmp/shoji-space-move" + (managed.isEmpty ? "" : "-managed")

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
func gateCtl(_ args: [String]) -> String { sh(src + "/gate-ctl.swift", args).1 }
func tee(_ path: String, _ s: String) { print(s, terminator: s.hasSuffix("\n") ? "" : "\n"); try? s.write(toFile: path, atomically: true, encoding: .utf8) }
func lineValue(_ s: String, prefix: String) -> String? {   // first line starting `prefix`, digits after
    for l in s.split(separator: "\n") where l.hasPrefix(prefix) { return String(l.dropFirst(prefix.count).prefix { $0.isNumber }) }
    return nil
}
func grepLast(_ s: String, _ pat: String, _ g: Int = 1) -> String? {
    guard let re = try? NSRegularExpression(pattern: pat) else { return nil }
    let ms = re.matches(in: s, range: NSRange(s.startIndex..., in: s))
    guard let m = ms.last, let r = Range(m.range(at: g), in: s) else { return nil }
    return String(s[r])
}
func die(_ m: String) -> Never { print(m); exit(1) }

try? fm.removeItem(atPath: out); try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
let spaces = sh(src + "/spaces.swift", []).1
try? spaces.write(toFile: out + "/spaces.txt", atomically: true, encoding: .utf8)
print(spaces, terminator: spaces.hasSuffix("\n") ? "" : "\n")
let active = lineValue(spaces, prefix: "ACTIVE ") ?? ""
var target = ""
for l in spaces.split(separator: "\n") where l.hasPrefix("SPACE ") {
    let id = String(l.dropFirst(6).prefix { $0.isNumber }); if !id.isEmpty && id != active { target = id; break }
}
guard !target.isEmpty else { die("Need a second desktop Space: open Mission Control and click + to add one, then rerun.") }
print("active=\(active) target=\(target)")

var triggerArgs = ["--space-move", target, "--delay", "2000"]
if !managed.isEmpty { triggerArgs.append(managed) }
let trig = sh(src + "/shoji-ws-ordering-trigger", triggerArgs, toFile: out + "/trigger.txt", background: true).2
let trigPid = trig.processIdentifier
for s in [SIGINT, SIGTERM] { signal(s) { _ in _exit(130) } }

var wid = ""
for _ in 0..<100 {
    if let s = try? String(contentsOfFile: out + "/trigger.txt", encoding: .utf8) { wid = lineValue(s, prefix: "window=") ?? "" }
    if !wid.isEmpty { break }
    usleep(50_000)
}
guard !wid.isEmpty else { print("no window id from trigger"); exit(1) }
print("window=\(wid)")

let samp = sh(src + "/shoji-ws-visibility-sampler", [wid, "200000", "10000"], toFile: out + "/sampler.csv", background: true).2
tee(out + "/arm.txt", gateCtl(["space-place", wid, x, y]))
let gen = grepLast((try? String(contentsOfFile: out + "/arm.txt", encoding: .utf8)) ?? "", #"gen=(\d+)"#) ?? ""
guard !gen.isEmpty else { die("space-place did not return a generation") }
print("armed generation=\(gen)")
// The commit reaches the hold at ~4.2 s (startup + 1.0 s pump + 2.0 s delay);
// the deadline is 3 s. Release at ~4.5 s, inside the hold.
usleep(4_500_000)
tee(out + "/release.txt", gateCtl(["release", gen]))
usleep(500_000)
tee(out + "/placement.txt", gateCtl(["placement"]))
let bounds = sh(src + "/shoji-gate-client", ["bounds", wid]).1
try? bounds.write(toFile: out + "/bounds.txt", atomically: true, encoding: .utf8)
print(bounds, terminator: bounds.hasSuffix("\n") ? "" : "\n")
trig.waitUntilExit()
samp.waitUntilExit()
_ = gateCtl(["dump"]); usleep(400_000)
try? fm.removeItem(atPath: out + "/response.bin")
try? fm.copyItem(atPath: "/private/tmp/shoji-ws-observer-response-26A434.bin", toPath: out + "/response.bin")
print("DONE out=\(out)")
_ = trigPid
