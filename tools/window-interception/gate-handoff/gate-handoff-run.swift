#!/usr/bin/swift
// Disposable Shoji Test guest only. Runs the Mach gate client as the desktop
// user and hands over the gate send right from WindowServer's task as root
// (task-port handoff; bootstrap_look_up from WindowServer is denied on
// macOS 27). Leaves WindowServer running.
import Foundation

let src = "/Users/Shared/shoji-ws-observer.Qwiazd"
let req = "/private/tmp/shoji-gate-handoff-request"
let resp = "/private/tmp/shoji-gate-handoff-response"
let out = "/tmp/shoji-gate-handoff-client.out"
let fm = FileManager.default

func die(_ m: String, _ c: Int32) -> Never {
    FileHandle.standardError.write(Data((m + "\n").utf8)); exit(c)
}

// Remove a path and any "path.*" siblings.
func purge(_ base: String) {
    try? fm.removeItem(atPath: base)
    let parent = (base as NSString).deletingLastPathComponent
    let prefix = (base as NSString).lastPathComponent + "."
    if let entries = try? fm.contentsOfDirectory(atPath: parent) {
        for e in entries where e.hasPrefix(prefix) { try? fm.removeItem(atPath: parent + "/" + e) }
    }
}

func reqSiblingExists() -> Bool {
    let parent = (req as NSString).deletingLastPathComponent
    let prefix = (req as NSString).lastPathComponent + "."
    return ((try? fm.contentsOfDirectory(atPath: parent))?.contains { $0.hasPrefix(prefix) }) ?? false
}

func firstLine(_ launch: String, _ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: launch); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe
    try? p.run()
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(data: d, encoding: .utf8)?.split(separator: "\n").first.map(String.init) ?? ""
}

// Run launch (optionally as a user, optionally capturing to `out`); return the Process.
@discardableResult
func spawn(_ launch: String, _ cmdArgs: [String], asUser user: String? = nil,
           captureToOut: Bool = false, background: Bool = false) -> Process {
    let p = Process()
    if let user = user {
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-u", user, launch] + cmdArgs
    } else {
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = cmdArgs
    }
    if captureToOut, let fh = FileHandle(forWritingAtPath: out) {
        p.standardOutput = fh; p.standardError = fh
    }
    try? p.run()
    if !background { p.waitUntilExit() }
    return p
}

guard geteuid() == 0 else { die("Run with sudo on the disposable guest.", 1) }

let ws = firstLine("/usr/bin/pgrep", ["-x", "WindowServer"])
for p in [req, resp,
          "/private/tmp/shoji-gate-controller-request",
          "/private/tmp/shoji-gate-controller-response",
          "/private/tmp/shoji-gate-controller-seq"] { purge(p) }
try? fm.removeItem(atPath: out)
print("ws=\(ws)")

var args = Array(CommandLine.arguments.dropFirst())
var clientBin = src + "/shoji-gate-client"
if args.first == "--client", args.count >= 2 { clientBin = args[1]; args.removeFirst(2) }

if args.first == "symlink-test" {
    // The helper must refuse a request that is not a regular uid-501 file
    // (NOFOLLOW open). The symlink target is harmless.
    try? fm.removeItem(atPath: req + ".424242")
    try? fm.createSymbolicLink(atPath: req + ".424242", withDestinationPath: "/dev/null")
    print("request.424242 symlinked to /dev/null; helper must refuse")
    let p = spawn(src + "/shoji-gate-handoff", [ws])
    try? fm.removeItem(atPath: req + ".424242")
    print("handoff_exit=\(p.terminationStatus) (1=refused as designed)")
    exit(0)
}

fm.createFile(atPath: out, contents: Data())
let client = spawn(clientBin, args, asUser: "shoji-test", captureToOut: true, background: true)
var i = 0
while i < 100 { if reqSiblingExists() { break }; usleep(50_000); i += 1 }
if reqSiblingExists() {
    spawn(src + "/shoji-gate-handoff", [ws])   // best effort (|| true)
} else {
    print("no handoff request; client falling back")
}
client.waitUntilExit()
let rc = client.terminationStatus
if let data = fm.contents(atPath: out), let s = String(data: data, encoding: .utf8) {
    print(s, terminator: "")
}
print("client_exit=\(rc)")
exit(rc)
