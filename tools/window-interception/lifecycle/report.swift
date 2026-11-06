#!/usr/bin/env swift
// Decode a saved V3 observer ring; never contacts or mutates WindowServer.
// usage: report.swift PATH/response.bin
import Foundation

func refuse(_ m: String) -> Never { FileHandle.standardError.write(Data("refused: \(m)\n".utf8)); exit(1) }

let argv = Array(CommandLine.arguments.dropFirst())
guard let path = argv.first else { FileHandle.standardError.write(Data("usage: report.swift RING\n".utf8)); exit(2) }
guard let data = FileManager.default.contents(atPath: path) else { refuse("cannot read \(path)") }
func load<T>(_ o: Int, _ t: T.Type) -> T { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: t) } }

if data.count != 56 + 256 * 104 || data.prefix(8) != Data("WSOBSERV".utf8) { refuse("expected a complete V3 observer ring") }
let version = load(8, UInt64.self), calls = load(16, UInt64.self)
let numer = load(40, UInt32.self), denom = load(44, UInt32.self), torn = load(48, UInt32.self)
if version != 3 || numer == 0 || denom == 0 || torn != 0 { refuse("unsupported version, invalid timebase or torn snapshot") }

var events: [[String: Any]] = []
var seen = Set<UInt64>()
for index in 0..<256 {
    let off = 56 + index * 104
    let seq = load(off, UInt64.self)
    let before = load(off + 16, UInt64.self), after = load(off + 24, UInt64.self)
    if seq == 0 { continue }
    let count = load(off + 32, UInt32.self)
    let flag = load(off + 36, UInt32.self)
    let result = load(off + 40, Int32.self)
    let captured = load(off + 44, UInt32.self)
    let held = load(off + 48, UInt32.self)
    if seq > calls || seen.contains(seq) || after < before || captured > 4 { refuse("inconsistent ring event") }
    seen.insert(seq)
    var ids: [UInt32] = []
    for i in 0..<Int(captured) { ids.append(load(off + 52 + i * 4, UInt32.self)) }
    let durationUs = Double(after - before) * Double(numer) / Double(denom) / 1000.0
    events.append(["sequence": seq, "count": count, "flag": flag, "result": result,
                   "held": held, "duration_us": durationUs, "ids": ids])
}
events.sort { ($0["sequence"] as! UInt64) < ($1["sequence"] as! UInt64) }

// SHA-256 over the raw bytes via /usr/bin/shasum (no CommonCrypto import needed).
var sha = ""
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum"); p.arguments = ["-a", "256", path]
let pipe = Pipe(); p.standardOutput = pipe
try? p.run(); let shaOut = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""; p.waitUntilExit()
sha = shaOut.split(separator: " ").first.map(String.init) ?? ""

let out: [String: Any] = ["schema": 1, "source": path, "sha256": sha, "observer_version": version,
                          "calls": calls, "retained": events.count, "events": events,
                          "scope": "saved snapshot only; not a current health or production readiness assertion"]
let json = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
print(String(data: json, encoding: .utf8)!)
