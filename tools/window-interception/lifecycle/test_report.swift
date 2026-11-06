#!/usr/bin/env swift
// Black-box test for report.swift: feed a hand-built observer ring and assert
// decode + refusals. Run: swift lifecycle/test_report.swift
import Foundation

let fm = FileManager.default
let tool = (CommandLine.arguments[0] as NSString).deletingLastPathComponent + "/report.swift"
var failures = 0
func check(_ cond: Bool, _ msg: String) { if cond { print("PASS \(msg)") } else { print("FAIL \(msg)"); failures += 1 } }

func run(_ bytes: [UInt8]) -> (code: Int32, out: String) {
    let dir = NSTemporaryDirectory() + "shoji-test-report-\(UUID().uuidString)"
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/ring.bin"
    fm.createFile(atPath: path, contents: Data(bytes))
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["swift", tool, path]
    let o = Pipe(); p.standardOutput = o; p.standardError = Pipe()
    try? p.run(); let out = String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""; p.waitUntilExit()
    try? fm.removeItem(atPath: dir)
    return (p.terminationStatus, out)
}

func put<T: FixedWidthInteger>(_ ring: inout [UInt8], _ off: Int, _ v: T) {
    var le = v.littleEndian; withUnsafeBytes(of: &le) { for (i, b) in $0.enumerated() { ring[off + i] = b } }
}
func baseRing() -> [UInt8] {
    var r = [UInt8](repeating: 0, count: 56 + 256 * 104)
    for (i, b) in Array("WSOBSERV".utf8).enumerated() { r[i] = b }
    put(&r, 8, UInt64(3)); put(&r, 16, UInt64(1)); put(&r, 24, UInt64(0)); put(&r, 32, UInt64(0))   // version, calls, entry, branch
    put(&r, 40, UInt32(1)); put(&r, 44, UInt32(1)); put(&r, 48, UInt32(0))                           // numer, denom, torn
    put(&r, 56, UInt64(1)); put(&r, 64, UInt64(0)); put(&r, 72, UInt64(1000)); put(&r, 80, UInt64(2000)) // seq, conn, before, after
    put(&r, 88, UInt32(1)); put(&r, 92, UInt32(0)); put(&r, 96, Int32(0)); put(&r, 100, UInt32(1)); put(&r, 104, UInt32(3)) // count, flag, result, captured, held
    put(&r, 108, UInt32(42))   // first id
    return r
}

// 1. decode timing and target
let (c1, out1) = run(baseRing())
check(c1 == 0, "valid ring decodes (exit 0)")
if let j = (try? JSONSerialization.jsonObject(with: Data(out1.utf8))) as? [String: Any] {
    check((j["retained"] as? NSNumber)?.intValue == 1, "retained == 1")
    let ev = (j["events"] as? [[String: Any]])?.first
    check((ev?["ids"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } == [42], "event id == [42]")
    check((ev?["duration_us"] as? NSNumber)?.doubleValue == 1, "duration_us == 1")
} else { check(false, "valid ring produced JSON") }

// 2. truncation refused
check(run(Array(baseRing().dropLast())).code != 0, "truncated ring refused")
// 3. torn snapshot refused
var torn = baseRing(); put(&torn, 48, UInt32(1)); check(run(torn).code != 0, "torn snapshot refused")
// 4. negative duration refused (after < before)
var neg = baseRing(); put(&neg, 80, UInt64(0)); check(run(neg).code != 0, "after<before refused")

print("failures=\(failures)")
exit(failures == 0 ? 0 : 1)
