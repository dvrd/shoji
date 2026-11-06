#!/usr/bin/env swift
// Disposable 26A434 fixture only. Each captured display frame contains both
// windows, allowing mixed states to be detected without cross-stream matching.
// usage: run.swift cascade|gated
import Foundation

let src = "/Users/Shared/shoji-ws-observer.Qwiazd"
let program = src + "/Shoji Layout Capture.app/Contents/MacOS/shoji-layout-frame"
let fixtureProgram = src + "/shoji-layout-fixture"
let fm = FileManager.default

guard let mode = CommandLine.arguments.dropFirst().first else {
    FileHandle.standardError.write(Data("usage: run.swift cascade|gated\n".utf8)); exit(2)
}
guard mode == "cascade" || mode == "gated" else { exit(2) }

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
func grep(_ s: String, _ pat: String, _ g: Int = 1) -> String? {
    guard let re = try? NSRegularExpression(pattern: pat),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: g), in: s) else { return nil }
    return String(s[r])
}
func die(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }
func fileHas(_ path: String, _ needle: String) -> Bool { ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").contains(needle) }

// Guard: disposable 26A434 guest desktop, as shoji-test.
if out1("/usr/bin/id", ["-un"]) != "shoji-test"
    || out1("/usr/bin/sw_vers", ["-buildVersion"]) != "26A434"
    || out1("/usr/sbin/sysctl", ["-n", "kern.hv_vmm_present"]) != "1"
    || out1("/usr/bin/stat", ["-f", "%Su", "/dev/console"]) != "shoji-test" {
    die("Disposable 26A434 guest desktop required.")
}

var tmpl = "/tmp/shoji-layout-frame.XXXXXXXX".cString(using: .utf8)!
guard let cdir = mkdtemp(&tmpl) else { die("mkdtemp failed") }
let out = String(cString: cdir)
print("out=\(out) mode=\(mode)")
try? "\(mode)\n".write(toFile: out + "/mode.txt", atomically: true, encoding: .utf8)

let uid = out1("/usr/bin/id", ["-u"])
var captureLabel = "", gen = "", fixturePid: Int32 = 0
func cleanup() {
    if !gen.isEmpty { try? gateCtlRaw(["release", gen]).write(toFile: out + "/cleanup-release.txt", atomically: true, encoding: .utf8) }
    if !captureLabel.isEmpty { sh("/bin/launchctl", ["bootout", "gui/\(uid)/\(captureLabel)"]) }
    if fixturePid != 0 { kill(fixturePid, SIGTERM) }
}
func gateCtlRaw(_ args: [String]) -> String { sh("swift", [src + "/gate-ctl.swift"] + args).1 }
for s in [SIGINT, SIGTERM] { signal(s) { _ in _exit(130) } }

func waitFile(_ path: String) {
    for _ in 0..<1200 { if let a = try? fm.attributesOfItem(atPath: path), (a[.size] as? Int ?? 0) > 0 { return }; usleep(50_000) }
    cleanup(); die("timeout: \(path)")
}

fixturePid = sh(fixtureProgram, ["fixture", out], toFile: out + "/fixture.log", background: true).2.processIdentifier
waitFile(out + "/fixture-ready.json")
let readyTxt = (try? String(contentsOfFile: out + "/fixture-ready.json", encoding: .utf8)) ?? ""
let red = grep(readyTxt, #""red":(\d+)"#) ?? "", green = grep(readyTxt, #""green":(\d+)"#) ?? "", marker = grep(readyTxt, #""marker":(\d+)"#) ?? ""
guard !red.isEmpty, !green.isEmpty, !marker.isEmpty else { cleanup(); die("fixture ready.json missing ids") }

// AppKit's first surface commit can overwrite positions requested before its
// run loop starts. Establish and verify layout A after that commit, before SCK.
try? "warmup cascade 200\n".write(toFile: out + "/fixture-request", atomically: true, encoding: .utf8)
var i = 0
while i < 100 { if fileHas(out + "/fixture-response.json", #""id":"warmup""#) { break }; usleep(20_000); i += 1 }
guard fileHas(out + "/fixture-response.json", #""red_y":200"#), fileHas(out + "/fixture-response.json", #""green_y":200"#) else { cleanup(); die("warmup layout not established") }
try? fm.copyItem(atPath: out + "/fixture-response.json", toPath: out + "/initial-layout.json")
usleep(500_000)

captureLabel = "com.shoji.c1.capture.\(getpid())"
let plist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>\(captureLabel)</string>
<key>ProgramArguments</key><array><string>\(program)</string><string>capture</string><string>\(out)</string><string>10000</string></array>
<key>RunAtLoad</key><true/>
<key>ProcessType</key><string>Interactive</string>
<key>StandardOutPath</key><string>\(out)/capture.log</string>
<key>StandardErrorPath</key><string>\(out)/capture.log</string>
</dict></plist>
"""
try? plist.write(toFile: out + "/capture.plist", atomically: true, encoding: .utf8)
sh("/bin/launchctl", ["bootstrap", "gui/\(uid)", out + "/capture.plist"])
waitFile(out + "/capture-ready.json")

var sequence = 0
func fixtureCommand(_ cmd: String...) {
    sequence += 1
    try? "\(sequence) \(cmd.joined(separator: " "))\n".write(toFile: out + "/fixture-request.tmp", atomically: true, encoding: .utf8)
    try? fm.removeItem(atPath: out + "/fixture-request")
    try? fm.moveItem(atPath: out + "/fixture-request.tmp", toPath: out + "/fixture-request")
    var k = 0
    while k < 100 {
        if fileHas(out + "/fixture-response.json", "\"id\":\"\(sequence)\"") {
            if let fh = FileHandle(forWritingAtPath: out + "/driver-responses.jsonl") ?? { fm.createFile(atPath: out + "/driver-responses.jsonl", contents: nil); return FileHandle(forWritingAtPath: out + "/driver-responses.jsonl") }() {
                fh.seekToEndOfFile(); fh.write(Data(((try? String(contentsOfFile: out + "/fixture-response.json", encoding: .utf8)) ?? "").utf8)); try? fh.close()
            }
            return
        }
        usleep(20_000); k += 1
    }
    cleanup(); die("fixture command timeout: \(cmd.joined(separator: " "))")
}
@discardableResult
func gate(_ args: [String]) -> String {
    let response = gateCtlRaw(args)
    let line = "\(args.joined(separator: " ")) \(response)"
    print(line, terminator: line.hasSuffix("\n") ? "" : "\n")
    if let fh = FileHandle(forWritingAtPath: out + "/gate.log") ?? { fm.createFile(atPath: out + "/gate.log", contents: nil); return FileHandle(forWritingAtPath: out + "/gate.log") }() {
        fh.seekToEndOfFile(); fh.write(Data((line.hasSuffix("\n") ? line : line + "\n").utf8)); try? fh.close()
    }
    return response
}

usleep(500_000)
for y in [450, 200, 450, 200, 450, 200] {
    if mode == "cascade" {
        fixtureCommand("cascade", "\(y)")
    } else {
        gate(["layout-begin"])
        gate(["layout-add", red, "100", "\(y)"])
        gate(["layout-add", green, "400", "\(y)"])
        let armResp = gate(["layout-arm", marker, "8000"])
        gen = grep(armResp, #"gen=(\d+)"#) ?? ""
        fixtureCommand("trigger")
        gate(["layout-status"])
        gen = ""
    }
    usleep(350_000)
}
fixtureCommand("status")
waitFile(out + "/capture-done.json")
sh("/bin/launchctl", ["bootout", "gui/\(uid)/\(captureLabel)"])
captureLabel = ""
try? gateCtlRaw(["dump"]).write(toFile: out + "/dump.txt", atomically: true, encoding: .utf8)
guard fileHas(out + "/dump.txt", " status=0 ") else { cleanup(); die("dump not status=0") }
try? fm.copyItem(atPath: "/private/tmp/shoji-ws-observer-response-26A434.bin", toPath: out + "/response.bin")
fixtureCommand("shutdown")
var status: Int32 = 0; waitpid(fixturePid, &status, 0)   // fixture exits on shutdown
fixturePid = 0
print("COLLECTED: \(mode) \(out)")
