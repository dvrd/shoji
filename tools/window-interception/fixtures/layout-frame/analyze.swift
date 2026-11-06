#!/usr/bin/env swift
// Evaluate two-window pixel transitions in one ScreenCaptureKit stream.
// usage: analyze.swift DIRECTORY
import Foundation

let fm = FileManager.default
guard let dir = CommandLine.arguments.dropFirst().first else { FileHandle.standardError.write(Data("usage: analyze.swift DIRECTORY\n".utf8)); exit(2) }
func fail(_ m: String) -> Never { FileHandle.standardError.write(Data("invalid evidence: \(m)\n".utf8)); exit(2) }

func text(_ name: String) -> String {
    guard let s = try? String(contentsOfFile: dir + "/" + name, encoding: .utf8) else { fail("cannot read \(name)") }
    return s
}
func objLines(_ name: String) -> [[String: Any]] {
    text(name).split(separator: "\n").compactMap { line -> [String: Any]? in
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(t.utf8))) as? [String: Any]
    }
}
func json(_ name: String) -> [String: Any] {
    guard let o = (try? JSONSerialization.jsonObject(with: Data(text(name).utf8))) as? [String: Any] else { fail("bad json in \(name)") }
    return o
}
func i(_ d: [String: Any], _ k: String) -> Int { (d[k] as? NSNumber)?.intValue ?? 0 }
func dbl(_ d: [String: Any], _ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? 0 }
func str(_ d: [String: Any], _ k: String) -> String { d[k] as? String ?? "" }

let mode = text("mode.txt").trimmingCharacters(in: .whitespacesAndNewlines)
guard mode == "cascade" || mode == "gated" else { fail("unknown experiment mode") }
let ready = json("fixture-ready.json"), clock = json("capture-ready.json")
let numer = i(clock, "numer"), denom = i(clock, "denom")
if Set([i(ready, "red"), i(ready, "green"), i(ready, "marker")]).count != 3 || numer == 0 || denom == 0 { fail("invalid fixture identity or timebase") }

let frames = objLines("frames.jsonl")
let events = objLines("fixture-events.jsonl").filter { ["cascade", "trigger"].contains(str($0, "verb")) && str($0, "id") != "warmup" }
var issues: [String] = []
if events.count != 6 { issues.append("expected six fixture layout changes") }
for (idx, event) in events.enumerated() {
    let y = idx % 2 == 0 ? 450 : 200
    if i(event, "red_status") != 0 || i(event, "green_status") != 0
        || (i(event, "red_x"), i(event, "green_x"), i(event, "red_y"), i(event, "green_y")) != (100, 400, y, y) {
        issues.append("fixture readback does not match complete requested layout")
    }
    if i(event, "ended") < i(event, "started") { issues.append("invalid fixture event clock") }
}
let valid = frames.filter { i($0, "status") == 0 && ($0["displayTicks"] is NSNumber) }
if valid.isEmpty || valid.count != frames.count { issues.append("missing complete-frame display timestamps") }
if zip(valid, valid.dropFirst()).contains(where: { i($1, "displayTicks") < i($0, "displayTicks") }) { issues.append("display timestamps go backwards") }

// Only claim about the actual change interval, with margins that retain stable
// states before and after.
let margin = 200_000_000 * denom / numer
var selected: [[String: Any]] = []
if !events.isEmpty {
    let first = i(events.first!, "started") - margin, last = i(events.last!, "ended") + margin
    selected = valid.filter { (first...last).contains(i($0, "displayTicks")) }
}
var states: [String: Int] = [:]
for f in selected { states[str(f, "state"), default: 0] += 1 }
if (states["??"] ?? 0) != 0 || selected.contains(where: { str($0, "state").contains("?") }) { issues.append("fixture pixels missing or outside calibrated position bands") }
if selected.contains(where: { i($0, "redCount") < 100 || i($0, "greenCount") < 100 }) { issues.append("too few fixture color pixels") }

