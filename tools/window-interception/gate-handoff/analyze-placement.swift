#!/usr/bin/env swift
// Check saved placement evidence; bounds polling cannot prove frame atomicity.
// usage: analyze-placement.swift DIRECTORY [--expected-position X Y]
import Foundation

let fm = FileManager.default
var argv = Array(CommandLine.arguments.dropFirst())
var expected: (Int, Int)?
if let idx = argv.firstIndex(of: "--expected-position"), argv.count > idx + 2, let x = Int(argv[idx + 1]), let y = Int(argv[idx + 2]) {
    expected = (x, y); argv.removeSubrange(idx...(idx + 2))
}
guard let dir = argv.first else { FileHandle.standardError.write(Data("usage: analyze-placement.swift DIRECTORY [--expected-position X Y]\n".utf8)); exit(2) }
func fail(_ m: String) -> Never { FileHandle.standardError.write(Data("invalid evidence: \(m)\n".utf8)); exit(2) }
func text(_ name: String) -> String {
    guard let s = try? String(contentsOfFile: dir + "/" + name, encoding: .utf8) else { fail("cannot read \(name)") }
    return s
}
func rx(_ s: String, _ pat: String, _ g: Int = 1) -> String? {
    guard let re = try? NSRegularExpression(pattern: pat, options: [.anchorsMatchLines]),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: g), in: s) else { return nil }
    return String(s[r])
}

let trigger = text("trigger.txt")
guard let widStr = rx(trigger, #"^window=(\d+)$"#), let wid = Int(widStr) else { fail("trigger.txt has no fixture window id") }

guard let data = fm.contents(atPath: dir + "/response.bin") else { fail("invalid observer response size or magic") }
if data.count != 56 + 256 * 104 || data.prefix(8) != Data("WSOBSERV".utf8) { fail("invalid observer response size or magic") }
func load<T>(_ o: Int, _ t: T.Type) -> T { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: t) } }
let version = load(8, UInt64.self), calls = load(16, UInt64.self)
let numer = load(40, UInt32.self), denom = load(44, UInt32.self), torn = load(48, UInt32.self)
if version != 3 || numer == 0 || denom == 0 { fail("unsupported observer version or invalid timebase") }

var events: [[String: Any]] = []
var off = 56
while off < data.count {
    let seq = load(off, UInt64.self)
    let before = load(off + 16, UInt64.self), after = load(off + 24, UInt64.self)
    let result = load(off + 40, Int32.self), captured = load(off + 44, UInt32.self), held = load(off + 48, UInt32.self)
    let cap = min(Int(captured), 4)
    var ids: [UInt32] = [], ops: [Int32] = []
    for k in 0..<4 { ids.append(load(off + 52 + k * 4, UInt32.self)); ops.append(load(off + 68 + k * 4, Int32.self)) }
    if seq != 0 && ids.prefix(cap).contains(UInt32(wid)) {
        events.append(["sequence": seq, "before": before, "after": after, "held": held, "result": result,
                       "operations": Array(ops.prefix(cap)), "duration_ms": Double(after - before) * Double(numer) / Double(denom) / 1e6])
    }
    off += 104
}

let sampler = text("sampler.csv")
guard let sw = rx(sampler, #"^# window=(\d+)\b"#), Int(sw) == wid else { fail("sampler window does not match fixture") }
guard let sn = rx(sampler, #"^# timebase_numer=(\d+) timebase_denom=(\d+)\b"#, 1),
      let sd = rx(sampler, #"^# timebase_numer=(\d+) timebase_denom=(\d+)\b"#, 2),
      Int(sn) == Int(numer), Int(sd) == Int(denom) else { fail("sampler and observer timebases differ") }
let dataLines = sampler.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("#") }.map(String.init)
var rows: [[String: String]] = []
if let header = dataLines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
    let cols = header.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    for line in dataLines.dropFirst(dataLines.firstIndex(of: header)! + 1) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
        let vals = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        var row: [String: String] = [:]; for (c, v) in zip(cols, vals) { row[c] = v }
        rows.append(row)
    }
}
let durations = rows.compactMap { r -> Double? in
    guard let e = Int(r["tick_end"] ?? ""), let s = Int(r["tick_start"] ?? "") else { return nil }
    return Double(e - s) * Double(numer) / Double(denom) / 1e6
}

var issues: [String] = []
if events.isEmpty { issues.append("observer dump has no fixture events; hold cannot be correlated") }
let holds = events.filter { ($0["held"] as! UInt32) != 0 }
if holds.isEmpty { issues.append("no completed hold recorded for fixture") }
if holds.contains(where: { ($0["held"] as! UInt32) == 2 }) { issues.append("autonomous timeout observed; release-driven placement not established") }
if torn != 0 { issues.append("observer reports torn event copies") }
if !trigger.contains("PASS:") { issues.append("fixture completion missing") }
var duplicates: [String] = []
for (name, original) in [("response-run2.bin", data), ("sampler-run2.csv", Data(sampler.utf8))] {
    let cand = dir + "/" + name
    if fm.fileExists(atPath: cand), fm.contents(atPath: cand) == original { duplicates.append(name) }
}
if !duplicates.isEmpty { issues.append("second-run artifacts duplicate first-run bytes; not independent evidence") }

if let (ex, ey) = expected {
    func fields(_ name: String) -> [String: Int] {
        var out: [String: Int] = [:]
        guard let re = try? NSRegularExpression(pattern: #"\b([a-z_]+)=(-?\d+)\b"#) else { return out }
        let s = text(name)
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            if let kr = Range(m.range(at: 1), in: s), let vr = Range(m.range(at: 2), in: s), let v = Int(s[vr]) { out[String(s[kr])] = v }
        }
        return out
    }
    let arm = fields("arm.txt"), release = fields("release.txt"), placed = fields("placement.txt"), bounds = fields("bounds-released.txt")
    if arm["status"] != 0 || arm["target"] != wid || (arm["gen"] ?? 0) == 0 { issues.append("placement arm is not accepted for the fixture") }
    if release["status"] != 0 || release["target"] != wid || release["gen"] != arm["gen"] { issues.append("release does not match the armed fixture and generation") }
    if placed["status"] != 0 || placed["gen"] != arm["gen"] || (placed["x"], placed["y"]) != (ex, ey) { issues.append("server placement result does not match request and generation") }
    if bounds["status"] != 0 || bounds["window"] != wid || (bounds["x"], bounds["y"]) != (ex, ey) { issues.append("independent bounds do not match requested placement") }
    if holds.count != 1 || holds.contains(where: { ($0["result"] as! Int32) != 0 }) { issues.append("expected exactly one successful fixture hold") }
}

func sha256(_ path: String) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum"); p.arguments = ["-a", "256", path]
    let o = Pipe(); p.standardOutput = o; try? p.run()
    let s = String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""; p.waitUntilExit()
    return s.split(separator: " ").first.map(String.init) ?? ""
}
let verdict = !issues.isEmpty ? "inconclusive" : (expected != nil ? "geometry-verified" : "correlated-only")
let result: [String: Any] = [
    "window": wid, "observer_calls": calls, "torn": torn,
    "observer_sha256": sha256(dir + "/response.bin"),
    "fixture_events": events, "duplicate_artifacts": duplicates,
    "sampler_rows": rows.count, "max_query_ms": durations.max() ?? 0,
    "issues": issues, "verdict": verdict,
    "limitation": "Bounds queries describe intervals, not presentation frames; geometry evidence does not establish frame atomicity.",
]
let outData = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(data: outData, encoding: .utf8)!)
exit(issues.isEmpty ? 0 : 1)
