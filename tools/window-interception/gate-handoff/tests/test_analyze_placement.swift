#!/usr/bin/swift
// Black-box test for analyze-placement.swift. Run: swift gate-handoff/tests/test_analyze_placement.swift
import Foundation

let fm = FileManager.default
let tool = (CommandLine.arguments[0] as NSString).deletingLastPathComponent + "/../analyze-placement.swift"
var failures = 0
func check(_ cond: Bool, _ msg: String) { if cond { print("PASS \(msg)") } else { print("FAIL \(msg)"); failures += 1 } }

func put<T: FixedWidthInteger>(_ b: inout [UInt8], _ off: Int, _ v: T) {
    var le = v.littleEndian; withUnsafeBytes(of: &le) { for (i, x) in $0.enumerated() { b[off + i] = x } }
}
func baseData() -> [UInt8] {
    var d = [UInt8](repeating: 0, count: 56 + 256 * 104)
    for (i, b) in Array("WSOBSERV".utf8).enumerated() { d[i] = b }
    put(&d, 8, UInt64(3)); put(&d, 16, UInt64(1)); put(&d, 24, UInt64(0)); put(&d, 32, UInt64(0))
    put(&d, 40, UInt32(125)); put(&d, 44, UInt32(3)); put(&d, 48, UInt32(0))
    put(&d, 56, UInt64(1)); put(&d, 64, UInt64(0)); put(&d, 72, UInt64(100)); put(&d, 80, UInt64(24000100))
    put(&d, 88, UInt32(1)); put(&d, 92, UInt32(0)); put(&d, 96, Int32(0)); put(&d, 100, UInt32(1)); put(&d, 104, UInt32(1))
    put(&d, 108, UInt32(42)); put(&d, 124, Int32(1))
    return d
}
let samplerCSV = """
# window=42 interval_us=200000 duration_ms=8000
# timebase_numer=125 timebase_denom=3 start_tick=0
seq,tick_start,tick_end,found,onscreen,layer,alpha,x,y,width,height
0,100,24000100,1,1,0,1,123,910,314,228

"""

func newDir() -> String {
    let dir = NSTemporaryDirectory() + "shoji-test-placement-\(UUID().uuidString)"
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? "window=42\nPASS: fixture completed\n".write(toFile: dir + "/trigger.txt", atomically: true, encoding: .utf8)
    try? samplerCSV.write(toFile: dir + "/sampler.csv", atomically: true, encoding: .utf8)
    return dir
}
func run(_ dir: String, _ data: [UInt8], expected: (Int, Int)? = nil) -> (code: Int32, out: String) {
    fm.createFile(atPath: dir + "/response.bin", contents: Data(data))
    var args = [dir]
    if let (x, y) = expected { args += ["--expected-position", "\(x)", "\(y)"] }
    let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
    let o = Pipe(); p.standardOutput = o; p.standardError = Pipe()
    try? p.run(); let out = String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""; p.waitUntilExit()
    return (p.terminationStatus, out)
}
func json(_ s: String) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]) ?? [:] }

// 1. correlated hold, not atomic
do {
    let dir = newDir(); let (_, out) = run(dir, baseData()); let j = json(out)
    check(j["verdict"] as? String == "correlated-only", "verdict correlated-only")
    check((j["max_query_ms"] as? NSNumber)?.intValue == 1000, "max_query_ms == 1000")
    check(((j["fixture_events"] as? [[String: Any]])?.first?["held"] as? NSNumber)?.intValue == 1, "held == 1")
    try? fm.removeItem(atPath: dir)
}
// 2. stale dump → inconclusive (id 99 not captured)
do { let dir = newDir(); var d = baseData(); put(&d, 108, UInt32(99)); check(json(run(dir, d).out)["verdict"] as? String == "inconclusive", "stale dump inconclusive"); try? fm.removeItem(atPath: dir) }
// 3. autonomous timeout
do { let dir = newDir(); var d = baseData(); put(&d, 104, UInt32(2)); check((json(run(dir, d).out)["issues"] as? [String] ?? []).joined(separator: " ").contains("autonomous timeout"), "autonomous timeout flagged"); try? fm.removeItem(atPath: dir) }
// 4. uncaptured id → no events
do { let dir = newDir(); var d = baseData(); put(&d, 100, UInt32(0)); check((json(run(dir, d).out)["fixture_events"] as? [Any])?.isEmpty == true, "uncaptured id → no events"); try? fm.removeItem(atPath: dir) }
// 5. duplicate run artifacts
do {
    let dir = newDir(); let d = baseData(); fm.createFile(atPath: dir + "/response-run2.bin", contents: Data(d))
    check((json(run(dir, d).out)["duplicate_artifacts"] as? [String]) == ["response-run2.bin"], "duplicate artifacts flagged"); try? fm.removeItem(atPath: dir)
}
// 6. timebase mismatch refused
do { let dir = newDir(); var d = baseData(); put(&d, 40, UInt32(1)); check(run(dir, d).code != 0, "timebase mismatch refused"); try? fm.removeItem(atPath: dir) }
// 7. truncated refused
do { let dir = newDir(); check(run(dir, Array(baseData().dropLast())).code != 0, "truncated dump refused"); try? fm.removeItem(atPath: dir) }
// 8/9. geometry verified + generation mismatch inconclusive + unchanged bounds
func placementDir() -> String {
    let dir = newDir()
    try? "1 status=0 target=42 gen=7\n".write(toFile: dir + "/arm.txt", atomically: true, encoding: .utf8)
    try? "2 status=0 target=42 gen=7\n".write(toFile: dir + "/release.txt", atomically: true, encoding: .utf8)
    try? "3 status=0 gen=7 x=600 y=400\n".write(toFile: dir + "/placement.txt", atomically: true, encoding: .utf8)
    try? "bounds: window=42 status=0 x=600 y=400 w=320 h=232\n".write(toFile: dir + "/bounds-released.txt", atomically: true, encoding: .utf8)
    return dir
}
do {
    let dir = placementDir()
    check(json(run(dir, baseData(), expected: (600, 400)).out)["verdict"] as? String == "geometry-verified", "geometry verified")
    try? "3 status=0 gen=6 x=600 y=400\n".write(toFile: dir + "/placement.txt", atomically: true, encoding: .utf8)
    check(json(run(dir, baseData(), expected: (600, 400)).out)["verdict"] as? String == "inconclusive", "generation mismatch inconclusive")
    try? fm.removeItem(atPath: dir)
}
do {
    let dir = placementDir()
    try? "bounds: window=42 status=0 x=120 y=908 w=320 h=232\n".write(toFile: dir + "/bounds-released.txt", atomically: true, encoding: .utf8)
    check((json(run(dir, baseData(), expected: (600, 400)).out)["issues"] as? [String] ?? []).joined(separator: " ").contains("independent bounds"), "unchanged bounds flagged")
    try? fm.removeItem(atPath: dir)
}

print("failures=\(failures)")
exit(failures == 0 ? 0 : 1)
