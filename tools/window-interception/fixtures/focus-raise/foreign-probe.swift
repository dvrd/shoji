#!/usr/bin/env swift
// C2 production prerequisite: does the ordering receipt fire when a window is
// raised the way Shoji raises it — from another process? Methods:
//   owner       fixture raises its own window (orderFrontRegardless)
//   owner-focus fixture activates + makeKeyAndOrderFront (control; proven 2026-11-05)
//   dock-order  Shoji's .Order: Dock payload Window_Order (transaction commit)
//   ax-focus    Shoji's .Focus: activate + AXMain + AXRaise (needs AX trust)
// Run as shoji-test, unlocked GUI, gate controller serving, Dock payload loaded.
// usage: foreign-probe.swift [METHOD...]
import Foundation

let src = "/Users/Shared/shoji-ws-observer.Qwiazd"
let out = "/tmp/shoji-c2-foreign"
let fixtureDir = "/tmp/shoji-c2-foreign-lab"
let fm = FileManager.default
let methods = CommandLine.arguments.count > 1 ? Array(CommandLine.arguments.dropFirst()) : ["owner-focus", "owner", "dock-order", "ax-focus"]

@discardableResult
func sh(_ launch: String, _ args: [String], capture: Bool = true, toFile: String? = nil, background: Bool = false) -> (Int32, String, Process) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: launch.hasPrefix("/") ? launch : "/usr/bin/env")
    p.arguments = launch.hasPrefix("/") ? args : [launch] + args
    var pipe: Pipe?
    if let f = toFile { fm.createFile(atPath: f, contents: Data()); if let fh = FileHandle(forWritingAtPath: f) { p.standardOutput = fh; p.standardError = fh } }
    else if capture { pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe }
    do { try p.run() } catch { return (127, "\(error)", p) }
    if background { return (0, "", p) }
    var o = ""; if let pipe = pipe { o = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "" }
    p.waitUntilExit(); return (p.terminationStatus, o, p)
}
func gateCtl(_ args: [String]) -> String { sh("swift", [src + "/gate-ctl.swift"] + args).1 }
func grep(_ s: String, _ pat: String, _ g: Int = 1) -> String? {
    guard let re = try? NSRegularExpression(pattern: pat),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: g), in: s) else { return nil }
    return String(s[r])
}
func append(_ path: String, _ s: String) {
    if let fh = FileHandle(forWritingAtPath: path) { fh.seekToEndOfFile(); fh.write(Data(s.utf8)); try? fh.close() }
    else { try? s.write(toFile: path, atomically: true, encoding: .utf8) }
}

try? fm.removeItem(atPath: out); try? fm.removeItem(atPath: fixtureDir)
try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
try? fm.createDirectory(atPath: fixtureDir, withIntermediateDirectories: true)
var lab = src + "/Shoji Focus Lab.app/Contents/MacOS/shoji-focus-fixture"
if !fm.isExecutableFile(atPath: lab) { lab = src + "/shoji-focus-fixture" }
var labProcPid: Int32 = 0
let (_, _, labProc) = sh(lab, ["fixture", fixtureDir], toFile: out + "/fixture.log", background: true)
let labpid = labProc.processIdentifier
labProcPid = labpid
func cleanup() { kill(labpid, SIGTERM) }
for s in [SIGINT, SIGTERM] { signal(s) { _ in kill(labProcPid, SIGTERM); _exit(130) } }

var i = 0
while i < 100 && !fm.fileExists(atPath: fixtureDir + "/ready.json") { usleep(100_000); i += 1 }
let ready = (try? String(contentsOfFile: fixtureDir + "/ready.json", encoding: .utf8)) ?? ""
let red = grep(ready, #""red":(\d+)"#) ?? ""
let green = grep(ready, #""green":(\d+)"#) ?? ""
let summary = out + "/summary.txt"
let head = "lab pid=\(labpid) red=\(red) green=\(green) methods=\(methods.joined(separator: " "))\n"
print(head, terminator: ""); try? head.write(toFile: summary, atomically: true, encoding: .utf8)

var seq = 0
func labCmd(_ cmd: String...) {   // atomic rename: fixture polls every 5 ms, must never see a partial line
    seq += 1
    let line = "\(Int(Date().timeIntervalSince1970))\(getpid())\(seq) \(cmd.joined(separator: " "))\n"
    try? line.write(toFile: fixtureDir + "/request.tmp", atomically: true, encoding: .utf8)
    try? fm.removeItem(atPath: fixtureDir + "/request")
    try? fm.moveItem(atPath: fixtureDir + "/request.tmp", toPath: fixtureDir + "/request")
    usleep(500_000)
}
func receipt(_ gen: String) -> (fired: Bool, line: String) {   // 0 if fired within ~2 s
    var line = ""
    for _ in 0..<20 {
        line = gateCtl(["receipt", gen])
        if line.contains(" status=0 ") { print(line, terminator: line.hasSuffix("\n") ? "" : "\n"); return (true, line) }
        usleep(100_000)
    }
    print(line, terminator: line.hasSuffix("\n") ? "" : "\n"); return (false, line)
}

for method in methods {
    labCmd("focus", "green")   // put green in front so raising red is a real order change
    _ = gateCtl(["watch", "0"])
    let gen = grep(gateCtl(["watch", red]), #"gen=(\d+)"#) ?? ""
    var action = ""
    switch method {
    case "owner": labCmd("raise", "red"); action = "owner raise"
    case "owner-focus": labCmd("focus", "red"); action = "owner focus"
    case "dock-order": action = sh(src + "/shoji-ws-ordering-trigger", ["--dock-order", red]).1
    case "ax-focus": action = sh(src + "/shoji-ws-ordering-trigger", ["--ax-focus", "\(labpid)", red]).1
    default: break
    }
    let (fired, line) = receipt(gen)
    _ = gateCtl(["watch", "0"])
    let row = "\(method) gen=\(gen) fired=\(fired ? "yes" : "no") | \(action.replacingOccurrences(of: "\n", with: " ")) | \(line)\n"
    print(row, terminator: ""); append(summary, row)
}
labCmd("snapshot")
if fm.fileExists(atPath: fixtureDir + "/response.json") { try? fm.removeItem(atPath: out + "/snapshot.json"); try? fm.copyItem(atPath: fixtureDir + "/response.json", toPath: out + "/snapshot.json") }
print("DONE out=\(out)")
cleanup()
