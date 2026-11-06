#!/usr/bin/env swift
// Black-box test for analyze.swift (layout-frame). Run: swift fixtures/layout-frame/test_analyze.swift
import Foundation

let fm = FileManager.default
let tool = (CommandLine.arguments[0] as NSString).deletingLastPathComponent + "/analyze.swift"
var failures = 0
func check(_ cond: Bool, _ msg: String) { if cond { print("PASS \(msg)") } else { print("FAIL \(msg)"); failures += 1 } }

func put<T: FixedWidthInteger>(_ b: inout [UInt8], _ off: Int, _ v: T) {
    var le = v.littleEndian; withUnsafeBytes(of: &le) { for (i, x) in $0.enumerated() { b[off + i] = x } }
}
func jsonl(_ rows: [[String: Any]]) -> String {
    rows.map { String(data: try! JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), encoding: .utf8)! }.joined(separator: "\n") + "\n"
}
func write(_ path: String, _ s: String) { try? s.write(toFile: path, atomically: true, encoding: .utf8) }
func writeJSON(_ path: String, _ o: [String: Any]) { try? JSONSerialization.data(withJSONObject: o).write(to: URL(fileURLWithPath: path)) }

struct Evidence { var dir: String; var frames: [[String: Any]]; var events: [[String: Any]] }

func evidence(mode: String = "gated", mixed: Bool = false) -> Evidence {
    let dir = NSTemporaryDirectory() + "shoji-test-analyze-\(UUID().uuidString)"
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    write(dir + "/mode.txt", mode)
    writeJSON(dir + "/fixture-ready.json", ["pid": 10, "red": 41, "green": 42, "marker": 43])
    writeJSON(dir + "/capture-ready.json", ["started": 1_000_000_000, "numer": 1, "denom": 1])
    var events: [[String: Any]] = [], frames: [[String: Any]] = []
    func frame(_ tick: Int, _ state: String) {
        frames.append(["sequence": frames.count, "displayTicks": tick, "callbackTicks": tick + 1000, "status": 0, "redCount": 4000, "greenCount": 4000, "state": state])
    }
    var data = [UInt8](repeating: 0, count: 56 + 256 * 104)
    for (i, b) in Array("WSOBSERV".utf8).enumerated() { data[i] = b }
    put(&data, 8, UInt64(3)); put(&data, 16, UInt64(6)); put(&data, 24, UInt64(0)); put(&data, 32, UInt64(0))
    put(&data, 40, UInt32(1)); put(&data, 44, UInt32(1)); put(&data, 48, UInt32(0))
    for index in 0..<6 {
        let tick = 1_500_000_000 + index * 500_000_000
        let y = index % 2 == 0 ? 450 : 200
        events.append(["verb": mode == "gated" ? "trigger" : "cascade", "started": tick, "ended": tick + 100_000_000,
                       "red_status": 0, "green_status": 0, "red_x": 100, "green_x": 400, "red_y": y, "green_y": y])
        let off = 56 + index * 104
        put(&data, off, UInt64(index + 1)); put(&data, off + 8, UInt64(0)); put(&data, off + 16, UInt64(tick)); put(&data, off + 24, UInt64(tick + 200_000))
        put(&data, off + 32, UInt32(1)); put(&data, off + 36, UInt32(0)); put(&data, off + 40, Int32(0)); put(&data, off + 44, UInt32(1)); put(&data, off + 48, UInt32(3))
        put(&data, off + 52, UInt32(43))
    }
    let stop = (events.last!["ended"] as! Int) + 200_000_001
    var tick = 1_000_000_000
    while tick < stop {
        var state = "AA"
        for (index, event) in events.enumerated() {
            let started = event["started"] as! Int
            if tick >= started {
                let even = index % 2 == 0
                if tick < started + 40_000_000 { state = mixed ? (even ? "BA" : "AB") : (even ? "AA" : "BB") }
                else { state = even ? "BB" : "AA" }
            }
        }
        frame(tick, state); tick += 10_000_000
    }
    fm.createFile(atPath: dir + "/response.bin", contents: Data(data))
    let e = Evidence(dir: dir, frames: frames, events: events); save(e); return e
}
func save(_ e: Evidence) {
    write(e.dir + "/frames.jsonl", jsonl(e.frames))
    write(e.dir + "/fixture-events.jsonl", jsonl(e.events))
}
func analyze(_ dir: String) -> [String: Any] {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["swift", tool, dir]
    let o = Pipe(); p.standardOutput = o; p.standardError = Pipe()
    try? p.run(); let out = String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""; p.waitUntilExit()
    return ((try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any]) ?? [:]
}
func issues(_ j: [String: Any]) -> [String] { j["issues"] as? [String] ?? ["<no issues key>"] }

