#!/usr/bin/env swift
// Authorize Shoji binaries to claim the WindowServer gate, without rebuilding
// the payload or restarting WindowServer. Run as root (installer/update step).
//
// Writes the CDHash of each PATH, one per line, to the root-owned clients file
// beside the payload; the payload rereads it on every HELLO and ignores it
// unless file and directory are root-owned and not group/world-writable.
// The list is replaced, so pass every binary that should stay trusted.
// usage: trust-client.swift PATH...   |   trust-client.swift --clear
import Foundation

let dir = "/Library/GPUBundles/ShojiWindowServerProbe"
let file = dir + "/clients"
let fm = FileManager.default

func die(_ m: String, _ c: Int32) -> Never {
    FileHandle.standardError.write(Data((m + "\n").utf8)); exit(c)
}

// Run a command; return (exitStatus, combined stdout+stderr).
func run(_ launch: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launch)
    p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (127, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

guard geteuid() == 0 else { die("run as root", 1) }
let args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else { die("usage: trust-client.swift PATH... | --clear", 2) }

if args[0] == "--clear" {
    try? fm.removeItem(atPath: file)
    print("cleared \(file)")
    exit(0)
}

// install -d -o root -g wheel -m 755 dir
try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
chown(dir, 0, 0); chmod(dir, 0o755)

let tmp = dir + "/.clients." + String(format: "%06x", Int.random(in: 0..<0xFFFFFF))
func cleanup() { try? fm.removeItem(atPath: tmp) }

var lines = ""
for path in args {
    let (verify, _) = run("/usr/bin/codesign", ["--verify", "--strict", path])
    if verify != 0 { cleanup(); die("not validly signed: \(path)", 1) }
    let (_, info) = run("/usr/bin/codesign", ["-dvvv", path])
    var hash = ""
    for line in info.split(separator: "\n", omittingEmptySubsequences: false)
    where line.hasPrefix("CDHash=") { hash = String(line.dropFirst(7)) }
    let valid = hash.count == 40 && hash.allSatisfy { "0123456789abcdef".contains($0) }
    if !valid { cleanup(); die("no/invalid CDHash: \(path)", 1) }
    lines += hash + "\n"
    print("trusted \(hash) \(path)")
}

do { try lines.write(toFile: tmp, atomically: false, encoding: .utf8) }
catch { cleanup(); die("cannot write \(tmp): \(error)", 1) }
chown(tmp, 0, 0); chmod(tmp, 0o644)
if rename(tmp, file) != 0 { cleanup(); die("cannot replace \(file)", 1) }   // atomic mv -f