var stable: [[String: Any]] = []
for f in selected {
    let st = str(f, "state")
    if (st == "AA" || st == "BB") && (stable.isEmpty || str(stable.last!, "state") != st) { stable.append(f) }
}
if let first = selected.first, stable.isEmpty || str(stable[0], "state") != "AA" {
    let prior = valid.filter { i($0, "displayTicks") < i(first, "displayTicks") && str($0, "state") == "AA" }
    if let last = prior.last { stable.insert(last, at: 0) }
}
let transitions = max(0, stable.count - 1)
if transitions != 6 || stable.isEmpty || str(stable[0], "state") != "AA" || str(stable.last!, "state") != "AA" {
    issues.append("capture did not resolve all six complete layout transitions")
}
let mixed = (states["AB"] ?? 0) + (states["BA"] ?? 0)
let gapsMs = zip(selected, selected.dropFirst()).map { Double(i($1, "displayTicks") - i($0, "displayTicks")) * Double(numer) / Double(denom) / 1e6 }
let mixedChanges = events.filter { event in
    selected.contains { f in
        (i(event, "started")...(i(event, "ended") + margin)).contains(i(f, "displayTicks")) && ["AB", "BA"].contains(str(f, "state"))
    }
}.count
if selected.count < 24 || (gapsMs.max() ?? Double.infinity) > 50 { issues.append("continuous fixture capture has a gap over 50 ms or insufficient frames") }
if mode == "cascade" && mixedChanges != 6 { issues.append("continuous positive control did not resolve each staggered change") }
if mode == "cascade" && mixed == 0 { issues.append("positive control did not expose any mixed frame") }
if mode == "gated" && mixed != 0 { issues.append("gated layout has captured mixed frames") }

var gateEvents: [[String: Any]] = []
if mode == "gated" {
    guard let data = fm.contents(atPath: dir + "/response.bin") else { fail("invalid observer response") }
    if data.count != 56 + 256 * 104 || data.prefix(8) != Data("WSOBSERV".utf8) { fail("invalid observer response") }
    func load<T>(_ o: Int, _ t: T.Type) -> T { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: t) } }
    let version = load(8, UInt64.self)
    let onumer = load(40, UInt32.self), odenom = load(44, UInt32.self), torn = load(48, UInt32.self)
    if version != 3 || torn != 0 || Int(onumer) != numer || Int(odenom) != denom { issues.append("observer version, timebase or torn-copy failure") }
    var off = 56
    while off < data.count {
        let seq = load(off, UInt64.self)
        let before = load(off + 16, UInt64.self), after = load(off + 24, UInt64.self)
        let result = load(off + 40, Int32.self), captured = load(off + 44, UInt32.self), held = load(off + 48, UInt32.self), wid = load(off + 52, UInt32.self)
        if seq != 0 && captured != 0 && Int(wid) == i(ready, "marker") && held != 0 {
            gateEvents.append(["sequence": seq, "held": held, "result": result,
                               "duration_us": Double(after - before) * Double(onumer) / Double(odenom) / 1000])
        }
        off += 104
    }
    if gateEvents.count != 6 || gateEvents.contains(where: { ($0["held"] as! UInt32) != 3 || ($0["result"] as! Int32) != 0 || ($0["duration_us"] as! Double) > 8000 }) {
        issues.append("expected six successful automatic callbacks within 8 ms")
    }
}

let verdict = !issues.isEmpty ? "inconclusive" : (mode == "cascade" ? "mixed-frame-control-observed" : "captured-layout-transitions-atomic")
let result: [String: Any] = [
    "mode": mode, "complete_frames": valid.count, "change_interval_frames": selected.count,
    "states": states, "mixed_frames": mixed, "mixed_changes": mixedChanges,
    "max_change_frame_gap_ms": gapsMs.max() as Any, "resolved_transitions": transitions,
    "callback_events": gateEvents, "issues": issues, "verdict": verdict,
    "limitation": "One display stream, two owned fixture windows and six transitions on one VM build; capture can omit frames and is not physical scanout or a production integration guarantee.",
]
let outData = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(data: outData, encoding: .utf8)!)
exit(issues.isEmpty ? 0 : 1)