// 1. complete gated transitions
do { let e = evidence(); let j = analyze(e.dir)
    check(issues(j).isEmpty, "gated: no issues"); check((j["resolved_transitions"] as? NSNumber)?.intValue == 6, "gated: 6 transitions"); try? fm.removeItem(atPath: e.dir) }
// 2. mixed frames reject gated
do { let e = evidence(mixed: true); check(issues(analyze(e.dir)).contains("gated layout has captured mixed frames"), "gated+mixed flagged"); try? fm.removeItem(atPath: e.dir) }
// 3. positive control needs a mixed frame
do { let e = evidence(mode: "cascade"); check(issues(analyze(e.dir)).contains("positive control did not expose any mixed frame"), "cascade no-mixed flagged"); try? fm.removeItem(atPath: e.dir) }
do { let e = evidence(mode: "cascade", mixed: true); check(issues(analyze(e.dir)).isEmpty, "cascade+mixed clean"); try? fm.removeItem(atPath: e.dir) }
// 4. missing transition → inconclusive
do { var e = evidence(); for i in e.frames.indices { e.frames[i]["state"] = "AA" }; save(e); check(analyze(e.dir)["verdict"] as? String == "inconclusive", "all-AA inconclusive"); try? fm.removeItem(atPath: e.dir) }
// 5. warmup event not counted
do { var e = evidence(); var warmup = e.events[0]; warmup["id"] = "warmup"; warmup["started"] = 1_100_000_000; warmup["ended"] = 1_200_000_000; e.events.insert(warmup, at: 0); save(e)
    check(issues(analyze(e.dir)).isEmpty, "warmup not counted"); try? fm.removeItem(atPath: e.dir) }
// 6. missing color pixels → inconclusive band
do { var e = evidence(); let start = e.events[0]["started"] as! Int
    if let idx = e.frames.firstIndex(where: { ($0["displayTicks"] as! Int) >= start }) { e.frames[idx]["state"] = "?B"; e.frames[idx]["redCount"] = 0 }; save(e)
    check(issues(analyze(e.dir)).contains("fixture pixels missing or outside calibrated position bands"), "missing color flagged"); try? fm.removeItem(atPath: e.dir) }
// 7. slow callback is not frame-scale success
do { let e = evidence(); var d = [UInt8](fm.contents(atPath: e.dir + "/response.bin")!); put(&d, 56 + 24, UInt64(1_520_000_000)); fm.createFile(atPath: e.dir + "/response.bin", contents: Data(d))
    check(issues(analyze(e.dir)).contains("expected six successful automatic callbacks within 8 ms"), "slow callback flagged"); try? fm.removeItem(atPath: e.dir) }
// 8. sparse capture cannot certify
do { var e = evidence(); e.frames = stride(from: 0, to: e.frames.count, by: 50).map { e.frames[$0] }; save(e)
    check(issues(analyze(e.dir)).contains("continuous fixture capture has a gap over 50 ms or insufficient frames"), "sparse flagged"); try? fm.removeItem(atPath: e.dir) }

print("failures=\(failures)")
exit(failures == 0 ? 0 : 1)
