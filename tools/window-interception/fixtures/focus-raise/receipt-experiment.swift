#!/usr/bin/swift
// C2 ordering-receipt experiment: arm a watch on a fixture window, trigger an
// owner-side focus change, and consume the once-only ordering receipt — no AX
// readback polling. Run as shoji-test on the guest with an unlocked GUI.
import Foundation

let src = "/Users/Shared/shoji-ws-observer.Qwiazd"
let out = "/tmp/shoji-focus-receipt"
let fixtureDir = "/tmp/shoji-focus-lab"
let fm = FileManager.default

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
func grep(_ s: String, _ pat: String, _ g: Int = 1) -> String? {
    guard let re = try? NSRegularExpression(pattern: pat),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: g), in: s) else { return nil }
    return String(s[r])
}
func teeWrite(_ path: String, _ s: String) { print(s, terminator: s.hasSuffix("\n") ? "" : "\n"); try? s.write(toFile: path, atomically: true, encoding: .utf8) }
func die(_ m: String) -> Never { print(m); exit(1) }

try? fm.removeItem(atPath: out); try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
try? fm.removeItem(atPath: fixtureDir); try? fm.createDirectory(atPath: fixtureDir, withIntermediateDirectories: true)
var lab = src + "/Shoji Focus Lab.app/Contents/MacOS/shoji-focus-fixture"
if !fm.isExecutableFile(atPath: lab) { lab = src + "/shoji-focus-fixture" }
var labpid: Int32 = 0
let labProc = sh(lab, ["fixture", fixtureDir], toFile: out + "/fixture.log", background: true).2
labpid = labProc.processIdentifier
for s in [SIGINT, SIGTERM] { signal(s) { _ in kill(labpid, SIGTERM); _exit(130) } }

var i = 0
while i < 100 && !fm.fileExists(atPath: fixtureDir + "/ready.json") { usleep(100_000); i += 1 }
guard fm.fileExists(atPath: fixtureDir + "/ready.json") else { die("fixture never became ready") }
let ready = (try? String(contentsOfFile: fixtureDir + "/ready.json", encoding: .utf8)) ?? ""
let red = grep(ready, #""red":(\d+)"#) ?? "", green = grep(ready, #""green":(\d+)"#) ?? ""
print("red=\(red) green=\(green)")

func fixtureCmd(_ cmd: String...) {
    let id = Int(Date().timeIntervalSince1970 * 1e9)
    try? "\(id) \(cmd.joined(separator: " "))\n".write(toFile: fixtureDir + "/request", atomically: true, encoding: .utf8)
    usleep(400_000)
}
func receiptUntil(_ gen: String, _ want: Int, _ tries: Int, toFile path: String) -> Bool {
    var acc = "", ok = false
    for _ in 0..<tries {
        let line = gateCtl(["receipt", gen])
        acc += line.hasSuffix("\n") ? line : line + "\n"
        if line.contains(" status=\(want) ") { ok = true; break }
        usleep(100_000)
    }
    print(acc, terminator: ""); try? acc.write(toFile: path, atomically: true, encoding: .utf8)
    return ok
}

var fails = 0
func check(_ label: String, _ pass: Bool) { if pass { print("PASS \(label)") } else { print("FAIL \(label)"); fails += 1 } }
func fileHas(_ path: String, _ needle: String) -> Bool { ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").contains(needle) }

print("=== 1. arm receipt for green, then focus green ===")
teeWrite(out + "/watch-green.txt", gateCtl(["watch", green]))
let gen = grep((try? String(contentsOfFile: out + "/watch-green.txt", encoding: .utf8)) ?? "", #"gen=(\d+)"#) ?? ""
guard !gen.isEmpty else { die("no generation") }
usleep(300_000)
fixtureCmd("focus", "green")
_ = receiptUntil(gen, 0, 30, toFile: out + "/receipt-green.txt")
check("receipt fired for focused window", fileHas(out + "/receipt-green.txt", " status=0 "))

print("=== 2. consumed receipt reads idle; stale generation refused ===")
teeWrite(out + "/receipt-consumed.txt", gateCtl(["receipt", gen]))
check("consumed receipt is idle (8)", fileHas(out + "/receipt-consumed.txt", " status=8 "))
let stale = gateCtl(["receipt", "\((Int(gen) ?? 0) + 99)"])
try? stale.write(toFile: out + "/receipt-stale.txt", atomically: true, encoding: .utf8)
check("stale generation refused (7/8)", fileHas(out + "/receipt-stale.txt", " status=7 ") || fileHas(out + "/receipt-stale.txt", " status=8 "))

print("=== 3. cancel: arm red, cancel with watch 0, receipt reads idle ===")
teeWrite(out + "/watch-red.txt", gateCtl(["watch", red]))
let gen2 = grep((try? String(contentsOfFile: out + "/watch-red.txt", encoding: .utf8)) ?? "", #"gen=(\d+)"#) ?? ""
_ = gateCtl(["watch", "0"])
teeWrite(out + "/receipt-canceled.txt", gateCtl(["receipt", gen2]))
check("canceled watch is idle (8)", fileHas(out + "/receipt-canceled.txt", " status=8 "))

print("=== 4. replay: red focus fires a fresh receipt only after a fresh arm ===")
teeWrite(out + "/watch-red2.txt", gateCtl(["watch", red]))
let gen3 = grep((try? String(contentsOfFile: out + "/watch-red2.txt", encoding: .utf8)) ?? "", #"gen=(\d+)"#) ?? ""
fixtureCmd("focus", "red")
_ = receiptUntil(gen3, 0, 30, toFile: out + "/receipt-red.txt")
check("second arm fires for the other window", fileHas(out + "/receipt-red.txt", " status=0 "))

print("=== 5. snapshot: fixture focus state ===")
fixtureCmd("snapshot")
usleep(500_000)
print((try? String(contentsOfFile: fixtureDir + "/response.json", encoding: .utf8)) ?? "")

print("fails=\(fails)")
kill(labpid, SIGTERM)
exit(fails == 0 ? 0 : 1)
